@echo off
rem Runs submit.ps1 from a plain command prompt. See README.md, or "submit -?".
if "%~1"=="-?" goto help
if "%~1"=="/?" goto help
if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0submit.ps1" %*
exit /b %ERRORLEVEL%

:help
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Help '%~dp0submit.ps1' -Detailed"
exit /b 0
