@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "%~dp0Start-KIStack-SearXNG.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
start "KI-Stack LM Studio" cmd.exe /D /C call "C:\KI-Stack\modules\applications\Start-KIStack-LMStudio.cmd"
timeout /t 3 /nobreak >nul
start "KI-Stack Open WebUI + SearXNG" cmd.exe /D /K call "%~dp0Start-KIStack-OpenWebUI-WithSearch.cmd"
exit /b 0