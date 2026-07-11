@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CPanCleaner.ps1" -Action Clean -Include NetLimiterStats -Apply -Elevate
pause
