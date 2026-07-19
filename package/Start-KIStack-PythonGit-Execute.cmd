@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "BOOTSTRAP=%~dp0Bootstrap-KIStack-PythonGit.cmd"

if not exist "%BOOTSTRAP%" (
    echo.
    echo FEHLER: Bootstrap-KIStack-PythonGit.cmd fehlt.
    echo Paketpfad: %~dp0
    echo.
    echo Die Diagnosesitzung bleibt geoeffnet.
    "%ComSpec%" /D /K
    exit /b 1
)

"%ComSpec%" /D /K ""%BOOTSTRAP%" Execute "KI-Stack PythonGit - Execute""
exit /b %ERRORLEVEL%
