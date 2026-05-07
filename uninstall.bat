@echo off
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0uninstall.ps1" %*
if errorlevel 1 (
    echo.
    echo Uninstall failed. Press any key to close.
    pause >nul
)
