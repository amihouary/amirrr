@echo off
rem Auto-generated launcher for instance "3794xa" (console port 5558).
rem Regenerate all of them from the manager window > Launchers.
rem
rem   run-3794xa.bat            boot it (does NOT open WhatsApp - tap the icon yourself)
rem   run-3794xa.bat -Stop      graceful shutdown (lets Android flush userdata)
rem   run-3794xa.bat -Snapshot  resume from a saved snapshot instead of booting fresh
rem                           (measured 4-8x SLOWER on this disk - see android.ps1)
rem   run-3794xa.bat -Net       network diagnostics
rem   run-3794xa.bat -Check     device identity / Google Play / capabilities / integrity
rem                           (integrity = why WhatsApp registration blocks on an emulator)
rem   run-3794xa.bat -Paste     paste the Windows clipboard into the focused field
rem                           (Ctrl+V inside the emulator window does the same thing)
rem   run-3794xa.bat -ResetApp -Force
rem                           wipe WhatsApp's data here and start it fresh - the way out
rem                           of "Download the official WhatsApp to continue". Erases
rem                           this instance's session and local chat history.
rem
rem NO console window: PowerShell starts hidden and this file exits immediately.
rem Everything it would have printed is in logs\3794xa.log - read it in the manager
rem window > Logs, which also tails it live. A failed boot still raises a dialog.
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0android.ps1" -Name 3794xa %*
