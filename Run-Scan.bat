@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CPanCleaner.ps1" -Action Scan -Include Default
pause
