@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-OpenWebUIAgentPack.ps1" -Action DryRun
exit /b %errorlevel%
