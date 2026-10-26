# Removes everything the toolkit installed: the emulator, the virtual phones
# (including WhatsApp data on them), the WhatsApp Web profiles and the Desktop
# shortcuts it created. Your real phones and other shortcuts are not touched.

. "$PSScriptRoot\common.ps1"

Write-Host ''
Write-Host "This deletes $Root and every virtual phone in it, with the WhatsApp chats stored there." -ForegroundColor Yellow
Write-Host 'Make a WhatsApp chat backup inside each virtual phone first if you need the chats.' -ForegroundColor Yellow
$answer = Read-Host 'Type YES to delete everything'
if ($answer -cne 'YES') {
    Write-Host 'Cancelled.'
    Read-Host 'Press Enter to close'
    exit 0
}

Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe' OR Name LIKE 'qemu-system-%' OR Name = 'adb.exe' OR Name = 'msedge.exe' OR Name = 'chrome.exe'" |
    Where-Object { $_.ExecutablePath -like "$Root\*" -or $_.CommandLine -like "*$Root\*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

$shell = New-Object -ComObject WScript.Shell
Get-ChildItem (Get-DesktopPath) -Filter '*.lnk' | ForEach-Object {
    $lnk = $shell.CreateShortcut($_.FullName)
    if ($lnk.Arguments -like "*$Root\*" -or $lnk.TargetPath -like "$Root\*") {
        Remove-Item $_.FullName -Force
        Write-Ok "Removed shortcut $($_.Name)"
    }
}

if (Test-Path $Root) {
    # Run the deletion from outside the folder, since this script may live in it.
    Set-Location $env:TEMP
    [Environment]::CurrentDirectory = $env:TEMP
    Remove-Item $Root -Recurse -Force
}
Write-Ok "Removed $Root"
Read-Host 'Press Enter to close'
