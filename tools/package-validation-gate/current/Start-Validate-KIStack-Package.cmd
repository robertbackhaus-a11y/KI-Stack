@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "PACKAGE=%~1"
if not defined PACKAGE (
  set /p "PACKAGE=Vollstaendigen Pfad zum finalen KI-Stack-ZIP eingeben: "
)
if not defined PACKAGE (
  echo Kein Paket angegeben.
  exit /b 2
)
set "PWSH="
for %%P in (pwsh.exe) do if not defined PWSH for /f "delims=" %%I in ('where %%P 2^>nul') do if not defined PWSH set "PWSH=%%I"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined LOCALAPPDATA if exist "%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe"
if not defined PWSH (
  echo PowerShell 7 wurde nicht gefunden.
  exit /b 3
)
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Invoke-KIStack-PackageValidationGate.ps1" -PackagePath "%PACKAGE%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo Paket wurde vom Validation Gate abgewiesen. Exitcode: %RC%
exit /b %RC%
