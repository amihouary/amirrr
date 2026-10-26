@echo off
rem Double-click me. Opens the instance manager window:
rem   list / New / Clone / Rename / Delete / Start / Stop / Cold boot /
rem   Paste / Check / Network / Retune / Identity / Logs / Folder / Launchers /
rem   Requirements / Settings / Stop all
rem
rem   Requirements  what is installed, what is missing and what is too slow on this
rem                 machine, with what to do about each - plus a button that downloads
rem                 the missing SDK parts. Same report: android.ps1 -Requirements
rem   Settings      where the SDK, the JDK and the instances live -> settings.ini
rem   New           asks what kind of device it should look like (screen, region, SIM
rem                 number, RAM). Identity asks the same for an instance that exists.
rem
rem No console anywhere: every button runs android.ps1 hidden and everything it prints
rem lands in logs\<instance>.log. "Logs" tails that live (logs.bat opens it directly).
rem "Stop all" is the panic button and closes this window too, by design.
rem Every button also works from a terminal - see the top of android.ps1.
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0manager.ps1"
