# Turns on the built-in Windows feature "Windows Hypervisor Platform", which the
# Android Emulator uses to run fast. Must run as administrator; a restart is
# needed afterwards. Works on Windows 10/11 Home and Pro.

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

try {
    Write-Host 'Enabling Windows Hypervisor Platform...' -ForegroundColor Cyan
    $result = Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
    if ($result.RestartNeeded) {
        Write-Host 'Done. Please RESTART Windows, then open your WhatsApp Phone.' -ForegroundColor Green
    } else {
        Write-Host 'Done. The feature is enabled.' -ForegroundColor Green
    }

    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
        Write-Host ''
        Write-Host 'Virtualization is also OFF in your BIOS/UEFI.' -ForegroundColor Yellow
        Write-Host 'While restarting, open BIOS/UEFI settings and enable "Virtualization Technology" (Intel) or "SVM Mode" (AMD).' -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Read-Host 'Press Enter to close'
