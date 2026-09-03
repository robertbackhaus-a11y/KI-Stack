@echo off
setlocal
set "TARGET=%~dp0modules\cutover\Stop-KIStack.cmd"
if not exist "%TARGET%" (echo FEHLER: Zentraler Stop fehlt: %TARGET%& exit /b 2)
call "%TARGET%"
set "EC=%ERRORLEVEL%"
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-KIStack-Managed.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
exit /b %EC%
