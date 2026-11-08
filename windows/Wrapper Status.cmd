@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0backend.ps1" -Action Status %*
set "wrapper_result=%errorlevel%"
pause
exit /b %wrapper_result%
