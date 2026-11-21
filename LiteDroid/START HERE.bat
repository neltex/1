@echo off
rem ============================================================
rem  LiteDroid - the only file you need to double-click.
rem
rem  First time : installs everything (needs admin + reboot maybe)
rem  After that : just opens the LiteDroid window
rem ============================================================
title LiteDroid
setlocal
cd /d "%~dp0"

rem ---- is the Android runtime already installed? -------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Get-AppxPackage -Name MicrosoftCorporationII.WindowsSubsystemForAndroid -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 goto install

rem ---- already installed: just open the window ---------------------------
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LiteDroid.ps1"
exit /b 0

:install
echo.
echo   ==========================================================
echo    LiteDroid is not installed on this PC yet.
echo.
echo    This one-time step downloads about 550 MB and needs
echo    administrator rights. It takes 5-15 minutes.
echo   ==========================================================
echo.

net session >nul 2>&1
if not errorlevel 1 goto runsetup

echo   Asking Windows for permission...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b 0

:runsetup
title LiteDroid setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Setup.ps1"
exit /b 0
