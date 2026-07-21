@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "PWSH="
for %%P in (pwsh.exe) do if not defined PWSH for /f "delims=" %%I in ('where %%P 2^>nul') do if not defined PWSH set "PWSH=%%I"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined LOCALAPPDATA if exist "%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe"
if not defined PWSH (
  echo PowerShell 7 wurde nicht gefunden.
  pause
  exit /b 3
)
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Install-KIStack-ValidationGate.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo Installation fehlgeschlagen. Exitcode: %RC%
pause
exit /b %RC%
