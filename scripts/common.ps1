# Shared settings and helpers for the WhatsApp Phones toolkit.
# Everything lives under one ASCII-only folder (default C:\WaPhones) because the
# Android emulator fails when its paths contain spaces or non-English letters
# (for example an Arabic Windows user name).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:WAPHONES_ROOT) { $Root = $env:WAPHONES_ROOT } else { $Root = 'C:\WaPhones' }

$Sdk          = Join-Path $Root 'sdk'
$UserHome     = Join-Path $Root 'home'
$AvdHome      = Join-Path $UserHome 'avd'
$Downloads    = Join-Path $Root 'downloads'
$WebProfiles  = Join-Path $Root 'web'
$InstalledScripts = Join-Path $Root 'scripts'

$Emulator   = Join-Path $Sdk 'emulator\emulator.exe'
$Adb        = Join-Path $Sdk 'platform-tools\adb.exe'

$PhonePrefix = 'WhatsApp-'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }

function Assert-SafeRoot {
    if ($Root -notmatch '^[A-Za-z]:\\[A-Za-z0-9_\-\\]+$') {
        throw "The install folder '$Root' must use English letters/numbers only and no spaces (example: C:\WaPhones)."
    }
}

function Set-AndroidEnv {
    $env:ANDROID_HOME          = $Sdk
    $env:ANDROID_SDK_ROOT      = $Sdk
    $env:ANDROID_USER_HOME     = $UserHome
    $env:ANDROID_EMULATOR_HOME = $UserHome
    $env:ANDROID_AVD_HOME      = $AvdHome
}

function Invoke-Download([string]$Url, [string]$OutFile) {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    Write-Host "    Downloading $Url"
    # curl.exe (built into Windows 10/11) shows progress; fall back to PowerShell if it fails.
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        & $curl -L --fail --retry 3 --progress-bar -o $OutFile $Url
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warn 'curl failed, retrying with PowerShell (no progress bar, please wait)...'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    } catch {
        throw "Download failed: $Url ($($_.Exception.Message))"
    }
}

function Expand-Zip([string]$ZipFile, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $Destination)
}

function Get-PhoneNames {
    if (-not (Test-Path $AvdHome)) { return @() }
    Get-ChildItem $AvdHome -Filter "$PhonePrefix*.ini" |
        ForEach-Object { $_.BaseName } |
        Sort-Object { [int]($_ -replace '\D', '') }
}

function Get-PhoneDisplayName([string]$Name) {
    $config = Join-Path $AvdHome "$Name.avd\config.ini"
    if (Test-Path $config) {
        $line = Get-Content $config | Where-Object { $_ -like 'avd.ini.displayname=*' } | Select-Object -First 1
        if ($line) { return $line.Substring('avd.ini.displayname='.Length) }
    }
    return $Name
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon, [string]$WorkingDir) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    if ($Icon) { $lnk.IconLocation = $Icon }
    if ($WorkingDir) { $lnk.WorkingDirectory = $WorkingDir }
    $lnk.Save()
}

function Get-DesktopPath { [Environment]::GetFolderPath('Desktop') }
