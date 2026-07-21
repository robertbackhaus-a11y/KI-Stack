@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-OpenWebUIImagePack.ps1"
exit /b %errorlevel%
