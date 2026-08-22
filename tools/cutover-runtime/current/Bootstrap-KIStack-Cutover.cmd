@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ACTION=%~1"
set "WINDOW_TITLE=%~2"
set "ELEVATION_MARKER=%~3"
set "PACKAGE_ROOT=%~dp0"
set "EXITCODE=1"
set "FAIL_MESSAGE="

if not defined TEMP set "TEMP=%SystemRoot%\Temp"
set "TEMP_LOG=%TEMP%\KI-Stack-Cutover-Bootstrap.log"
set "LOCAL_STATE=%PACKAGE_ROOT%State\Starter"
set "LOCAL_LOG=%LOCAL_STATE%\Bootstrap-latest.log"

if defined WINDOW_TITLE title %WINDOW_TITLE%

if not exist "%LOCAL_STATE%" md "%LOCAL_STATE%" >nul 2>&1

call :Log "============================================================"
call :Log "Bootstrap gestartet."
call :Log "Aktion: %ACTION%"
call :Log "Elevation-Marker: %ELEVATION_MARKER%"
call :Log "Paketwurzel: %PACKAGE_ROOT%"
call :Log "ComSpec: %ComSpec%"

if /I "%ACTION%"=="SelfTest" goto :ActionValid
if /I "%ACTION%"=="DryRun" goto :ActionValid
if /I "%ACTION%"=="Execute" goto :ActionValid
set "FAIL_MESSAGE=Unbekannte Starteraktion: %ACTION%"
goto :Fail

:ActionValid
pushd "%PACKAGE_ROOT%" >nul 2>&1
if errorlevel 1 (
    set "FAIL_MESSAGE=Das Paketverzeichnis konnte nicht geoeffnet werden: %PACKAGE_ROOT%"
    goto :Fail
)

call :FindPowerShell
if not defined PWSH (
    set "FAIL_MESSAGE=PowerShell 7 wurde weder unter ProgramW6432, ProgramFiles noch im PATH gefunden."
    goto :FailAfterPushd
)

call :Log "PowerShell 7: %PWSH%"

if not exist "%PACKAGE_ROOT%Start-KIStack-Cutover.ps1" (
    set "FAIL_MESSAGE=Start-KIStack-Cutover.ps1 fehlt."
    goto :FailAfterPushd
)
if not exist "%PACKAGE_ROOT%Request-KIStack-Elevation.ps1" (
    set "FAIL_MESSAGE=Request-KIStack-Elevation.ps1 fehlt."
    goto :FailAfterPushd
)
if not exist "%PACKAGE_ROOT%Core\KIStack.Starter.psm1" (
    set "FAIL_MESSAGE=Core\KIStack.Starter.psm1 fehlt."
    goto :FailAfterPushd
)
if not exist "%PACKAGE_ROOT%Invoke-KIStackBuilderKernel.ps1" (
    set "FAIL_MESSAGE=Invoke-KIStackBuilderKernel.ps1 fehlt."
    goto :FailAfterPushd
)
if not exist "%PACKAGE_ROOT%Tests\Test-KIStackBuilderKernel.ps1" (
    set "FAIL_MESSAGE=Tests\Test-KIStackBuilderKernel.ps1 fehlt."
    goto :FailAfterPushd
)
if not exist "%PACKAGE_ROOT%Config\kernel-config.json" (
    set "FAIL_MESSAGE=Config\kernel-config.json fehlt."
    goto :FailAfterPushd
)

if /I not "%ACTION%"=="Execute" goto :AfterElevation
call :EnsureElevation
if errorlevel 20 goto :ElevationHandedOff
if errorlevel 1 goto :FailAfterPushd

:AfterElevation
set "KI_STACK_LAUNCHED_FROM_CMD=1"
call :Log "PowerShell-Starter wird aufgerufen."
echo.
echo ============================================================
echo KI-Stack Cutover v1.6.10 - %ACTION%
echo ============================================================
echo Paket: %PACKAGE_ROOT%
echo PowerShell: %PWSH%
echo Bootstrap-Log: %TEMP_LOG%
if /I "%ACTION%"=="Execute" echo Elevation-Log: %TEMP%\KI-Stack-Cutover-Elevation.log
echo.

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACKAGE_ROOT%Start-KIStack-Cutover.ps1" -Action "%ACTION%"
set "EXITCODE=%ERRORLEVEL%"
call :Log "PowerShell-Starter beendet. Exitcode: %EXITCODE%"

popd
goto :Finish

:ElevationHandedOff
call :Log "Erhoehter Execute-Prozess wurde gestartet. Nicht erhoehtes Fenster wird geschlossen."
popd
exit 0

:FailAfterPushd
popd

:Fail
call :Log "FEHLER: %FAIL_MESSAGE%"
echo.
echo START FEHLGESCHLAGEN: %FAIL_MESSAGE%
echo.
echo Bootstrap-Log: %TEMP_LOG%
if exist "%LOCAL_LOG%" echo Paket-Log: %LOCAL_LOG%
set "EXITCODE=1"

:Finish
echo.
if "%EXITCODE%"=="0" (
    echo Vorgang erfolgreich abgeschlossen. Exitcode: 0
) else (
    echo Vorgang fehlgeschlagen. Exitcode: %EXITCODE%
)
echo Bootstrap-Log: %TEMP_LOG%
if /I "%ACTION%"=="Execute" echo Elevation-Log: %TEMP%\KI-Stack-Cutover-Elevation.log
if exist "%LOCAL_LOG%" echo Paket-Log: %LOCAL_LOG%
echo.
echo Druecken Sie eine beliebige Taste, um dieses Fenster zu schliessen.
pause >nul
exit /b %EXITCODE%

:EnsureElevation
if /I "%ELEVATION_MARKER%"=="Elevated" exit /b 0
call :Log "Execute: Administratorstatus wird geprueft; falls erforderlich wird UAC automatisch angefordert."
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACKAGE_ROOT%Request-KIStack-Elevation.ps1" -BootstrapPath "%PACKAGE_ROOT%Bootstrap-KIStack-Cutover.cmd" -Action Execute -WindowTitle "%WINDOW_TITLE%"
set "ELEVATION_RESULT=%ERRORLEVEL%"
call :Log "UAC-Helfer beendet. Exitcode: %ELEVATION_RESULT%"
if "%ELEVATION_RESULT%"=="10" exit /b 20
if not "%ELEVATION_RESULT%"=="0" (
    set "FAIL_MESSAGE=Die automatische UAC-Elevation ist fehlgeschlagen oder wurde abgebrochen. Siehe %TEMP%\KI-Stack-Cutover-Elevation.log"
    exit /b 1
)
exit /b 0

:FindPowerShell
set "PWSH="
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH if exist "%%~fI" set "PWSH=%%~fI"
exit /b 0

:Log
>>"%TEMP_LOG%" echo [%DATE% %TIME%] %~1
if exist "%LOCAL_STATE%" >>"%LOCAL_LOG%" echo [%DATE% %TIME%] %~1
exit /b 0
