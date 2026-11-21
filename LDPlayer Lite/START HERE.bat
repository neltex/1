@echo off
setlocal
cd /d "%TEMP%"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0LDPlayer-Lite.ps1"
pause
