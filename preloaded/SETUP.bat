@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare.ps1"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" (echo SETUP STATUS: SUCCESS) else (echo SETUP STATUS: FAILURE)
echo Press any key to close this window.
pause >nul
exit /b %RESULT%
