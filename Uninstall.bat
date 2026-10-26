@echo off
title WhatsApp Phones - Uninstall
rem Leave the install folder first so Windows lets the script delete it.
cd /d "%TEMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1" %*
