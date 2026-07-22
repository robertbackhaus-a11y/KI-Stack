@echo off
setlocal
set "ROOT=%~dp0"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh.exe"
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Test-KIStackCompleteInstaller.ps1"
exit /b %ERRORLEVEL%
