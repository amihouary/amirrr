@echo off
rem PANIC BUTTON. Double-click me when something is stuck and you want it all gone:
rem every emulator, the adb server, and any launcher still waiting on a boot.
rem
rem   kill-all.bat          asks each instance to shut down first, so the quick-boot
rem                         snapshots are saved, then kills whatever is left
rem   kill-all.bat -Force   kills immediately, no graceful shutdown.
rem                         Faster, but every instance loses its snapshot and the next
rem                         start is a slow cold boot. Use only when it is truly wedged.
rem
rem No console: it reports with one dialog when it is done, and writes the details to
rem logs\_killall.log. Measured 25-30 s for three instances.
rem
rem Nothing here touches the instances themselves - no WhatsApp session is ever lost,
rem only the saved RAM state.
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0android.ps1" -KillAll %*
