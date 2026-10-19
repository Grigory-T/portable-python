@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0portable-python.ps1" (
    echo.
    echo LAUNCHER STATUS: FAILURE
    echo Missing technical launcher: portable-python.ps1
    echo Overall exit code: 30
    set "FINAL_EXIT_CODE=30"
    goto finish
)

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" (
    echo.
    echo LAUNCHER STATUS: FAILURE
    echo Windows PowerShell was not found.
    echo Overall exit code: 30
    set "FINAL_EXIT_CODE=30"
    goto finish
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable-python.ps1" -NoPause
set "TECHNICAL_EXIT_CODE=%ERRORLEVEL%"

if "%TECHNICAL_EXIT_CODE%"=="0" (
    set "FINAL_EXIT_CODE=0"
    goto finish
)
if "%TECHNICAL_EXIT_CODE%"=="10" (
    set "FINAL_EXIT_CODE=10"
    goto finish
)
if "%TECHNICAL_EXIT_CODE%"=="20" (
    set "FINAL_EXIT_CODE=20"
    goto finish
)
if "%TECHNICAL_EXIT_CODE%"=="30" (
    set "FINAL_EXIT_CODE=30"
    goto finish
)

echo.
echo LAUNCHER STATUS: FAILURE
echo Unexpected technical exit code: %TECHNICAL_EXIT_CODE%
echo Overall exit code: 30
set "FINAL_EXIT_CODE=30"

:finish
echo.
if "%FINAL_EXIT_CODE%"=="0" echo START STATUS: SUCCESS
if "%FINAL_EXIT_CODE%"=="10" echo START STATUS: PORTABLE PYTHON FAILURE
if "%FINAL_EXIT_CODE%"=="20" echo START STATUS: APPLICATION FAILURE
if "%FINAL_EXIT_CODE%"=="30" echo START STATUS: LAUNCHER FAILURE
echo Press any key to close this window.
pause >nul
exit /b %FINAL_EXIT_CODE%
