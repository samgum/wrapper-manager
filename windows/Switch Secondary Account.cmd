@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0account-login.ps1" -Profile secondary %*
set "wrapper_result=%errorlevel%"
pause
exit /b %wrapper_result%
