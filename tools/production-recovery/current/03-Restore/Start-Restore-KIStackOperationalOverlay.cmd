@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack Operational Recovery

set "PYTHON="
if exist "C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe" set "PYTHON=C:\KI-Stack\python\venvs\openwebui\Scripts\python.exe"
if not defined PYTHON if exist "C:\KI-Stack\python\venvs\comfyui\Scripts\python.exe" set "PYTHON=C:\KI-Stack\python\venvs\comfyui\Scripts\python.exe"
if not defined PYTHON for /f "delims=" %%I in ('where py.exe 2^>nul') do if not defined PYTHON set "PYTHON=%%I"
if not defined PYTHON for /f "delims=" %%I in ('where python.exe 2^>nul') do if not defined PYTHON set "PYTHON=%%I"

if not defined PYTHON (
  echo Python wurde nicht gefunden.
  pause
  exit /b 1
)

"%PYTHON%" "%~dp0Apply-KIStackOperationalOverlay.py"
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
