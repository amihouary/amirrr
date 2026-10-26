# Installs Google's official Android Emulator (the same one Android Studio uses)
# and creates one virtual phone per WhatsApp number, each with Google Play so the
# official WhatsApp app can be installed from the Play Store.
#
# Safe to run again: finished steps are skipped, and asking for more phones only
# adds the missing ones.

param(
    [int]$Phones = 0,
    [string]$SystemImage = 'system-images;android-34;google_apis_playstore;x86_64',
    [int]$RamMB = 2048,
    [string]$StorageSize = '8G'
)

. "$PSScriptRoot\common.ps1"

function Get-CmdlineToolsArchive {
    # Read the download link straight from Google's official package list so we
    # always get the current version together with its checksum.
    $base = 'https://dl.google.com/android/repository/'
    try {
        $xmlFile = Join-Path $Downloads 'repository2-3.xml'
        Invoke-Download ($base + 'repository2-3.xml') $xmlFile
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($xmlFile)
        $pkg = $xml.SelectSingleNode("//*[local-name()='remotePackage' and @path='cmdline-tools;latest']")
        foreach ($archive in $pkg.SelectNodes(".//*[local-name()='archive']")) {
            $os = $archive.SelectSingleNode("*[local-name()='host-os']")
            if ($os -and $os.InnerText -eq 'windows') {
                $complete = $archive.SelectSingleNode("*[local-name()='complete']")
                $checksum = $complete.SelectSingleNode("*[local-name()='checksum']")
                $algo = $checksum.GetAttribute('type')
                if (-not $algo) { $algo = 'sha1' }
                return @{
                    Url       = $base + $complete.SelectSingleNode("*[local-name()='url']").InnerText
                    Checksum  = $checksum.InnerText
                    Algorithm = $algo.ToUpper()
                }
            }
        }
        throw 'Windows package not found in the list.'
    } catch {
        Write-Warn "Could not read Google's package list ($($_.Exception.Message)). Using a known version."
        return @{ Url = $base + 'commandlinetools-win-11076708_latest.zip'; Checksum = $null; Algorithm = $null }
    }
}

function Set-IniValues([string]$File, [hashtable]$Values) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $File) { foreach ($l in Get-Content $File) { $lines.Add($l) } }
    foreach ($key in $Values.Keys) {
        $entry = "$key=$($Values[$key])"
        $pattern = '^\s*' + [regex]::Escape($key) + '\s*='
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $idx = $i; break }
        }
        if ($idx -ge 0) { $lines[$idx] = $entry } else { $lines.Add($entry) }
    }
    [System.IO.File]::WriteAllLines($File, $lines.ToArray())
}

function Test-Webcam {
    try { return [bool](Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction Stop) }
    catch { return $false }
}

function Show-AccelHelp {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
        Write-Warn 'Virtualization (Intel VT-x / AMD SVM) is OFF in your BIOS/UEFI.'
        Write-Warn 'Restart the PC, open BIOS/UEFI settings and enable "Virtualization Technology" or "SVM Mode".'
    }
    Write-Warn 'The emulator needs the Windows feature "Windows Hypervisor Platform".'
}

# ---------------------------------------------------------------- checks
Write-Host ''
Write-Host '=============================================' -ForegroundColor Green
Write-Host '   WhatsApp Phones - setup (official tools)  ' -ForegroundColor Green
Write-Host '=============================================' -ForegroundColor Green

Assert-SafeRoot

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -ne 'AMD64') {
    throw "This PC is '$arch'. Google's Android Emulator on Windows needs a 64-bit Intel or AMD processor."
}

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGB -lt 8) {
    Write-Warn "This PC has $ramGB GB of RAM. Run only one virtual phone at a time."
}

if ($Phones -le 0) {
    $answer = Read-Host 'How many virtual phones do you want (one per WhatsApp number)? [2]'
    if ([string]::IsNullOrWhiteSpace($answer)) { $Phones = 2 } else { $Phones = [int]$answer }
}
if ($Phones -lt 1 -or $Phones -gt 20) { throw 'Choose between 1 and 20 phones.' }

$drive = (Split-Path $Root -Qualifier).TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
$needGB = 8 + 3 * $Phones
if ($freeGB -lt $needGB) {
    Write-Warn "Only $freeGB GB free on ${drive}:. About $needGB GB is recommended."
}

New-Item -ItemType Directory -Force -Path $Root, $Sdk, $AvdHome, $Downloads | Out-Null

# ---------------------------------------------------------------- Java (needed by Google's SDK tools)
Write-Step 'Step 1/5: Java runtime for the Android SDK tools'
if (Get-JavaHome) {
    Write-Ok 'Already installed.'
} else {
    $zip = Join-Path $Downloads 'jdk.zip'
    try {
        Invoke-Download 'https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.zip' $zip
    } catch {
        Write-Warn 'Microsoft OpenJDK download failed, trying Eclipse Temurin.'
        Invoke-Download 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' $zip
    }
    Expand-Zip $zip $JdkDir
    Remove-Item $zip -Force
    if (-not (Get-JavaHome)) { throw 'Java was downloaded but java.exe was not found.' }
    Write-Ok 'Installed.'
}
Set-AndroidEnv

