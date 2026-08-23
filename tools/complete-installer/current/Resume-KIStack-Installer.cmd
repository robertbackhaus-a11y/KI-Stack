@echo off
chcp 65001 >nul
setlocal
set "ROOT=%~dp0"
set "LOG=%ROOT%KI-Stack-Installer-output.txt"
set "TX=%~1"
if not defined TX set /p "TX=TransactionId fuer Resume eingeben: "
if not defined TX (echo FEHLER: Resume erfordert eine TransactionId.& exit /b 2)
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (echo FEHLER: PowerShell 7 wurde nicht gefunden.& exit /b 70)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Start-KIStackCompleteInstaller.ps1" -Resume -TransactionId "%TX%"
set "RC=%ERRORLEVEL%"

if exist "%LOG%" type "%LOG%"
if exist "%LOG%.stderr.txt" type "%LOG%.stderr.txt"
echo.
if "%RC%"=="0" (
  echo INSTALLATION BEENDET. Exitcode 0.
) else if "%RC%"=="31" (
  echo NEUSTART ERFORDERLICH. Danach Resume-KIStack-Installer.cmd mit der TransactionId aus der Ausgabe starten. Exitcode 31.
) else (
  echo INSTALLATION FEHLGESCHLAGEN. Exitcode %RC%.
)
if exist "%LOG%" echo Vollstaendige Ausgabe: "%LOG%"
if exist "%LOG%.bootstrap.jsonl" echo Bootstrap-Diagnose:   "%LOG%.bootstrap.jsonl"
if exist "%LOG%.stderr.txt" echo Fehlerausgabe:        "%LOG%.stderr.txt"
if exist "%LOG%.transcript.txt" echo Transcript:           "%LOG%.transcript.txt"
if exist "%LOG%.exitcode.txt" echo Exitcode:             "%LOG%.exitcode.txt"
pause
exit /b %RC%
