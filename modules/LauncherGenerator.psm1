#Requires -Version 5.1
<#
.SYNOPSIS
    Launch Script Generator for OpenClaw WSL Automation
.DESCRIPTION
    Creates Windows launch scripts for starting OpenClaw
#>

#region Launch Script Generation

function Get-LaunchCommand {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OpenClawPath,
        
        [Parameter()]
        [string]$MainScript = "openclaw.py",
        
        [Parameter()]
        [string]$VenvPath,
        
        [Parameter()]
        [switch]$UseVenv,
        
        [Parameter()]
        [ValidateSet("npm", "git", "local")]
        [string]$InstallMethod = "npm"
    )
    
    # For npm installation, run openclaw gateway to start the service
    # --allow-unconfigured lets OpenClaw handle first-run onboarding automatically
    # Token is passed via $gatewayToken variable defined in generated launcher script
    if ($InstallMethod -eq "npm") {
        return 'openclaw gateway --allow-unconfigured --token=$gatewayToken'
    }
    
    # Build the bash command for git/local installation
    $bashCmd = "cd '$OpenClawPath'"
    
    if ($UseVenv -and $VenvPath) {
        $bashCmd += " && source '$VenvPath/bin/activate'"
    }
    
    if ($MainScript.StartsWith("-m ")) {
        $bashCmd += " && python3 $MainScript"
    } else {
        $bashCmd += " && python3 '$MainScript'"
    }
    
    return $bashCmd
}

function New-LaunchScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$OpenClawPath,
        
        [Parameter()]
        [string]$MainScript = "openclaw.py",
        
        [Parameter()]
        [string]$VenvPath,
        
        [Parameter()]
        [switch]$UseVenv,
        
        [Parameter()]
        [ValidateSet("npm", "git", "local")]
        [string]$InstallMethod = "npm",
        
        [Parameter()]
        [string]$RepoRoot
    )
    
    Write-Host "  Creating launch script: $OutputPath" -ForegroundColor Cyan
    
    $launchCmd = Get-LaunchCommand `
        -OpenClawPath $OpenClawPath `
        -MainScript $MainScript `
        -VenvPath $VenvPath `
        -UseVenv:$UseVenv `
        -InstallMethod $InstallMethod
    
    $pathInfo = if ($InstallMethod -eq "npm") { "Installed via npm" } else { "Path: $OpenClawPath" }
    
    # Determine settings path - use RepoRoot if provided, otherwise derive from OutputPath
    $settingsRepoRoot = if ($RepoRoot) { 
        $RepoRoot 
    } else { 
        # OutputPath is typically .local/scripts/launch-openclaw.ps1
        # Go up 2 levels to get repo root
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $OutputPath))
    }
    
    $scriptContent = @"

#Requires -Version 5.1
<#
.SYNOPSIS
    Launch OpenClaw in WSL
.DESCRIPTION
    Auto-generated launcher for OpenClaw
    Distribution: $DistroName
    $pathInfo
    Supports same-window (logs visible) and new-window (non-blocking) modes
#>

`$ErrorActionPreference = 'Stop'
`$DistroName = "$DistroName"
`$GatewayPort = 18789

# Read launch mode: defaults first, user settings override
`$LaunchMode = "sameWindow"
`$RepoRoot = Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)
`$settingsFile = Join-Path `$RepoRoot ".local\settings.json"
`$defaultsFile = Join-Path `$RepoRoot "config\defaults.json"
if (Test-Path `$defaultsFile) {
    try {
        `$defaults = Get-Content `$defaultsFile -Raw | ConvertFrom-Json
        if (`$defaults.launcher.launchMode) { `$LaunchMode = `$defaults.launcher.launchMode }
    } catch {}
}
if (Test-Path `$settingsFile) {
    try {
        `$settings = Get-Content `$settingsFile -Raw | ConvertFrom-Json
        if (`$settings.launcher.launchMode) { `$LaunchMode = `$settings.launcher.launchMode }
    } catch {}
}

Write-Host ""
Write-Host " OpenClaw Gateway" -ForegroundColor Cyan
Write-Host " ================" -ForegroundColor Cyan
Write-Host ""

# Ensure WSL is running
`$null = & wsl.exe -d `$DistroName -e true 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Host " [ERROR] WSL distribution '`$DistroName' not found." -ForegroundColor Red
    Write-Host " Please run Start.ps1 to reinstall." -ForegroundColor Red
    Read-Host " Press Enter to exit"
    exit 1
}