# ---------------------------------------------------------------- Android SDK command-line tools
Write-Step 'Step 2/5: Android SDK command-line tools (from dl.google.com)'
if (Test-Path $SdkManager) {
    Write-Ok 'Already installed.'
} else {
    $info = Get-CmdlineToolsArchive
    $zip = Join-Path $Downloads 'cmdline-tools.zip'
    Invoke-Download $info.Url $zip
    if ($info.Checksum) {
        $hash = (Get-FileHash $zip -Algorithm $info.Algorithm).Hash
        if ($hash -ne $info.Checksum) { throw 'Checksum mismatch: the download is damaged. Run Setup again.' }
        Write-Ok "Checksum verified ($($info.Algorithm))."
    }
    $tmp = Join-Path $Downloads 'cmdline-tools-tmp'
    Expand-Zip $zip $tmp
    $dest = Join-Path $Sdk 'cmdline-tools\latest'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Move-Item (Join-Path $tmp 'cmdline-tools') $dest
    Remove-Item $tmp -Recurse -Force
    Remove-Item $zip -Force
    Write-Ok 'Installed.'
}

# ---------------------------------------------------------------- emulator + Google Play system image
Write-Step 'Step 3/5: Android Emulator and Android image with Google Play (large download, please wait)'
$yes = ((1..60) | ForEach-Object { 'y' }) -join "`r`n"
$yes | & $SdkManager "--sdk_root=$Sdk" --licenses
if ($LASTEXITCODE -ne 0) { throw 'Accepting the Android SDK licenses failed.' }
& $SdkManager "--sdk_root=$Sdk" platform-tools emulator $SystemImage
if ($LASTEXITCODE -ne 0) { throw 'Installing the emulator packages failed. Check your internet and run Setup again.' }
Write-Ok 'Emulator and image ready.'

# ---------------------------------------------------------------- virtual phones
Write-Step "Step 4/5: Creating $Phones virtual phone(s)"
$hasWebcam = Test-Webcam
if ($hasWebcam) { $backCamera = 'webcam0' } else { $backCamera = 'virtualscene' }
for ($i = 1; $i -le $Phones; $i++) {
    $name = "$PhonePrefix$i"
    $avdDir = Join-Path $AvdHome "$name.avd"
    if (Test-Path (Join-Path $AvdHome "$name.ini")) {
        Write-Ok "$name already exists."
        continue
    }
    'no' | & $AvdManager create avd -n $name -k $SystemImage -d pixel_6 -p $avdDir --force
    if ($LASTEXITCODE -ne 0) {
        'no' | & $AvdManager create avd -n $name -k $SystemImage -p $avdDir --force
    }
    if ($LASTEXITCODE -ne 0) { throw "Creating $name failed." }
    Set-IniValues (Join-Path $avdDir 'config.ini') @{
        'avd.ini.displayname'     = "WhatsApp Phone $i"
        'hw.ram'                  = $RamMB
        'disk.dataPartition.size' = $StorageSize
        'hw.keyboard'             = 'yes'
        'hw.gpu.enabled'          = 'yes'
        'hw.gpu.mode'             = 'auto'
        'hw.camera.back'          = $backCamera
        'hw.camera.front'         = 'emulated'
        'hw.audioInput'           = 'yes'
        'hw.audioOutput'          = 'yes'
    }
    Write-Ok "$name created."
}

# ---------------------------------------------------------------- toolkit copy + desktop shortcuts
Write-Step 'Step 5/5: Desktop shortcuts'
New-Item -ItemType Directory -Force -Path $InstalledScripts | Out-Null
if ((Resolve-Path $PSScriptRoot).Path -ne $InstalledScripts) {
    Copy-Item (Join-Path $PSScriptRoot '*.ps1') $InstalledScripts -Force
    Copy-Item (Join-Path $PSScriptRoot '..\*.bat') $Root -Force
    Copy-Item (Join-Path $PSScriptRoot '..\README.md') $Root -Force -ErrorAction SilentlyContinue
}
$desktop = Get-DesktopPath
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$startScript = Join-Path $InstalledScripts 'start-phone.ps1'
foreach ($name in Get-PhoneNames) {
    $n = $name.Substring($PhonePrefix.Length)
    New-Shortcut -Path (Join-Path $desktop "WhatsApp Phone $n.lnk") `
        -Target $powershell `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`" -Name $name -Detached" `
        -Icon "$Emulator,0" `
        -WorkingDir $InstalledScripts
    Write-Ok "Desktop shortcut: WhatsApp Phone $n"
}

# ---------------------------------------------------------------- hardware acceleration
Write-Step 'Checking hardware acceleration'
& $Emulator -accel-check
$accelOk = ($LASTEXITCODE -eq 0)
$needRestart = $false
if ($accelOk) {
    Write-Ok 'Hardware acceleration works.'
} else {
    Show-AccelHelp
    $answer = Read-Host 'Enable "Windows Hypervisor Platform" now? Needs administrator and a restart. [Y/n]'
    if ($answer -notmatch '^[nN]') {
        try {
            Start-Process -FilePath $powershell -Verb RunAs -Wait -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\enable-acceleration.ps1`"")
            $needRestart = $true
        } catch {
            Write-Warn 'Administrator permission was not given. Run scripts\enable-acceleration.ps1 as administrator later.'
        }
    }
}

# ---------------------------------------------------------------- done
Write-Host ''
Write-Host '=============================================' -ForegroundColor Green
Write-Host '   Setup finished' -ForegroundColor Green
Write-Host '=============================================' -ForegroundColor Green
if ($needRestart) {
    Write-Host ' * RESTART Windows first, then the phones will start.' -ForegroundColor Yellow
}
Write-Host ' 1. Double-click "WhatsApp Phone 1" on the Desktop (first start takes 1-3 minutes).'
Write-Host ' 2. Open Play Store, sign in with a Google account, install "WhatsApp Messenger" by WhatsApp LLC.'
Write-Host ' 3. Register your number (code by SMS or call). Repeat for each phone and number.'
Write-Host ' Everything is installed in' $Root
if ($hasWebcam) {
    Write-Host ' Your webcam is used as the phone camera (to scan QR codes).'
}
