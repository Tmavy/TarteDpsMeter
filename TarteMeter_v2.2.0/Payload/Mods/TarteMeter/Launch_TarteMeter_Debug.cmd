@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0DPSWindow.ps1"
