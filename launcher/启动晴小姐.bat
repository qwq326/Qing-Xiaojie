@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StartQingAll.ps1"
if errorlevel 1 echo Launcher exited with an error.
