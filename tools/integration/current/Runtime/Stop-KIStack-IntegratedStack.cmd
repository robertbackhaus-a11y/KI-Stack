@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0..") do set "MODULE_ROOT=%%~fI"
call "%MODULE_ROOT%\applications\Stop-KIStack-Applications.cmd"
call "%~dp0Stop-KIStack-SearXNG.cmd"
exit /b %ERRORLEVEL%
