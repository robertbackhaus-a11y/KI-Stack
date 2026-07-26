@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-OpenWebUIBallisticsPack.ps1" -Mode DryRun
exit /b %ERRORLEVEL%
