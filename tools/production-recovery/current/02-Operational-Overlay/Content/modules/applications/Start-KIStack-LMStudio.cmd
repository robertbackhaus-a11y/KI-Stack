@echo off
setlocal EnableExtensions DisableDelayedExpansion
title KI-Stack LM Studio
set "LMS_CLI="
set "LMSTUDIO_EXE=C:\Program Files\LM Studio\LM Studio.exe"
if not defined LMS_CLI for /f "delims=" %%I in ('where lms.exe 2^>nul') do if not defined LMS_CLI set "LMS_CLI=%%~fI"
if not defined LMS_CLI for /f "delims=" %%I in ('where lms.cmd 2^>nul') do if not defined LMS_CLI set "LMS_CLI=%%~fI"
if not defined LMS_CLI if exist "%USERPROFILE%\.lmstudio\bin\lms.exe" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.exe"
if not defined LMS_CLI if exist "%USERPROFILE%\.lmstudio\bin\lms.cmd" set "LMS_CLI=%USERPROFILE%\.lmstudio\bin\lms.cmd"
if defined LMS_CLI if exist "%LMS_CLI%" (
    call "%LMS_CLI%" server start --port 1234 --bind 127.0.0.1
    exit /b %ERRORLEVEL%
)
if defined LMSTUDIO_EXE if exist "%LMSTUDIO_EXE%" (
    start "" "%LMSTUDIO_EXE%"
    echo LM Studio wurde gestartet. Nach dem ersten Start steht der lms-Befehl zur Verfügung.
    exit /b 0
)
echo LM Studio ist installiert, aber weder lms noch die Programmdatei wurden aufgelöst.
echo LM Studio einmal manuell starten und danach dieses Skript erneut ausführen.
pause
exit /b 1
