# Starts one virtual phone. Without -Name it shows a menu of all phones.
#   -ColdBoot  start fresh instead of resuming the saved state (fixes most freezes)
#   -Wipe      factory-reset the phone (deletes WhatsApp and everything on it)

param(
    [string]$Name,
    [switch]$ColdBoot,
    [switch]$Wipe,
    [switch]$Detached
)

. "$PSScriptRoot\common.ps1"

function Show-Message([string]$Text) {
    (New-Object -ComObject WScript.Shell).Popup($Text, 0, 'WhatsApp Phones', 48) | Out-Null
}

function Test-PhoneRunning([string]$PhoneName) {
    $pattern = '-avd\s+"?' + [regex]::Escape($PhoneName) + '("|\s|$)'
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe' OR Name LIKE 'qemu-system-%'"
    return [bool]($procs | Where-Object { $_.CommandLine -match $pattern })
}

if (-not (Test-Path $Emulator)) {
    Show-Message 'The emulator is not installed yet. Run Setup.bat first.'
    exit 1
}
Set-AndroidEnv

$phones = @(Get-PhoneNames)
if ($phones.Count -eq 0) {
    Show-Message 'No virtual phones found. Run Setup.bat first.'
    exit 1
}

if (-not $Name) {
    Write-Host ''
    Write-Host 'Your virtual phones:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $phones.Count; $i++) {
        $state = ''
        if (Test-PhoneRunning $phones[$i]) { $state = '  (running)' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), (Get-PhoneDisplayName $phones[$i]), $state)
    }
    Write-Host ''
    $choice = Read-Host 'Type a number and press Enter'
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $phones.Count) {
        Write-Host 'Invalid choice.' -ForegroundColor Red
        exit 1
    }
    $Name = $phones[$index - 1]
}

if ($phones -notcontains $Name) {
    Show-Message "Phone '$Name' was not found. Run Setup.bat to create it."
    exit 1
}

if (Test-PhoneRunning $Name) {
    Show-Message "$(Get-PhoneDisplayName $Name) is already open."
    exit 0
}

if (-not $Detached) {
    # Relaunch from a hidden console: the emulator stays attached to that console,
    # so closing this window cannot close the phone by accident.
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                  '-File', "`"$PSCommandPath`"", '-Name', $Name, '-Detached')
    if ($ColdBoot) { $relaunch += '-ColdBoot' }
    if ($Wipe)     { $relaunch += '-Wipe' }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList $relaunch -WindowStyle Hidden
    Write-Host "Starting $(Get-PhoneDisplayName $Name)... (first start takes 1-3 minutes)" -ForegroundColor Green
    exit 0
}

$emulatorArgs = @('-avd', $Name, '-no-boot-anim')
if ($ColdBoot) { $emulatorArgs += '-no-snapshot-load' }
if ($Wipe)     { $emulatorArgs += '-wipe-data' }
Start-Process -FilePath $Emulator -ArgumentList $emulatorArgs -NoNewWindow
