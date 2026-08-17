@echo off
setlocal
set "ROOT=%~dp0"
set "VALIDATOR=%ROOT%scripts\Invoke-KIStackCompleteInstallerRCBuildValidation.ps1"
if not exist "%VALIDATOR%" (
  echo FEHLER: Das Build-Kit wurde nicht vollstaendig entpackt.
  echo.
  echo Die ZIP-Datei nicht direkt oeffnen und den Starter nicht aus der
  echo Windows-ZIP-Vorschau ausfuehren.
  echo Bitte die ZIP-Datei zuerst ueber "Alle extrahieren" in einen neuen
  echo Ordner entpacken und den Starter dort erneut ausfuehren.
  echo.
  echo Erwartete Datei:
  echo %VALIDATOR%
  pause
  exit /b 66
)
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%~fI"
if not defined PWSH (
  echo FEHLER: PowerShell 7 wurde nicht gefunden.
  pause
  exit /b 70
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%VALIDATOR%"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo ERFOLG: Build und Quellvalidierung abgeschlossen.
  echo Ergebnis: %ROOT%dist\complete-installer-rc-validation
) else (
  echo FEHLER: Build oder Quellvalidierung fehlgeschlagen. Exitcode %RC%.
)
pause
exit /b %RC%
