@echo off
setlocal
set "TARGET=C:\KI-Stack\modules\cutover\Start-KIStack.cmd"
if not exist "%TARGET%" (echo FEHLER: Zentraler Start fehlt: %TARGET%& exit /b 2)
call "%TARGET%"
exit /b %ERRORLEVEL%
