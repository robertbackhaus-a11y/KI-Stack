@echo off
setlocal
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\complete\Invoke-KIStackCompleteInstaller.ps1" -Mode Stop -TargetRoot "%~dp0."
set "EC=%ERRORLEVEL%"
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-KIStack-Managed.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
exit /b %EC%
