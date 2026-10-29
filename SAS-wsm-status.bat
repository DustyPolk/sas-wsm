@echo off
setlocal EnableExtensions
title SAS-wsm status
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SAS-wsm.ps1" -action status
set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
    echo SAS-wsm status completed.
) else (
    echo SAS-wsm status failed with exit code %EXITCODE%.
)
pause
exit /b %EXITCODE%
