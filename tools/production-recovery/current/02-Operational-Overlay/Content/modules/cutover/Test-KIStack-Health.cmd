@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH if exist "%%~fI" set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& set "EC=1"& goto :Finish)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-KIStack-Health.ps1"
set "EC=%ERRORLEVEL%"
:Finish
echo.
if "%EC%"=="0" (echo Vorgang erfolgreich abgeschlossen. Exitcode: 0) else (echo Vorgang fehlgeschlagen. Exitcode: %EC%)
echo Druecken Sie eine beliebige Taste, um dieses Fenster zu schliessen.
pause >nul
exit /b %EC%