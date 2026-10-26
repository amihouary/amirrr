@echo off
title WhatsApp Phones
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-phone.ps1" %*
timeout /t 5 >nul