# Stop any existing gateway first
Write-Host " Stopping any existing gateway..." -ForegroundColor DarkGray
`$null = & wsl.exe -d `$DistroName -- bash -lc "openclaw gateway stop 2>/dev/null; systemctl --user stop openclaw-gateway.service 2>/dev/null; pkill -f 'openclaw.*gateway' 2>/dev/null; sleep 1"

# Get token from OpenClaw config using jq
`$GatewayToken = & wsl.exe -d `$DistroName -- bash -lc "jq -r '.gateway.auth.token // empty' ~/.openclaw/openclaw.json 2>/dev/null"
`$GatewayToken = if (`$GatewayToken) { `$GatewayToken.Trim() } else { "" }
if ([string]::IsNullOrWhiteSpace(`$GatewayToken)) {
    `$GatewayToken = "openclaw-local-token"
}
`$DashboardUrl = "http://127.0.0.1:`$GatewayPort/?token=`$GatewayToken"

# Get current AI profile
`$CurrentModel = & wsl.exe -d `$DistroName -- bash -lc "jq -r '.agents.defaults.model.primary // empty' ~/.openclaw/openclaw.json 2>/dev/null"
`$CurrentModel = if (`$CurrentModel) { `$CurrentModel.Trim() } else { "Not configured" }

# Open browser
Start-Process `$DashboardUrl

Write-Host ""
Write-Host "  +-- Gateway Info ------------------" -ForegroundColor Cyan
Write-Host "  |" -ForegroundColor Cyan
Write-Host "  |  Dashboard: " -ForegroundColor Cyan -NoNewline
Write-Host "`$DashboardUrl" -ForegroundColor White
Write-Host "  |  Token:     " -ForegroundColor Cyan -NoNewline
Write-Host "`$GatewayToken" -ForegroundColor Yellow
Write-Host "  |  AI Model:  " -ForegroundColor Cyan -NoNewline
Write-Host "`$CurrentModel" -ForegroundColor Green
Write-Host "  |  Mode:      " -ForegroundColor Cyan -NoNewline
Write-Host `$(if (`$LaunchMode -eq "sameWindow") { "Same window (logs visible)" } else { "New window" }) -ForegroundColor White
Write-Host "  |" -ForegroundColor Cyan
Write-Host "  +-----------------------------------" -ForegroundColor Cyan
Write-Host ""

# Build the gateway command
`$gatewayCmd = "openclaw gateway --bind lan --port `$GatewayPort --verbose"

if (`$LaunchMode -eq "sameWindow") {
    # Same window: run gateway in current terminal (blocking, all logs visible)
    Write-Host "  Gateway is running below. Press Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host "  `$('-' * 50)" -ForegroundColor DarkGray
    Write-Host ""

    & wsl.exe -d `$DistroName -- bash -lc "`$gatewayCmd"

    Write-Host ""
    Write-Host "  `$('-' * 50)" -ForegroundColor DarkGray
    Write-Host "  Gateway stopped." -ForegroundColor DarkGray
} else {
    # New window: launch in separate terminal (non-blocking)
    Write-Host "  Gateway is starting in a separate window." -ForegroundColor DarkGray
    Write-Host "  Close that window or press Ctrl+C there to stop." -ForegroundColor DarkGray
    Write-Host ""

    `$wtPath = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (`$wtPath) {
        Start-Process wt.exe -ArgumentList "wsl.exe -d `$DistroName -- bash -lc '`$gatewayCmd'"
    } else {
        Start-Process cmd.exe -ArgumentList "/c start `"OpenClaw Gateway`" wsl.exe -d `$DistroName -- bash -lc '`$gatewayCmd'"
    }
}

exit 0
"@

    Set-Content -Path $OutputPath -Value $scriptContent -Encoding UTF8
    
    Write-Host "  [OK] Launch script created" -ForegroundColor Green
    
    return @{
        Path = $OutputPath
        Command = "wsl.exe -d `"$DistroName`" -- bash -lc `"$launchCmd`""
    }
}

function New-BatchLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$PowerShellScriptPath,
        
        [Parameter()]
        [switch]$RunAsAdmin
    )
    
    Write-Host "  Creating batch launcher: $OutputPath" -ForegroundColor Cyan
    
    $adminCode = if ($RunAsAdmin) {
        @"
:: Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
    exit /b
)
"@
    } else {
        ""
    }
    
    $batchContent = @"
@echo off
title OpenClaw Launcher
$adminCode

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PowerShellScriptPath"

