@echo off
setlocal EnableExtensions DisableDelayedExpansion
start "KI-Stack LM Studio" cmd.exe /D /C call "C:\KI-Stack\modules\applications\Start-KIStack-LMStudio.cmd"
timeout /t 3 /nobreak >nul
start "KI-Stack Open WebUI" cmd.exe /D /K call "C:\KI-Stack\modules\applications\Start-KIStack-OpenWebUI.cmd"
exit /b 0