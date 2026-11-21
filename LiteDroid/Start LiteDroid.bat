@echo off
rem LiteDroid - open the manager window (no admin rights needed)
setlocal
set "SCRIPT=%~dp0LiteDroid.ps1"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
exit /b 0