exit /b %errorlevel%
"@

    Set-Content -Path $OutputPath -Value $batchContent -Encoding ASCII
    
    Write-Host "  [OK] Batch launcher created" -ForegroundColor Green
    return $OutputPath
}

function New-ShortcutLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$TargetPath,
        
        [Parameter()]
        [string]$Arguments,
        
        [Parameter()]
        [string]$WorkingDirectory,
        
        [Parameter()]
        [string]$IconPath,
        
        [Parameter()]
        [string]$Description = "Launch OpenClaw"
    )
    
    Write-Host "  Creating shortcut: $OutputPath" -ForegroundColor Cyan
    
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($OutputPath)
    
    $shortcut.TargetPath = $TargetPath
    
    if ($Arguments) {
        $shortcut.Arguments = $Arguments
    }
    
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    
    if ($IconPath -and (Test-Path $IconPath)) {
        $shortcut.IconLocation = $IconPath
    }
    
    $shortcut.Description = $Description
    $shortcut.Save()
    
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
    
    Write-Host "  [OK] Shortcut created" -ForegroundColor Green
    return $OutputPath
}

#endregion

#region Helper Scripts

function New-HelperScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptsDirectory,
        
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$OpenClawPath,
        
        [Parameter()]
        [string]$Username,
        
        [Parameter()]
        [ValidateSet("npm", "git", "local")]
        [string]$InstallMethod = "npm"
    )
    
    Write-Host "  Creating helper scripts..." -ForegroundColor Cyan
    
    # Ensure scripts directory exists
    if (-not (Test-Path $ScriptsDirectory)) {
        New-Item -ItemType Directory -Path $ScriptsDirectory -Force | Out-Null
    }
    
    # Create shell access script
    $shellScript = @"
#Requires -Version 5.1
# Open WSL shell in OpenClaw environment

Write-Host "Opening WSL shell..." -ForegroundColor Cyan
Write-Host "Distribution: $DistroName" -ForegroundColor DarkGray
Write-Host ""

wsl.exe -d "$DistroName"
"@
    
    $shellScriptPath = Join-Path $ScriptsDirectory "open-shell.ps1"
    Set-Content -Path $shellScriptPath -Value $shellScript -Encoding UTF8
    
    # Create update script (different for npm vs git)
    if ($InstallMethod -eq "npm") {
        $updateScript = @"
#Requires -Version 5.1
# Update OpenClaw installation (npm)

Write-Host "Updating OpenClaw..." -ForegroundColor Cyan
Write-Host ""

`$cmd = "npm update -g openclaw"
wsl.exe -d "$DistroName" -- bash -lc "`$cmd"

if (`$LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Update complete!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Update failed!" -ForegroundColor Red
}

Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor DarkGray
`$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
"@
    } else {
        $updateScript = @"
#Requires -Version 5.1
# Update OpenClaw installation (git)

Write-Host "Updating OpenClaw..." -ForegroundColor Cyan
Write-Host ""

`$cmd = "cd '$OpenClawPath' && git pull --ff-only && pip3 install --user -r requirements.txt --quiet"
wsl.exe -d "$DistroName" -- bash -c "`$cmd"

if (`$LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Update complete!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Update failed!" -ForegroundColor Red
}

Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor DarkGray
`$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
"@
    }
    
    $updateScriptPath = Join-Path $ScriptsDirectory "update-openclaw.ps1"
    Set-Content -Path $updateScriptPath -Value $updateScript -Encoding UTF8
    
    # Create stop script
    $stopScript = @"
#Requires -Version 5.1
# Stop WSL distribution

Write-Host "Stopping WSL distribution: $DistroName" -ForegroundColor Cyan
wsl.exe --terminate "$DistroName"
Write-Host "Done." -ForegroundColor Green
"@
    
    $stopScriptPath = Join-Path $ScriptsDirectory "stop-wsl.ps1"
    Set-Content -Path $stopScriptPath -Value $stopScript -Encoding UTF8
    
    Write-Host "  [OK] Helper scripts created in: $ScriptsDirectory" -ForegroundColor Green
    
    return @{
        ShellScript = $shellScriptPath
        UpdateScript = $updateScriptPath
        StopScript = $stopScriptPath
    }
}

#endregion

#region Installation Summary

function Show-InstallationSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InstallState
    )
    
    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Green
    Write-Host "       INSTALLATION COMPLETE" -ForegroundColor Green
    Write-Host "  ======================================" -ForegroundColor Green
    Write-Host ""
    
    # Simple single-line format for each item
    Write-Host "  Distribution:    " -ForegroundColor Cyan -NoNewline
    Write-Host $InstallState.DistroName -ForegroundColor White
    
    Write-Host "  Linux User:      " -ForegroundColor Cyan -NoNewline
    Write-Host $InstallState.LinuxUsername -ForegroundColor White
    
    Write-Host "  Filesystem:      " -ForegroundColor Cyan -NoNewline
    Write-Host $InstallState.FilesystemMode -ForegroundColor White
    
    Write-Host "  Network:         " -ForegroundColor Cyan -NoNewline
    Write-Host $InstallState.NetworkMode -ForegroundColor White
    
    Write-Host ""
    Write-Host "  Install Path:    " -ForegroundColor Cyan -NoNewline
    Write-Host $InstallState.WindowsInstallPath -ForegroundColor White
    
    # Show installation method
    $installMethod = if ($InstallState.InstallMethod) { $InstallState.InstallMethod } else { "npm" }
    Write-Host "  Install Method:  " -ForegroundColor Cyan -NoNewline
    Write-Host $installMethod -ForegroundColor White
    
    # Show Linux path only if not npm method
    if ($installMethod -ne "npm" -and $InstallState.LinuxOpenClawPath) {
        Write-Host "  Linux Path:      " -ForegroundColor Cyan -NoNewline
        Write-Host $InstallState.LinuxOpenClawPath -ForegroundColor White
    }
    
    if ($InstallState.DataFolderLinuxPath -and $installMethod -ne "npm") {
        Write-Host "  Data Mount:      " -ForegroundColor Cyan -NoNewline
        Write-Host $InstallState.DataFolderLinuxPath -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Green
    Write-Host ""
    
    # Show appropriate instructions based on how OpenClaw was installed
    if ($InstallState.OpenClawCloned -eq $false) {
        Write-Host "  NOTE: OpenClaw was not installed." -ForegroundColor Yellow
        Write-Host "  WSL environment is ready." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To manually install OpenClaw:" -ForegroundColor DarkGray
        Write-Host "    wsl -d $($InstallState.DistroName) -- NODE_OPTIONS=--openssl-legacy-provider npm install -g openclaw" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host "  To start OpenClaw later:" -ForegroundColor DarkGray
        Write-Host "    .\OpenClaw.bat" -ForegroundColor White
        Write-Host ""
    }
}

