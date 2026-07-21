@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack Open WebUI
set "OPENWEBUI_ROOT=C:\KI-Stack\OpenWebUI"
set "DATA_DIR=C:\KI-Stack\OpenWebUI\data"
set "OPENWEBUI_LAUNCHER=C:\KI-Stack\python\venvs\openwebui\Scripts\open-webui.exe"
set "ENABLE_OLLAMA_API=False"
set "ENABLE_OPENAI_API=True"
set "OPENAI_API_BASE_URL=http://127.0.0.1:1234/v1"
set "OPENAI_API_KEY=lm-studio"
set "SCARF_NO_ANALYTICS=true"
set "DO_NOT_TRACK=true"
set "ANONYMIZED_TELEMETRY=false"
set "PYTHONNOUSERSITE=1"

if not exist "%OPENWEBUI_LAUNCHER%" (
  echo FEHLER: Open-WebUI-Launcher fehlt: %OPENWEBUI_LAUNCHER%
  exit /b 1
)
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%" 2>nul
if not exist "%DATA_DIR%" (
  echo FEHLER: Open-WebUI-Datenverzeichnis konnte nicht angelegt werden: %DATA_DIR%
  exit /b 1
)
if not exist "%OPENWEBUI_ROOT%" mkdir "%OPENWEBUI_ROOT%" 2>nul
pushd "%OPENWEBUI_ROOT%"
"%OPENWEBUI_LAUNCHER%" serve --host 127.0.0.1 --port 8080
set "EC=%ERRORLEVEL%"
popd
echo.
echo Open WebUI wurde beendet. Exitcode: %EC%
pause
exit /b %EC%
