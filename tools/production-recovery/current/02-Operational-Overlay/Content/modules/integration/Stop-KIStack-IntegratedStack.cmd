@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "C:\KI-Stack\modules\applications\Stop-KIStack-Applications.cmd"
call "%~dp0Stop-KIStack-SearXNG.cmd"
exit /b %ERRORLEVEL%