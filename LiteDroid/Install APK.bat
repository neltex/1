@echo off
rem LiteDroid - drag one or more .apk files onto this file to install them.
rem They are sideloaded into the Android runtime and opened straight away.
setlocal
if "%~1"=="" (
    echo Drag one or more .apk files onto this file.
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LiteDroid.ps1" -Apk %*
echo.
if errorlevel 1 (
    echo Install failed - see C:\LiteDroid\logs for details.
    pause
)
exit /b %errorlevel%
