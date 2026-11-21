@echo off
setlocal
rem Run from TEMP so this command window does not lock the extracted folder.
set "cleanup=%~dp0CLOSE AND UNLOCK.ps1"
cd /d "%TEMP%"
net session >nul 2>&1
if errorlevel 1 (
  echo Asking Windows for permission to close the old installer processes...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%cleanup%"
pause
