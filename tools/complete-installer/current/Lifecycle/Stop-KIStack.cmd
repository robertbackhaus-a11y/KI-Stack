@echo off
setlocal
set "TARGET=C:\KI-Stack\modules\cutover\Stop-KIStack.cmd"
if not exist "%TARGET%" (echo FEHLER: Zentraler Stop fehlt: %TARGET%& exit /b 2)
call "%TARGET%"
exit /b %ERRORLEVEL%
