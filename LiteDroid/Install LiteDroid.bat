@echo off
rem LiteDroid - one-time installer. Self-elevates, then runs Setup.ps1.
rem   Install LiteDroid.bat                     ultra-light profile
rem   Install LiteDroid.bat -Profile balanced   keep Google Play services
rem   Install LiteDroid.bat -Replace            wipe + reinstall the runtime
setlocal
net session >nul 2>&1
if %errorlevel%==0 goto run

echo Requesting administrator rights...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
exit /b 0

:run
title LiteDroid setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