function Show-ReinstallOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ExistingState
    )
    
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Yellow
    Write-Host "  EXISTING INSTALLATION DETECTED" -ForegroundColor Yellow
    Write-Host "===================================================================" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "  Distribution: $($ExistingState.DistroName)" -ForegroundColor White
    Write-Host "  Linux User: $($ExistingState.LinuxUsername)" -ForegroundColor White
    Write-Host "  Installed: $($ExistingState.InstallDate)" -ForegroundColor DarkGray
    
    # Show OpenClaw status
    $openClawStatus = if ($ExistingState.OpenClawCloned) { "Installed" } else { "Not installed" }
    Write-Host "  OpenClaw: $openClawStatus" -ForegroundColor $(if ($ExistingState.OpenClawCloned) { "Green" } else { "Yellow" })
    Write-Host ""
    
    # Adjust first option based on whether OpenClaw is cloned
    $firstOption = if ($ExistingState.OpenClawCloned) {
        "Update OpenClaw only (keep configuration)"
    } else {
        "Install/Update OpenClaw (keep configuration)"
    }
    
    $choices = @(
        $firstOption,
        "Reconfigure (change isolation settings)",
        "Full reinstall (remove and start fresh)",
        "Exit without changes"
    )
    
    Write-Host "  What would you like to do?" -ForegroundColor Yellow
    Write-Host ""
    
    for ($i = 0; $i -lt $choices.Count; $i++) {
        Write-Host "    $($i + 1)) $($choices[$i])" -ForegroundColor Gray
    }
    
    while ($true) {
        Write-Host ""
        Write-Host "  Enter choice (1-4): " -NoNewline -ForegroundColor Gray
        $userInput = Read-Host
        
        if ($userInput -match '^[1-4]$') {
            return [int]$userInput
        }
        
        Write-Host "  [ERROR] Please enter a number between 1 and 4." -ForegroundColor Red
    }
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Launch Scripts
    'Get-LaunchCommand',
    'New-LaunchScript',
    'New-BatchLauncher',
    'New-ShortcutLauncher',
    
    # Helper Scripts
    'New-HelperScripts',
    
    # Summary
    'Show-InstallationSummary',
    'Show-ReinstallOptions'
)
