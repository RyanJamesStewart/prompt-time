@echo off
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" %*
if errorlevel 1 (
    echo.
    echo Install failed. Press any key to close.
    pause >nul
)
