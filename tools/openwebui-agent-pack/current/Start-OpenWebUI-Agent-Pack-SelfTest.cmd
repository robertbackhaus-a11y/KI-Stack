@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-OpenWebUIAgentPack.ps1"
exit /b %errorlevel%
