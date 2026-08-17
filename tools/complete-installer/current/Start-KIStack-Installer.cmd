@echo off
chcp 65001 >nul
setlocal
set "ROOT=%~dp0"
set "LOG=%ROOT%KI-Stack-Installer-output.txt"
set "PWSH="
if not exist "%ROOT%Start-KIStackCompleteInstaller.ps1" (
  echo FEHLER: Das Installer-Paket ist nicht vollstaendig entpackt.
  echo Bitte das ZIP mit "Alle extrahieren" in einen neuen Ordner entpacken.
  pause
  exit /b 66
)
if not exist "%ROOT%CompleteInstaller.psm1" (
  echo FEHLER: CompleteInstaller.psm1 fehlt. Das Paket ist unvollstaendig.
  pause
  exit /b 66
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (
  echo FEHLER: PowerShell 7 wurde nicht gefunden.
  echo Erwarteter Pfad: "%ProgramFiles%\PowerShell\7\pwsh.exe"
  pause
  exit /b 70
)

echo KI-Stack Complete Installer - Execute
echo PowerShell: "%PWSH%"
echo Ziel:       C:\KI-Stack
echo Ausgabe:    "%LOG%"
echo.
echo HINWEIS: Die folgende Ausfuehrung darf das Zielsystem veraendern.
echo.

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Start-KIStackCompleteInstaller.ps1" -LogPath "%LOG%"
set "RC=%ERRORLEVEL%"

if exist "%LOG%" type "%LOG%"
if exist "%LOG%.stderr.txt" type "%LOG%.stderr.txt"
echo.
if "%RC%"=="0" (
  echo INSTALLATION BEENDET. Exitcode 0.
) else (
  echo INSTALLATION FEHLGESCHLAGEN. Exitcode %RC%.
)
echo Vollstaendige Ausgabe: "%LOG%"
echo Fehlerausgabe:        "%LOG%.stderr.txt"
echo Transcript:           "%LOG%.transcript.txt"
echo Exitcode:             "%LOG%.exitcode.txt"
pause
exit /b %RC%
