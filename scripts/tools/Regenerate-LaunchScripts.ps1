#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates OpenClaw launch scripts from current templates
.DESCRIPTION
    This script regenerates the launch scripts in .local/scripts/ using the latest
    templates from LauncherGenerator.psm1. Use this after updating OpenClaw-WSL
    to ensure you have the latest launcher features.
.EXAMPLE
    .\scripts\tools\Regenerate-LaunchScripts.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Determine repository root
$Script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

Write-Host ""
Write-Host "  Regenerating OpenClaw Launch Scripts" -ForegroundColor Cyan
Write-Host "  =====================================" -ForegroundColor Cyan
Write-Host ""

# Check state file exists
$stateFile = Join-Path $Script:RepoRoot ".local\state.json"
if (-not (Test-Path $stateFile)) {
    Write-Host "  [ERROR] No installation found. Run Install-OpenClaw.ps1 first." -ForegroundColor Red
    exit 1
}

# Load state
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
Write-Host "  Distribution: $($state.DistroName)" -ForegroundColor DarkGray
Write-Host "  Install Method: $($state.InstallMethod)" -ForegroundColor DarkGray
Write-Host ""

# Import the LauncherGenerator module
$modulePath = Join-Path $Script:RepoRoot "modules\LauncherGenerator.psm1"
Import-Module $modulePath -Force

# Regenerate launch script
$scriptsDir = Join-Path $Script:RepoRoot ".local\scripts"
$launchScriptPath = Join-Path $scriptsDir "launch-openclaw.ps1"

if ($state.InstallMethod -eq "npm") {
    $launchResult = New-LaunchScript `
        -OutputPath $launchScriptPath `
        -DistroName $state.DistroName `
        -InstallMethod "npm" `
        -RepoRoot $Script:RepoRoot
} else {
    $launchResult = New-LaunchScript `
        -OutputPath $launchScriptPath `
        -DistroName $state.DistroName `
        -OpenClawPath $state.LinuxOpenClawPath `
        -MainScript "openclaw.py" `
        -InstallMethod "git" `
        -RepoRoot $Script:RepoRoot
}

# Regenerate batch launcher
$batchPath = Join-Path $scriptsDir "launch-openclaw.bat"
$null = New-BatchLauncher -OutputPath $batchPath -PowerShellScriptPath $launchScriptPath

# Regenerate helper scripts
$null = New-HelperScripts `
    -ScriptsDirectory $scriptsDir `
    -DistroName $state.DistroName `
    -Username $state.LinuxUsername `
    -InstallMethod $state.InstallMethod

Write-Host ""
Write-Host "  [OK] Launch scripts regenerated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Updated files:" -ForegroundColor Cyan
Write-Host "    - .local\scripts\launch-openclaw.ps1" -ForegroundColor White
Write-Host "    - .local\scripts\launch-openclaw.bat" -ForegroundColor White
Write-Host "    - .local\scripts\open-shell.ps1" -ForegroundColor White
Write-Host "    - .local\scripts\update-openclaw.ps1" -ForegroundColor White
Write-Host "    - .local\scripts\stop-wsl.ps1" -ForegroundColor White
Write-Host ""
