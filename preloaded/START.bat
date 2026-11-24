@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" goto launcher_error
if not exist "%~dp0portable-python.ps1" goto launcher_error
if not exist "%~dp0portable-common.ps1" goto launcher_error
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable-python.ps1" -NoPause
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" echo START STATUS: SUCCESS
if "%RESULT%"=="10" echo START STATUS: PORTABLE PYTHON FAILURE
if "%RESULT%"=="20" echo START STATUS: APPLICATION FAILURE
if "%RESULT%"=="0" goto finish
if "%RESULT%"=="10" goto finish
if "%RESULT%"=="20" goto finish
:launcher_error
echo START STATUS: LAUNCHER FAILURE
set "RESULT=30"
:finish
echo Press any key to close this window.
pause >nul
exit /b %RESULT%
