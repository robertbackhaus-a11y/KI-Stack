@echo off
setlocal
set "ROOT=%~dp0"
set "LOG=%ROOT%KI-Stack-Audit-output.txt"
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (
  echo FEHLER: PowerShell 7 wurde nicht gefunden.
  echo Erwarteter Pfad: "%ProgramFiles%\PowerShell\7\pwsh.exe"
  pause
  exit /b 70
)

echo KI-Stack Complete Installer - Audit
echo PowerShell: "%PWSH%"
echo Ausgabe:    "%LOG%"
echo.

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Invoke-KIStackCompleteInstaller.ps1" -Mode Audit > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

type "%LOG%"
echo.
if "%RC%"=="0" (
  echo AUDIT BEENDET. Exitcode 0.
) else (
  echo AUDIT FEHLGESCHLAGEN. Exitcode %RC%.
)
echo Vollstaendige Ausgabe: "%LOG%"
pause
exit /b %RC%
