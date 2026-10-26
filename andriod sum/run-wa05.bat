@echo off
rem Auto-generated launcher for instance "wa05" (console port 5556).
rem Regenerate all of them from the manager window > Launchers.
rem
rem   run-wa05.bat            boot it (does NOT open WhatsApp - tap the icon yourself)
rem   run-wa05.bat -Stop      graceful shutdown (lets Android flush userdata)
rem   run-wa05.bat -Snapshot  resume from a saved snapshot instead of booting fresh
rem                           (measured 4-8x SLOWER on this disk - see android.ps1)
rem   run-wa05.bat -Net       network diagnostics
rem   run-wa05.bat -Check     device identity / Google Play / capabilities / integrity
rem                           (integrity = why WhatsApp registration blocks on an emulator)
rem   run-wa05.bat -Paste     paste the Windows clipboard into the focused field
rem                           (Ctrl+V inside the emulator window does the same thing)
rem   run-wa05.bat -ResetApp -Force
rem                           wipe WhatsApp's data here and start it fresh - the way out
rem                           of "Download the official WhatsApp to continue". Erases
rem                           this instance's session and local chat history.
rem
rem NO console window: PowerShell starts hidden and this file exits immediately.
rem Everything it would have printed is in logs\wa05.log - read it in the manager
rem window > Logs, which also tails it live. A failed boot still raises a dialog.
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0android.ps1" -Name wa05 %*
