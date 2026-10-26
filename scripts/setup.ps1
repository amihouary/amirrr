# Installs Google's official Android Emulator (the same one Android Studio uses)
# and creates one virtual phone per WhatsApp number, each with Google Play so the
# official WhatsApp app can be installed from the Play Store.
#
# Packages are downloaded straight from Google's official package list
# (dl.google.com) and checked against Google's checksums, so this does not depend
# on sdkmanager/avdmanager, whose command line keeps changing.
#
# Safe to run again: finished steps are skipped, and asking for more phones only
# adds the missing ones.

param(
    [int]$Phones = 0,
    [int]$ApiLevel = 34,
    [int]$RamMB = 2048,
    [string]$StorageSize = '8G'
)

. "$PSScriptRoot\common.ps1"

$RepoUrl   = 'https://dl.google.com/android/repository/'
$SysImgTag = 'google_apis_playstore'
$Abi       = 'x86_64'
$SysImgRel = "system-images\android-$ApiLevel\$SysImgTag\$Abi"
$SysImgDir = Join-Path $Sdk $SysImgRel

function Get-GoogleList([string]$BaseUrl, [string]$Prefix) {
    # Google publishes several versions of each list; take the newest one available.
    foreach ($version in 3, 2, 1) {
        $file = Join-Path $Downloads "$Prefix$version.xml"
        try {
            Invoke-Download "$BaseUrl$Prefix$version.xml" $file
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($file)
            return $xml
        } catch {
            Write-Warn "List version $version not available, trying an older one."
        }
    }
    throw "Could not read Google's package list from $BaseUrl. Check your internet and run Setup again."
}

function Find-Archive($Xml, [string]$PackagePath, [string]$BaseUrl) {
    # Newest stable (channel-0) build of the package for 64-bit Windows.
    $best = $null
    $bestRevision = [long]-1
    foreach ($pkg in $Xml.SelectNodes("//*[local-name()='remotePackage' and @path='$PackagePath']")) {
        $channel = $pkg.SelectSingleNode("*[local-name()='channelRef']")
        if ($channel -and $channel.GetAttribute('ref') -ne 'channel-0') { continue }
        $revision = [long]0
        $revNode = $pkg.SelectSingleNode("*[local-name()='revision']")
        foreach ($part in 'major', 'minor', 'micro') {
            $node = $null
            if ($revNode) { $node = $revNode.SelectSingleNode("*[local-name()='$part']") }
            $value = 0
            if ($node) { $value = [long]$node.InnerText }
            $revision = $revision * 10000 + $value
        }
        foreach ($archive in $pkg.SelectNodes(".//*[local-name()='archive']")) {
            $os  = $archive.SelectSingleNode("*[local-name()='host-os']")
            $cpu = $archive.SelectSingleNode("*[local-name()='host-arch']")
            if ($os -and $os.InnerText -ne 'windows') { continue }
            if ($cpu -and $cpu.InnerText -notin 'x64', 'x86_64') { continue }
            if ($revision -le $bestRevision) { continue }
            $complete = $archive.SelectSingleNode("*[local-name()='complete']")
            $checksum = $complete.SelectSingleNode("*[local-name()='checksum']")
            $algorithm = $checksum.GetAttribute('type')
            if (-not $algorithm) { $algorithm = 'sha1' }
            $licenseId = ''
            $licenseRef = $pkg.SelectSingleNode("*[local-name()='uses-license']")
            if ($licenseRef) { $licenseId = $licenseRef.GetAttribute('ref') }
            $licenseText = ''
            $licenseNode = $Xml.SelectSingleNode("//*[local-name()='license' and @id='$licenseId']")
            if ($licenseNode) { $licenseText = $licenseNode.InnerText }
            $best = @{
                Url         = $BaseUrl + $complete.SelectSingleNode("*[local-name()='url']").InnerText
                Checksum    = $checksum.InnerText.Trim()
                Algorithm   = $algorithm.ToUpper()
                LicenseId   = $licenseId
                LicenseText = $licenseText
            }
            $bestRevision = $revision
        }
    }
    if (-not $best) { throw "Package '$PackagePath' was not found in Google's package list." }
    return $best
}

