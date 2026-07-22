@echo off
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-KIStackSystemCleanup.ps1" -Mode Audit
