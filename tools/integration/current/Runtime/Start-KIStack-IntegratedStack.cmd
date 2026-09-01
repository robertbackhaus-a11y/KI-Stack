@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "%~dp0Start-KIStack-SearXNG.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
for %%I in ("%~dp0..") do set "MODULE_ROOT=%%~fI"
start "KI-Stack LM Studio" cmd.exe /D /C call "%MODULE_ROOT%\applications\Start-KIStack-LMStudio.cmd"
timeout /t 3 /nobreak >nul
start "KI-Stack Open WebUI + SearXNG" cmd.exe /D /K call "%~dp0Start-KIStack-OpenWebUI-WithSearch.cmd"
exit /b 0
