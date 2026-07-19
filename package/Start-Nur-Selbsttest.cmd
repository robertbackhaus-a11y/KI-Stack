@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "BOOTSTRAP=%~dp0Bootstrap-KIStack-ModelsWorkflows.cmd"

if not exist "%BOOTSTRAP%" (
    echo.
    echo FEHLER: Bootstrap-KIStack-ModelsWorkflows.cmd fehlt.
    echo Paketpfad: %~dp0
    echo.
    echo Die Diagnosesitzung bleibt geoeffnet.
    "%ComSpec%" /D /K
    exit /b 1
)

"%ComSpec%" /D /K ""%BOOTSTRAP%" SelfTest "KI-Stack Models/Workflows - Selbsttest""
exit /b %ERRORLEVEL%
