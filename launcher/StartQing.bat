@echo off
setlocal
title Qing Launcher
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StartQingAll.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo Launcher exited with error code %RC%.
pause
endlocal
