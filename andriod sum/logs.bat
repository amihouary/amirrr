@echo off
rem Double-click me to read what the emulators are doing. Nothing here opens a console:
rem every run of android.ps1 appends to logs\<instance>.log, the emulator's own output
rem goes to logs\<instance>-emulator.log, and this window tails whichever you pick.
rem
rem   logs.bat            open on the first instance
rem   logs.bat wa02       open on wa02
rem
rem "follow" keeps it scrolled to the newest line; "problems only" hides everything
rem except warnings, errors and the diagnosis of a failed boot.
cd /d "%~dp0"
set N=%1
if "%N%"=="" set N=wa01
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0manager.ps1" -Logs %N%
