#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Script:Version = "2.0.0"

# Resolve repository root (two levels up from scripts/internal/)
$Script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script:LocalPath = Join-Path $Script:RepoRoot ".local"

# Load required modules
$modulePath = Join-Path $Script:RepoRoot "modules"
$requiredModules = @("Logger.psm1", "WSLManager.psm1")

foreach ($module in $requiredModules) {
    $fullPath = Join-Path $modulePath $module
    if (Test-Path $fullPath) {
        Import-Module $fullPath -Force -DisableNameChecking
    } else {
        Write-Host "[ERROR] Required module not found: $module" -ForegroundColor Red
        exit 1
    }
}

function Show-UninstallBanner {
    Clear-Host
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Red
    Write-Host "                        WARNING" -ForegroundColor Red
    Write-Host "                OPENCLAW UNINSTALLATION" -ForegroundColor Red
    Write-Host "  ================================================================" -ForegroundColor Red
    Write-Host ""
}

function Show-UninstallWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$InstallationInfo
    )
    
    Write-Host "  This will PERMANENTLY DELETE the following components:" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($component in $InstallationInfo.Components) {
        $typeStr = $component.Type
        $nameStr = $component.Name
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  | $typeStr : " -ForegroundColor White -NoNewline
        Write-Host "$nameStr" -ForegroundColor Cyan
        if ($component.Path) {
            $pathStr = $component.Path
            Write-Host "  | Path: $pathStr" -ForegroundColor DarkGray
        }
        if ($component.Description) {
            $descStr = $component.Description
            Write-Host "  | $descStr" -ForegroundColor DarkGray
        }
        Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    Write-Host "  WARNING: THIS ACTION CANNOT BE UNDONE!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  All data inside the WSL distribution will be lost," -ForegroundColor Yellow
    Write-Host "  including any files, configurations, and installed software." -ForegroundColor Yellow
    Write-Host ""
}

function Confirm-Uninstall {
    [CmdletBinding()]
    param()
    
    Write-Host "  To confirm, type 'UNINSTALL' (case-sensitive): " -ForegroundColor White -NoNewline
    $confirmation = Read-Host
    
    return $confirmation -ceq "UNINSTALL"
}

function Start-Uninstallation {
    [CmdletBinding()]
    param()
    
    # Get installation info using shared module function
    $installInfo = Get-ExistingInstallationInfo -LocalPath $Script:LocalPath
    
    if (-not $installInfo.Exists) {
        Write-Host ""
        Write-Host "  No OpenClaw installation found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Nothing to uninstall." -ForegroundColor DarkGray
        Write-Host ""
        return @{
            Success = $true
            Message = "Nothing to uninstall"
        }
    }
    
    # Show warning with components
    Show-UninstallWarning -InstallationInfo $installInfo
    
    # Confirm unless -Force
    if (-not $Force) {
        if (-not (Confirm-Uninstall)) {
            Write-Host ""
            Write-Host "  Uninstallation cancelled." -ForegroundColor Yellow
            Write-Host ""
            return @{
                Success = $false
                Message = "Cancelled by user"
            }
        }
    }
    
    Write-Host ""
    Write-Host "  Starting uninstallation..." -ForegroundColor Cyan
    Write-Host ""
    
    # Use shared module function for actual uninstallation
    $result = Uninstall-OpenClawInstallation -LocalPath $Script:LocalPath -Force
    
    Write-Host ""
    
    if ($result.Success -and $result.Errors.Count -eq 0) {
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host "         UNINSTALLATION COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Removed components:" -ForegroundColor DarkGray
        foreach ($comp in $result.RemovedComponents) {
            Write-Host "    [OK] $comp" -ForegroundColor Green
        }
        Write-Host ""
        $repoStr = $Script:RepoRoot
        Write-Host "  The script files remain in: $repoStr" -ForegroundColor DarkGray
        Write-Host "  You can delete this folder manually if no longer needed." -ForegroundColor DarkGray
        Write-Host ""
        
        return @{
            Success = $true
            Message = "Uninstallation completed"
        }
    } else {
        Write-Host "  ================================================================" -ForegroundColor Yellow
        Write-Host "         UNINSTALLATION COMPLETED WITH ERRORS" -ForegroundColor Yellow
        Write-Host "  ================================================================" -ForegroundColor Yellow
        Write-Host ""
        
        if ($result.RemovedComponents.Count -gt 0) {
            Write-Host "  Removed components:" -ForegroundColor DarkGray
            foreach ($comp in $result.RemovedComponents) {
                Write-Host "    [OK] $comp" -ForegroundColor Green
            }
            Write-Host ""
        }
        
        if ($result.Errors.Count -gt 0) {
            Write-Host "  Some components could not be removed:" -ForegroundColor Yellow
            foreach ($err in $result.Errors) {
                Write-Host "    [FAIL] $err" -ForegroundColor Red
            }
            Write-Host ""
        }
        
        return @{
            Success = $false
            Message = "Completed with errors"
            Errors = $result.Errors
        }
    }
}

# Main Entry Point
Show-UninstallBanner
$result = Start-Uninstallation

Write-Host "Press any key to exit..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

if (-not $result.Success -and $result.Message -ne "Cancelled by user") {
    exit 1
}
