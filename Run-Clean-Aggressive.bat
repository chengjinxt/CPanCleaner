@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0CPanCleaner.ps1' -Action Clean -Include @('WindowsUpdate','DeliveryOptimization','OldQuarantine','NetLimiterStats') -Apply -Elevate"
pause
