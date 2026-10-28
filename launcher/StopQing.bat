@echo off
setlocal
title Qing Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StopQingAll.ps1" -Force
echo.
timeout /t 5 >nul
endlocal
