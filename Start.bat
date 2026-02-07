@echo off
:: OpenClaw Launcher
:: Double-click this file to open the OpenClaw menu

title OpenClaw

:: Check if already running as admin
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    goto :elevate
)

:elevate
:: Request admin privileges
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:run
:: Change to script directory
cd /d "%~dp0"

:: Run the menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1"

:: Keep window open if there was an error
if errorlevel 1 pause
