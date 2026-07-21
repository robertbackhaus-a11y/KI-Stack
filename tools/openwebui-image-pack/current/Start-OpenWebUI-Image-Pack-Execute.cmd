@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-OpenWebUIImagePack.ps1" -Action Execute
exit /b %errorlevel%
