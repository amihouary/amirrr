@echo off
rem Double-click me to create a new Android instance (one WhatsApp number per instance).
rem It creates the AVD, tunes it, reserves a console port, and writes run-<name>.bat
rem next to this file. After that you only ever touch run-<name>.bat.
rem
rem   new-instance.bat            asks for the name
rem   new-instance.bat wa02       creates "wa02" directly
rem   new-instance.bat wa02 2560  creates it with 2560 MB RAM (for stacking 4 accounts)
rem
rem Both get a device profile (screen, timezone, region, SIM number, device name) derived
rem from the name. To PICK one instead, use manager.bat > New - it asks what kind of
rem device you want - or android.ps1 -New wa02 -Device "Redmi Note 9" -Region 964-770.
rem
rem This one keeps its console: creating an AVD downloads and copies for a while and
rem there is nothing else to look at. Progress also goes to logs\<name>.log.
cd /d "%~dp0"

set NAME=%1
if "%NAME%"=="" set /p NAME=instance name (letters/digits only, e.g. wa02):
if "%NAME%"=="" goto :nothing

rem 2048, not 1536: the system image silently raises anything lower ("Increasing RAM
rem size to 2048MB"), so asking for less only made the log lie.
set RAM=%2
if "%RAM%"=="" set RAM=2048

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0android.ps1" -New "%NAME%" -Ram %RAM%
echo.
echo ---- exit code: %ERRORLEVEL% ----
pause
goto :eof

:nothing
echo no name given, nothing created.
pause