function Install-GooglePackage($Archive, [string]$Target, [string]$MarkerFile, [string]$Label) {
    $zip = Join-Path $Downloads 'package.zip'
    Invoke-Download $Archive.Url $zip
    $hash = (Get-FileHash $zip -Algorithm $Archive.Algorithm).Hash
    if ($hash -ne $Archive.Checksum) {
        throw "$Label download is damaged (checksum mismatch). Run Setup again."
    }
    Write-Ok "Checksum verified ($($Archive.Algorithm))."
    Write-Host '    Unpacking...'
    $tmp = Join-Path $Downloads 'unpack'
    Expand-Zip $zip $tmp
    Remove-Item $zip -Force
    # The zip holds one top folder (emulator\, platform-tools\, x86_64\ ...); find it by a file it must contain.
    $marker = Get-ChildItem $tmp -Recurse -Filter $MarkerFile |
        Sort-Object { $_.FullName.Split('\').Count } |
        Select-Object -First 1
    if (-not $marker) { throw "$Label download looks wrong ($MarkerFile is missing)." }
    if (Test-Path $Target) { Remove-Item $Target -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $Target) | Out-Null
    Move-Item $marker.DirectoryName $Target
    Remove-Item $tmp -Recurse -Force
    Write-Ok "$Label installed."
}

function Test-Webcam {
    try { return [bool](Get-PnpDevice -Class Camera, Image -Status OK -ErrorAction Stop) }
    catch { return $false }
}

function New-Phone([int]$Number, [string]$BackCamera, [int]$Cores) {
    $name = "$PhonePrefix$Number"
    $avdDir = Join-Path $AvdHome "$name.avd"
    New-Item -ItemType Directory -Force -Path $avdDir | Out-Null
    $config = [ordered]@{
        'AvdId'                   = $name
        'avd.ini.displayname'     = "WhatsApp Phone $Number"
        'avd.ini.encoding'        = 'UTF-8'
        'PlayStore.enabled'       = 'true'
        'abi.type'                = $Abi
        'hw.cpu.arch'             = $Abi
        'hw.cpu.ncore'            = $Cores
        'hw.ramSize'              = $RamMB
        'vm.heapSize'             = 256
        'image.sysdir.1'          = "$SysImgRel\"
        'tag.id'                  = $SysImgTag
        'tag.display'             = 'Google Play'
        'target'                  = "android-$ApiLevel"
        'hw.lcd.width'            = 1080
        'hw.lcd.height'           = 2400
        'hw.lcd.density'          = 420
        'hw.keyboard'             = 'yes'
        'hw.gpu.enabled'          = 'yes'
        'hw.gpu.mode'             = 'auto'
        'hw.camera.back'          = $BackCamera
        'hw.camera.front'         = 'emulated'
        'hw.audioInput'           = 'yes'
        'hw.audioOutput'          = 'yes'
        'hw.sdCard'               = 'no'
        'disk.dataPartition.size' = $StorageSize
        'fastboot.forceColdBoot'  = 'no'
        'showDeviceFrame'         = 'no'
    }
    $lines = [string[]]($config.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    [System.IO.File]::WriteAllLines((Join-Path $avdDir 'config.ini'), $lines)
    # The pointer file is written last: its presence means the phone is complete.
    [System.IO.File]::WriteAllLines((Join-Path $AvdHome "$name.ini"), [string[]]@(
        'avd.ini.encoding=UTF-8',
        "path=$avdDir",
        "path.rel=avd\$name.avd",
        "target=android-$ApiLevel"
    ))
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
Write-Host '   WhatsApp Phones - setup v2 (official tools)' -ForegroundColor Green
Write-Host '=============================================' -ForegroundColor Green

Assert-SafeRoot

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -ne 'AMD64') {
    throw "This PC is '$arch'. Google's Android Emulator on Windows needs a 64-bit Intel or AMD processor."
}

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$maxOpen = [math]::Max(1, [math]::Floor(($ramGB - 4) / 3))
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

# Earlier versions of this toolkit used Java + sdkmanager; they are no longer needed.
foreach ($old in (Join-Path $Root 'jdk'), (Join-Path $Sdk 'cmdline-tools')) {
    if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- Google packages
Write-Step 'Step 1/4: Android Emulator, adb and Android image with Google Play (from dl.google.com)'
$needEmulator = -not (Test-Path $Emulator)
$needAdb      = -not (Test-Path $Adb)
$needImage    = -not (Test-Path (Join-Path $SysImgDir 'source.properties'))
if (-not ($needEmulator -or $needAdb -or $needImage)) {
    Write-Ok 'Already installed.'
} else {
    $packages = @()
    if ($needEmulator -or $needAdb) { $repo = Get-GoogleList $RepoUrl 'repository2-' }
    if ($needEmulator) {
        $packages += @{ Archive = (Find-Archive $repo 'emulator' $RepoUrl)
                        Target = (Join-Path $Sdk 'emulator'); Marker = 'emulator.exe'; Label = 'Android Emulator' }
    }
    if ($needAdb) {
        $packages += @{ Archive = (Find-Archive $repo 'platform-tools' $RepoUrl)
                        Target = (Join-Path $Sdk 'platform-tools'); Marker = 'adb.exe'; Label = 'Platform tools (adb)' }
    }
    if ($needImage) {
        $imgUrl = "${RepoUrl}sys-img/$SysImgTag/"
        $imgList = Get-GoogleList $imgUrl 'sys-img2-'
        $packages += @{ Archive = (Find-Archive $imgList "system-images;android-$ApiLevel;$SysImgTag;$Abi" $imgUrl)
                        Target = $SysImgDir; Marker = 'source.properties'; Label = "Android $ApiLevel image with Google Play (about 1.5 GB)" }
    }

    # Show Google's own license texts for these packages before downloading them.
    $licenseDir = Join-Path $Root 'licenses'
    New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
    foreach ($p in $packages) {
        if ($p.Archive.LicenseId -and $p.Archive.LicenseText) {
            [System.IO.File]::WriteAllText((Join-Path $licenseDir "$($p.Archive.LicenseId).txt"), $p.Archive.LicenseText)
        }
    }
    Write-Host '    These packages are Google software. Their license texts are saved in:'
    Write-Host "    $licenseDir   (also: https://developer.android.com/studio/terms)"
    $answer = Read-Host '    Do you accept Google''s license? [Y/n]'
    if ($answer -match '^[nN]') { throw 'Setup cancelled: the license was not accepted.' }

    foreach ($p in $packages) {
        Install-GooglePackage $p.Archive $p.Target $p.Marker $p.Label
    }
}
# The emulator only accepts an SDK folder that has these two subfolders.
New-Item -ItemType Directory -Force -Path (Join-Path $Sdk 'platforms'), (Join-Path $Sdk 'platform-tools') | Out-Null
Set-AndroidEnv

# ---------------------------------------------------------------- virtual phones
Write-Step "Step 2/4: Creating $Phones virtual phone(s)"
$hasWebcam = Test-Webcam
if ($hasWebcam) { $backCamera = 'webcam0' } else { $backCamera = 'virtualscene' }
if ([Environment]::ProcessorCount -ge 8) { $cores = 4 } else { $cores = 2 }
for ($i = 1; $i -le $Phones; $i++) {
    $name = "$PhonePrefix$i"
    if (Test-Path (Join-Path $AvdHome "$name.ini")) {
        Write-Ok "$name already exists."
        continue
    }
    New-Phone $i $backCamera $cores
    Write-Ok "$name created."
}

# ---------------------------------------------------------------- toolkit copy + desktop shortcuts
Write-Step 'Step 3/4: Desktop shortcuts'
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
Write-Step 'Step 4/4: Checking hardware acceleration'
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
Write-Host " With $ramGB GB of RAM, keep about $maxOpen phone(s) open at the same time; close one before opening another."
Write-Host ' Everything is installed in' $Root
if ($hasWebcam) {
    Write-Host ' Your webcam is used as the phone camera (to scan QR codes).'
}
