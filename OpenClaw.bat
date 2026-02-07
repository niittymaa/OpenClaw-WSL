@echo off
title OpenClaw
setlocal EnableDelayedExpansion

REM ============================================================================
REM OpenClaw Launcher
REM Stops any existing gateway, opens browser, spawns gateway in new window
REM ============================================================================

cd /d "%~dp0"

REM Path relocation check
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '%~dp0modules\PathRelocation.psm1' -Force; $result = Invoke-PathRelocationCheck -CurrentPath '%~dp0'.TrimEnd('\'); if (-not $result) { exit 1 }"
if !ERRORLEVEL! neq 0 exit /b 1

REM Verify WSL distribution exists and start it
wsl.exe -d openclaw -e true >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo.
    echo  [ERROR] WSL distribution 'openclaw' not found.
    echo  Please run Start.ps1 to reinstall.
    echo.
    pause
    exit /b 1
)

echo.
echo  OpenClaw Gateway
echo  ================
echo.

REM Stop any existing gateway first
echo  Stopping any existing gateway...
wsl.exe -d openclaw -- bash -lc "openclaw gateway stop 2>/dev/null; systemctl --user stop openclaw-gateway.service 2>/dev/null; pkill -f 'openclaw.*gateway' 2>/dev/null; sleep 1; echo done"

REM Get the token from OpenClaw config using jq
for /f "tokens=*" %%t in ('wsl.exe -d openclaw -- bash -lc "jq -r '.gateway.auth.token // empty' ~/.openclaw/openclaw.json 2>/dev/null"') do set GATEWAY_TOKEN=%%t

if "!GATEWAY_TOKEN!"=="" (
    set GATEWAY_TOKEN=openclaw-local-token
)

REM Get current AI model profile
for /f "tokens=*" %%m in ('wsl.exe -d openclaw -- bash -lc "jq -r '.agents.defaults.model.primary // empty' ~/.openclaw/openclaw.json 2>/dev/null"') do set AI_MODEL=%%m

if "!AI_MODEL!"=="" (
    set AI_MODEL=Not configured
)

REM Open browser with correct token
start "" "http://127.0.0.1:18789/?token=!GATEWAY_TOKEN!"

echo.
echo   Gateway Info
echo   ------------
echo   Dashboard: http://127.0.0.1:18789/?token=!GATEWAY_TOKEN!
echo   Token:     !GATEWAY_TOKEN!
echo   AI Model:  !AI_MODEL!
echo.
echo   Gateway is starting in a separate window.
echo   Close that window or press Ctrl+C there to stop.
echo.

REM Launch gateway in a new terminal window (non-blocking)
REM Check if Windows Terminal is available
where wt.exe >nul 2>&1
if !ERRORLEVEL! equ 0 (
    start "" wt.exe wsl.exe -d openclaw -- bash -lc "openclaw gateway --bind lan --port 18789 --verbose"
) else (
    start "OpenClaw Gateway" wsl.exe -d openclaw -- bash -lc "openclaw gateway --bind lan --port 18789 --verbose"
)

exit /b 0
