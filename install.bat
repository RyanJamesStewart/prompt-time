@echo off
REM Strip Mark-of-the-Web from extracted .ps1 files before invoking them.
REM Without this, Windows can refuse to execute PowerShell scripts that
REM came from a downloaded zip even with `-ExecutionPolicy Bypass`,
REM particularly under corporate AppLocker / SmartScreen / GPO settings.
REM The watcher would then fail to start AFTER Claude Desktop restarts,
REM and the MCP tools would be missing with no obvious error.
powershell -ExecutionPolicy Bypass -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -Filter '*.ps1' | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" %*
if errorlevel 1 (
    echo.
    echo Install failed. Press any key to close.
    pause >nul
)
