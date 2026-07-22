@echo off
setlocal
set "ROOT=%~dp0"
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Invoke-KIStackCompleteInstaller.ps1" -Mode Upgrade
exit /b %ERRORLEVEL%
