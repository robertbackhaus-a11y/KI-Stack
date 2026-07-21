@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-OpenWebUIImagePack.ps1" -Action DryRun
exit /b %errorlevel%
