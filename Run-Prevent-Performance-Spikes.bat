@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0CPanCleaner.ps1' -Action PreventPerformanceSpikes -Apply -Elevate"
pause
