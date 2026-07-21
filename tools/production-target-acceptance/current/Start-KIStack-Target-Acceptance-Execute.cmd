@echo off
setlocal EnableExtensions DisableDelayedExpansion
echo === KI-Stack Production Target Acceptance v1.0.9 - Execute ===
if not exist "%~dp0VERSION" (
  echo FEHLER: VERSION-Datei fehlt.
  pause
  exit /b 1
)
set /p "PACKAGE_VERSION="<"%~dp0VERSION"
if not "%PACKAGE_VERSION%"=="1.0.9" (
  echo FEHLER: Falsche Paketversion. Erwartet 1.0.9, gefunden %PACKAGE_VERSION%.
  pause
  exit /b 1
)
title KI-Stack Production Target Acceptance v1.0.9 - Execute
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH if exist "%%~fI" set "PWSH=%%~fI"
if not defined PWSH (
  echo FEHLER: PowerShell 7 wurde nicht gefunden.
  echo.
  pause
  exit /b 1
)
pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
  echo FEHLER: Paketverzeichnis konnte nicht geoeffnet werden.
  echo.
  pause
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-KIStack-Target-Acceptance-Package.ps1"
if errorlevel 1 (
  echo.
  echo Paket-Selbsttest fehlgeschlagen.
  echo.
  pause
  popd
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-KIStack-Target-Acceptance.ps1" -Mode Execute
set "EC=%ERRORLEVEL%"
echo.
if "%EC%"=="0" (echo Zielsystemabnahme erfolgreich.) else (echo Zielsystemabnahme fehlgeschlagen. Exitcode: %EC%)
echo.
pause
popd
exit /b %EC%
