@echo off
REM prompt-time diagnostic launcher.
REM Run this AFTER restarting Claude Desktop if the tools don't appear.
REM Strip MoTW first (same precaution as install.bat) so PowerShell doesn't
REM refuse to load diagnose.ps1 from a downloaded zip.
powershell -ExecutionPolicy Bypass -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -Filter '*.ps1' | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0diagnose.ps1" %*
echo.
pause
