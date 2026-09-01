@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ENABLE_WEB_SEARCH=True"
set "WEB_SEARCH_ENGINE=searxng"
set "WEB_SEARCH_RESULT_COUNT=5"
set "WEB_SEARCH_CONCURRENT_REQUESTS=3"
set "WEB_LOADER_CONCURRENT_REQUESTS=5"
set "SEARXNG_QUERY_URL=http://localhost/searxng/search?q=<query>"
for %%I in ("%~dp0..") do set "MODULE_ROOT=%%~fI"
call "%MODULE_ROOT%\applications\Start-KIStack-OpenWebUI.cmd"
exit /b %ERRORLEVEL%
