# Creates one Desktop shortcut per number for the official WhatsApp Web
# (web.whatsapp.com). Each shortcut uses its own separate browser profile, so
# every number stays logged in at the same time as an official "linked device".

param([int]$Count = 0)

. "$PSScriptRoot\common.ps1"

function Find-Browser {
    foreach ($exe in 'msedge.exe', 'chrome.exe') {
        foreach ($hive in 'HKLM:', 'HKCU:') {
            $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
            $path = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
            if ($path) { $path = $path.Trim('"') }
            if ($path -and (Test-Path $path)) { return $path }
        }
    }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

Assert-SafeRoot

if ($Count -le 0) {
    $answer = Read-Host 'How many WhatsApp Web windows (one per number)? [2]'
    if ([string]::IsNullOrWhiteSpace($answer)) { $Count = 2 } else { $Count = [int]$answer }
}
if ($Count -lt 1 -or $Count -gt 20) { throw 'Choose between 1 and 20.' }

$browser = Find-Browser
if (-not $browser) { throw 'Microsoft Edge or Google Chrome was not found.' }

New-Item -ItemType Directory -Force -Path $WebProfiles | Out-Null
$desktop = Get-DesktopPath
for ($i = 1; $i -le $Count; $i++) {
    $profileDir = Join-Path $WebProfiles "WhatsApp-Web-$i"
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    New-Shortcut -Path (Join-Path $desktop "WhatsApp Web $i.lnk") `
        -Target $browser `
        -Arguments "--user-data-dir=`"$profileDir`" --app=https://web.whatsapp.com/ --no-first-run --no-default-browser-check" `
        -Icon "$browser,0"
    Write-Ok "Desktop shortcut: WhatsApp Web $i"
}

Write-Host ''
Write-Host 'Open each "WhatsApp Web N" shortcut and link it to a different number:' -ForegroundColor Green
Write-Host '  On the phone: WhatsApp > Settings > Linked devices > Link a device, then scan the QR code,'
Write-Host '  or click "Log in with phone number" in the window and type the code on the phone.'
