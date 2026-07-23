@echo off
setlocal
call "%~dp0Lifecycle\Status-KIStack-Interactive.cmd"
exit /b %ERRORLEVEL%
