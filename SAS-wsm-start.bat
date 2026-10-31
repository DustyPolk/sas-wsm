@echo off
setlocal EnableExtensions
title SAS-wsm start
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel%==0 goto :run

echo Requesting administrator approval to start SAS services...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
if errorlevel 1 (
    echo Administrator approval was not granted.
    pause
)
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SAS-wsm.ps1" -action start
set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
    echo SAS-wsm start completed.
) else (
    echo SAS-wsm start failed with exit code %EXITCODE%.
)
pause
exit /b %EXITCODE%
