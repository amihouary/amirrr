@echo off
title WhatsApp Web shortcuts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\web-shortcuts.ps1" %*
echo.
pause
