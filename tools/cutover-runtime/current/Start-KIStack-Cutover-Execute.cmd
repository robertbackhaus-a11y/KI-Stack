@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "BOOTSTRAP=%~dp0Bootstrap-KIStack-Cutover.cmd"

if not exist "%BOOTSTRAP%" (
    echo.
    echo FEHLER: Bootstrap-KIStack-Cutover.cmd fehlt.
    echo Paketpfad: %~dp0
    echo.
    echo Die Diagnosesitzung bleibt geoeffnet.
    "%ComSpec%" /D /K
    exit /b 1
)

"%ComSpec%" /D /C ""%BOOTSTRAP%" Execute "KI-Stack Cutover - Execute""
exit /b %ERRORLEVEL%
