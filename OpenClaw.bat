@echo off
title OpenClaw
setlocal EnableDelayedExpansion

REM ============================================================================
REM OpenClaw Launcher
REM Stops any existing gateway, opens browser, runs gateway
REM Supports sameWindow (default) and newWindow launch modes
REM ============================================================================

cd /d "%~dp0"

REM Path relocation check
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '%~dp0modules\PathRelocation.psm1' -Force; $result = Invoke-PathRelocationCheck -CurrentPath '%~dp0'.TrimEnd('\'); if (-not $result) { exit 1 }"
if !ERRORLEVEL! neq 0 exit /b 1

REM Read launch mode from settings (user override) or defaults
set LAUNCH_MODE=sameWindow
for /f "tokens=*" %%v in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$m = $null; $sf = '%~dp0.local\settings.json'; $df = '%~dp0config\defaults.json'; if (Test-Path $sf) { try { $s = Get-Content $sf -Raw | ConvertFrom-Json; if ($s.launcher.launchMode) { $m = $s.launcher.launchMode } } catch {} }; if (-not $m -and (Test-Path $df)) { try { $d = Get-Content $df -Raw | ConvertFrom-Json; if ($d.launcher.launchMode) { $m = $d.launcher.launchMode } } catch {} }; if ($m) { $m } else { 'sameWindow' }"') do set LAUNCH_MODE=%%v

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

REM Ensure TLS crash guard exists (for existing installations)
wsl.exe -d openclaw -- bash -c "test -f $HOME/.openclaw/tls-crash-guard.js || { mkdir -p $HOME/.openclaw && echo 'process.on(\"uncaughtException\",(e)=>{if(e instanceof TypeError&&e.message&&e.message.includes(\"setSession\"))return;throw e});' > $HOME/.openclaw/tls-crash-guard.js; }"

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
echo   Mode:      !LAUNCH_MODE!
echo.

REM Gateway command with TLS crash guard and auto-restart
set "GW_CMD=export PATH=\"$HOME/.npm-global/bin:$PATH\" && export NODE_OPTIONS=\"--require $HOME/.openclaw/tls-crash-guard.js\" && while true; do openclaw gateway --bind lan --port 18789 --verbose; EXIT_CODE=$?; if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 130 ]; then break; fi; echo [openclaw] Gateway crashed with exit code $EXIT_CODE, restarting in 3s...; sleep 3; done"

if "!LAUNCH_MODE!"=="sameWindow" (
    echo   Gateway is running below. Press Ctrl+C to stop.
    echo   --------------------------------------------------
    echo.
    wsl.exe -d openclaw -- bash -lc "!GW_CMD!"
    echo.
    echo   --------------------------------------------------
    echo   Gateway stopped.
) else (
    echo   Gateway is starting in a separate window.
    echo   Close that window or press Ctrl+C there to stop.
    echo.
    where wt.exe >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        start "" wt.exe wsl.exe -d openclaw -- bash -lc "!GW_CMD!"
    ) else (
        start "OpenClaw Gateway" wsl.exe -d openclaw -- bash -lc "!GW_CMD!"
    )
)

exit /b 0
