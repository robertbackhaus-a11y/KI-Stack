@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-OpenWebUIBallisticsPack.ps1"
exit /b %ERRORLEVEL%
