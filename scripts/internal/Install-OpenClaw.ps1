#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OpenClaw WSL Automation Installer
.DESCRIPTION
    Interactive PowerShell script that installs and configures WSL 
    and prepares a secure, isolated Linux environment for OpenClaw.
    
    The script uses the repository root as the installation root.
    Clone this repository and run the installer - the repo folder
    becomes your OpenClaw installation. Git-tracked files remain
    updatable via git pull, while local data is gitignored.
.NOTES
    Author: OpenClaw Team
    Version: 2.0.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Force,
    
    [Parameter()]
    [switch]$SkipConfirmation
)

$ErrorActionPreference = 'Stop'
$Script:Version = "2.0.0"

#region Path Resolution

# Resolve repository root (two levels up from scripts/internal/)
$Script:InstallRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script:LocalPath = Join-Path $Script:InstallRoot ".local"
$Script:WSLPath = Join-Path $Script:LocalPath "wsl"
$Script:OpenClawPath = Join-Path $Script:InstallRoot "openclaw"
$ModulesPath = Join-Path $Script:InstallRoot "modules"

#endregion

#region Module Loading

# Import all modules (Logger must be loaded first, then Core)
$modules = @(
    "Logger",
    "Core",
    "PathUtils",
    "WSLManager",
    "LinuxConfig",
    "IsolationConfig",
    "SoftwareInstall",
    "LauncherGenerator",
    "SettingsManager"
)

foreach ($moduleName in $modules) {
    $modulePath = Join-Path $ModulesPath "$moduleName.psm1"
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force -DisableNameChecking
    } else {
        Write-Host "[ERROR] Module not found: $modulePath" -ForegroundColor Red
        exit 1
    }
}

# Load defaults
$defaultsPath = Join-Path $Script:InstallRoot "config\defaults.json"
$Script:Defaults = if (Test-Path $defaultsPath) {
    Get-Content $defaultsPath -Raw | ConvertFrom-Json
} else {
    Write-Host "[WARNING] Defaults file not found, using built-in defaults" -ForegroundColor Yellow
    $null
}

# Initialize Settings Manager
Initialize-SettingsManager -RepoRoot $Script:InstallRoot

#endregion

#region Logging Initialization

# Initialize file-based logging
$logSubdir = if ($Script:Defaults.logging.subdirectory) { $Script:Defaults.logging.subdirectory } else { "logs" }
$Script:LogPath = Join-Path $Script:LocalPath $logSubdir

# Create .local directory if needed (for logging before full setup)
if (-not (Test-Path $Script:LocalPath)) {
    New-Item -Path $Script:LocalPath -ItemType Directory -Force | Out-Null
}

# Initialize the Logger module
$logConfig = @{
    LogDirectory  = $Script:LogPath
    LogLevel      = if ($Script:Defaults.logging.level) { $Script:Defaults.logging.level } else { "Info" }
    MaxLogSizeMB  = if ($Script:Defaults.logging.maxLogSizeMB) { $Script:Defaults.logging.maxLogSizeMB } else { 10 }
    MaxLogFiles   = if ($Script:Defaults.logging.maxLogFiles) { $Script:Defaults.logging.maxLogFiles } else { 5 }
}

$loggingInitialized = Initialize-Logging @logConfig

if ($loggingInitialized) {
    Enable-FileLogging
    Write-LogMessage "OpenClaw Installer v$Script:Version starting" -Level Info
    Write-LogMessage "Install root: $Script:InstallRoot" -Level Debug
} else {
    Write-Host "[WARNING] File logging could not be initialized" -ForegroundColor Yellow
}

# Clean up old logs periodically
if ($loggingInitialized) {
    $daysToKeep = if ($Script:Defaults.logging.daysToKeep) { $Script:Defaults.logging.daysToKeep } else { 30 }
    Clear-OldLogs -DaysToKeep $daysToKeep
}

#endregion

#region Banner

function Show-InstallerBanner {
    Clear-Host
    Write-Host ""
    Write-Host "  +=========================================================+" -ForegroundColor Cyan
    Write-Host "  |                                                         |" -ForegroundColor Cyan
    Write-Host "  |     ___   ____       _    _ ____  _                     |" -ForegroundColor Cyan
    Write-Host "  |    / _ \ / ___|     | |  | / ___|| |                    |" -ForegroundColor Cyan
    Write-Host "  |   | | | | |   _____ | |  | \___ \| |                    |" -ForegroundColor Cyan
    Write-Host "  |   | |_| | |__|_____|| |/\| |___) | |___                 |" -ForegroundColor Cyan
    Write-Host "  |    \___/ \____|      \_/\_/|____/|_____|                |" -ForegroundColor Cyan
    Write-Host "  |                                                         |" -ForegroundColor Cyan
    Write-Host "  |              WSL Automation Installer                   |" -ForegroundColor Cyan
    Write-Host "  |                                                         |" -ForegroundColor Cyan
    Write-Host "  +=========================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Install Location: $Script:InstallRoot" -ForegroundColor DarkGray
    Write-Host ""
}

#endregion

#region Main Installation Flow

function Start-Installation {
    [CmdletBinding()]
    param()
    
    # Installation state tracking
    $state = @{
        WindowsInstallPath = $Script:InstallRoot
        LocalPath = $Script:LocalPath
        OpenClawWindowsPath = $Script:OpenClawPath
        DistroName = $null
        LinuxUsername = $null
        LinuxOpenClawPath = $null
        FilesystemMode = $null
        NetworkMode = $null
        DataFolderPath = $null
        DataFolderLinuxPath = $null
        LaunchScriptPath = $null
        LaunchCommand = $null
        InstallDate = (Get-Date).ToString("o")
    }
    
    $totalSteps = 9
    $currentStep = 0
    
    try {
        #========================================
        # STEP 1: Prerequisites Check
        #========================================
        $currentStep++
        Write-Step "Prerequisites Check" -Step $currentStep -TotalSteps $totalSteps
        
        Write-SubStep "Checking administrator privileges..."
        Assert-AdminPrivileges
        Write-Success "Running with administrator privileges"
        
        Write-SubStep "Checking WSL availability..."
        Assert-WSLAvailable
        Write-Success "WSL is available"
        
        Write-SubStep "Install location: $Script:InstallRoot"
        Write-Success "Using script location as install root"
        
        # Check for existing installation (WSL distro OR local data)
        Write-SubStep "Checking for existing installation..."
        $existingInstall = Get-ExistingInstallationInfo -LocalPath $Script:LocalPath
        
        if ($existingInstall.Exists -and -not $Force) {
            # Existing installation found - prompt user
            $userChoice = Show-ExistingInstallationPrompt -InstallationInfo $existingInstall
            
            switch ($userChoice) {
                "uninstall" {
                    Write-Host ""
                    Write-Host "  Removing existing installation..." -ForegroundColor Cyan
                    Write-Log -Message "User chose to uninstall existing installation" -Level "Info"
                    
                    $uninstallResult = Uninstall-OpenClawInstallation -LocalPath $Script:LocalPath -Force
                    
                    if (-not $uninstallResult.Success -and $uninstallResult.Errors.Count -gt 0) {
                        Write-Host ""
                        Write-Host "  ⚠  Some components could not be removed:" -ForegroundColor Yellow
                        foreach ($err in $uninstallResult.Errors) {
                            Write-Host "    • $err" -ForegroundColor Red
                        }
                        Write-Host ""
                        Write-Host "  Installation cannot continue with existing components." -ForegroundColor Red
                        Write-Host "  Please manually remove the components and try again." -ForegroundColor DarkGray
                        return @{ Success = $false; Error = "Failed to remove existing installation" }
                    }
                    
                    Write-Host ""
                    Write-Success "Existing installation removed"
                    Write-Host ""
                    # Continue with fresh install
                }
                "abort" {
                    Write-Host ""
                    Write-Host "  Installation aborted by user." -ForegroundColor Yellow
                    Write-Log -Message "Installation aborted by user due to existing installation" -Level "Info"
                    return @{ Success = $false; Aborted = $true }
                }
            }
        } elseif (-not $existingInstall.Exists) {
            Write-Success "No existing installation found"
        }
        
        #========================================
        # STEP 2: Local Directory Setup
        #========================================
        $currentStep++
        Write-Step "Local Directory Setup" -Step $currentStep -TotalSteps $totalSteps
        
        # Create local subdirectories (these are gitignored)
        Write-SubStep "Creating local directory structure..."
        $localSubdirs = if ($Script:Defaults.paths.localSubdirectories) { $Script:Defaults.paths.localSubdirectories } else { @("data", "scripts", "wsl", "logs") }
        New-DirectoryStructure -BasePath $Script:LocalPath -Subdirectories $localSubdirs | Out-Null
        
        $state.DataFolderPath = Join-Path $Script:LocalPath "data"
        $state.WSLPath = $Script:WSLPath
        
        # Copy tool scripts to data folder (for WSL access)
        $assetsScriptsPath = Join-Path $PSScriptRoot "..\..\assets\scripts"
        if (Test-Path $assetsScriptsPath) {
            Write-SubStep "Copying tool scripts to data folder..."
            Get-ChildItem -Path $assetsScriptsPath -Filter "*.sh" | ForEach-Object {
                $destPath = Join-Path $state.DataFolderPath $_.Name
                # Convert to Unix line endings
                $content = Get-Content $_.FullName -Raw
                $content = $content -replace "`r`n", "`n"
                [System.IO.File]::WriteAllText($destPath, $content, [System.Text.UTF8Encoding]::new($false))
            }
        }
        
        Write-Success "Local directories created in .local/"
        
        #========================================
        # STEP 3: WSL Distribution
        #========================================
        $currentStep++
        Write-Step "WSL Distribution Setup" -Step $currentStep -TotalSteps $totalSteps
        
        # Get or create the OpenClaw distribution (stored locally for portability)
        $state.DistroName = Get-OrCreateOpenClawDistribution -LocalWSLPath $Script:WSLPath
        Write-Success "Using distribution: $($state.DistroName)"
        
        #========================================
        # STEP 4: Linux User Setup
        #========================================
        $currentStep++
        Write-Step "Linux User Configuration" -Step $currentStep -TotalSteps $totalSteps
        
        $defaultUsername = if ($Script:Defaults.linux.defaultUsername) { $Script:Defaults.linux.defaultUsername } else { "openclaw" }
        
        $state.LinuxUsername = Read-ValidatedInput `
            -Prompt "Enter Linux username" `
            -Default $defaultUsername `
            -Validator { param($u) Test-ValidLinuxUsername $u }
        
        # Log user choice
        Write-Log -Message "User selected Linux username: $($state.LinuxUsername)" -Level "Info"
        
        # Check if user exists
        if (-not (Test-LinuxUserExists -DistroName $state.DistroName -Username $state.LinuxUsername)) {
            Write-SubStep "Creating user: $($state.LinuxUsername)"
            $null = New-LinuxUser -DistroName $state.DistroName -Username $state.LinuxUsername
            
            Write-Host ""
            Write-Host "  Please set a password for user '$($state.LinuxUsername)'" -ForegroundColor Yellow
            $null = Set-LinuxUserPassword -DistroName $state.DistroName -Username $state.LinuxUsername
        } else {
            Write-Success "User '$($state.LinuxUsername)' already exists"
        }
        
        # Configure passwordless sudo
        Write-SubStep "Configuring passwordless sudo..."
        $null = Set-PasswordlessSudo -DistroName $state.DistroName -Username $state.LinuxUsername
        
        # Set default user
        Write-SubStep "Setting default WSL user..."
        $null = Set-DefaultWSLUser -DistroName $state.DistroName -Username $state.LinuxUsername
        
        Write-Success "Linux user configured"
        
        #========================================
        # STEP 5: Filesystem Access Mode
        #========================================
        $currentStep++
        Write-Step "Filesystem Access Configuration" -Step $currentStep -TotalSteps $totalSteps
        
        $state.FilesystemMode = Select-FilesystemMode -Default 2
        
        # Log user choice
        Write-Log -Message "User selected filesystem mode: $($state.FilesystemMode)" -Level "Info"
        
        Write-Success "Filesystem mode selected: $($state.FilesystemMode)"
        
        #========================================
        # STEP 6: Network Isolation
        #========================================
        $currentStep++
        Write-Step "Network Configuration" -Step $currentStep -TotalSteps $totalSteps
        
        $state.NetworkMode = Select-NetworkMode -Default 1
        
        # Log user choice
        Write-Log -Message "User selected network mode: $($state.NetworkMode)" -Level "Info"
        
        Write-Success "Network mode selected: $($state.NetworkMode)"
        
        #========================================
        # STEP 7: Apply Configuration
        #========================================
        $currentStep++
        Write-Step "Applying Configuration" -Step $currentStep -TotalSteps $totalSteps
        
        # Filesystem configuration
        Write-SubStep "Configuring filesystem access..."
        $state.DataFolderLinuxPath = "/mnt/openclaw-data"
        
        $null = Set-FilesystemAccessMode `
            -DistroName $state.DistroName `
            -Mode $state.FilesystemMode `
            -DataFolderWindowsPath $state.DataFolderPath `
            -LinuxMountPoint $state.DataFolderLinuxPath `
            -Username $state.LinuxUsername
        
        # Network configuration
        Write-SubStep "Configuring network access..."
        $null = Set-NetworkIsolation `
            -DistroName $state.DistroName `
            -Mode $state.NetworkMode `
            -Username $state.LinuxUsername
        
        # Restart WSL to apply changes
        Write-SubStep "Restarting WSL to apply configuration..."
        Restart-Distribution -DistroName $state.DistroName
        
        # Mount filesystems
        if ($state.FilesystemMode -eq "limited") {
            Write-SubStep "Mounting shared folders..."
            $null = Mount-FstabEntries -DistroName $state.DistroName
        }
        
        # Enable systemd user lingering (required for systemd user services)
        Write-SubStep "Configuring systemd user services..."
        $null = Enable-SystemdLingering -DistroName $state.DistroName -Username $state.LinuxUsername
        
        # Configure stable DNS (after restart so wsl.conf [network] generateResolvConf=false is active)
        Write-SubStep "Configuring stable DNS..."
        $null = Set-StableDNS -DistroName $state.DistroName
        
        Write-Success "Configuration applied"
        
        #========================================
        # STEP 8: Install Software & OpenClaw
        #========================================
        $currentStep++
        Write-Step "Software Installation" -Step $currentStep -TotalSteps $totalSteps
        
        # Install required packages
        Write-SubStep "Installing required Linux packages..."
        $null = Install-RequiredPackages -DistroName $state.DistroName -Username $state.LinuxUsername
        
        # Install OpenClaw via npm (default method)
        Write-SubStep "Installing OpenClaw..."
        $openClawResult = Install-OpenClaw `
            -DistroName $state.DistroName `
            -Username $state.LinuxUsername `
            -InstallMethod "npm" `
            -Force:$Force
        
        $state.LinuxOpenClawPath = $openClawResult.Path
        $state.OpenClawCloned = $openClawResult.CloneSucceeded
        $state.InstallMethod = if ($openClawResult.Method) { $openClawResult.Method } else { "npm" }
        
        # Configure data directory if limited mode and using git/local method
        if ($state.FilesystemMode -eq "limited" -and $state.DataFolderLinuxPath -and $state.InstallMethod -ne "npm") {
            Write-SubStep "Configuring OpenClaw data directory..."
            $null = Set-OpenClawDataDirectory `
                -DistroName $state.DistroName `
                -Username $state.LinuxUsername `
                -OpenClawPath $state.LinuxOpenClawPath `
                -DataPath $state.DataFolderLinuxPath
        }
        
        if ($openClawResult.CloneSucceeded) {
            Write-Success "OpenClaw installed"
        } else {
            Write-WarningMessage "OpenClaw code not yet available - WSL environment is ready"
        }
        
        #========================================
        # STEP 9: Create Launch Scripts
        #========================================
        $currentStep++
        Write-Step "Creating Launch Scripts" -Step $currentStep -TotalSteps $totalSteps
        
        # Create launch scripts if OpenClaw was installed (npm or git)
        if ($openClawResult.CloneSucceeded -or $openClawResult.AlreadyInstalled) {
            # Create launch script in .local/scripts (gitignored)
            $scriptsDir = Join-Path $Script:LocalPath "scripts"
            
            $launchScriptPath = Join-Path $scriptsDir "launch-openclaw.ps1"
            
            # Use npm method if installed via npm
            $installMethod = if ($openClawResult.Method -eq "npm") { "npm" } else { "git" }
            
            if ($installMethod -eq "npm") {
                $launchResult = New-LaunchScript `
                    -OutputPath $launchScriptPath `
                    -DistroName $state.DistroName `
                    -InstallMethod "npm" `
                    -RepoRoot $Script:InstallRoot
            } else {
                # Detect main script for git/local installation
                $mainScript = Get-OpenClawMainScript `
                    -DistroName $state.DistroName `
                    -InstallPath $state.LinuxOpenClawPath `
                    -User $state.LinuxUsername
                
                $launchResult = New-LaunchScript `
                    -OutputPath $launchScriptPath `
                    -DistroName $state.DistroName `
                    -OpenClawPath $state.LinuxOpenClawPath `
                    -MainScript $mainScript `
                    -InstallMethod "git" `
                    -RepoRoot $Script:InstallRoot
            }
            
            $state.LaunchScriptPath = $launchResult.Path
            $state.LaunchCommand = $launchResult.Command
            
            # Create batch launcher for convenience
            $batchPath = Join-Path $scriptsDir "launch-openclaw.bat"
            $null = New-BatchLauncher -OutputPath $batchPath -PowerShellScriptPath $launchScriptPath
            
            
            Write-Success "Launch scripts created in .local/scripts/"
        } else {
            Write-WarningMessage "Launch scripts not created - OpenClaw not available"
            Write-Host "  You can manually install OpenClaw later with:" -ForegroundColor DarkGray
            Write-Host "    wsl -d $($state.DistroName) -- NODE_OPTIONS=--openssl-legacy-provider npm i -g openclaw" -ForegroundColor DarkGray
        }
        
        # Always create helper scripts (they're useful for shell access, etc.)
        $scriptsDir = Join-Path $Script:LocalPath "scripts"
        $helperInstallMethod = if ($state.InstallMethod) { $state.InstallMethod } else { "npm" }
        $null = New-HelperScripts `
            -ScriptsDirectory $scriptsDir `
            -DistroName $state.DistroName `
            -OpenClawPath $state.LinuxOpenClawPath `
            -Username $state.LinuxUsername `
            -InstallMethod $helperInstallMethod
        
        #========================================
        # Save Installation State
        #========================================
        # Save state to .local/ (gitignored)
        $stateFile = Join-Path $Script:LocalPath "state.json"
        $state.LastModified = (Get-Date).ToString("o")
        $state.Version = "2.0"
        $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
        Write-LogMessage "Installation state saved to .local/state.json" -Level Debug
        
        #========================================
        # Show Summary
        #========================================
        Show-InstallationSummary -InstallState $state
        
        #========================================
        # Launch OpenClaw Onboarding
        #========================================
        if ($openClawResult.CloneSucceeded -or $openClawResult.AlreadyInstalled) {
            Start-OpenClawSetup -DistroName $state.DistroName -Username $state.LinuxUsername
        }
        
    }
    catch {
        Write-Host ""
        Write-ErrorMessage "Installation failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "  Error details:" -ForegroundColor Red
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
        Write-Host ""
        
        # Log detailed error to file
        if (Test-FileLoggingEnabled) {
            Write-ErrorLog -Message "Installation failed" -Exception $_.Exception -ErrorRecord $_
            Write-Host "  Error details logged to: $(Get-ErrorLogFilePath)" -ForegroundColor DarkGray
            Write-Host ""
        }
        
        throw
    }
}

#endregion

#region Main Entry Point

# Show banner
Show-InstallerBanner

# Start installation
try {
    Write-LogMessage "Starting installation process" -Level Info
    Start-Installation
    Write-LogMessage "Installation completed successfully" -Level Success
}
catch {
    Write-LogMessage "Installation aborted: $($_.Exception.Message)" -Level Error
    
    # Log full error details
    if (Test-FileLoggingEnabled) {
        Write-ErrorLog -Message "Installation aborted" -Exception $_.Exception -ErrorRecord $_
    }
    
    Write-Host ""
    Write-Host "Installation aborted." -ForegroundColor Red
    
    # Show log location for troubleshooting
    if (Test-FileLoggingEnabled) {
        Write-Host ""
        Write-Host "  For troubleshooting, check the log files:" -ForegroundColor Yellow
        Write-Host "    Log file: $(Get-LogFilePath)" -ForegroundColor DarkGray
        Write-Host "    Error log: $(Get-ErrorLogFilePath)" -ForegroundColor DarkGray
    }
    
    # Set LASTEXITCODE to indicate failure but don't exit - let the script continue to cleanup
    $global:LASTEXITCODE = 1
}
finally {
    # Log summary at end
    if (Test-FileLoggingEnabled) {
        $summary = Get-LogSummary
        if ($summary) {
            Write-LogMessage "Session summary - Entries: $($summary.TotalEntries), Errors: $($summary.Errors), Warnings: $($summary.Warnings)" -Level Info -NoConsole
        }
    }
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

#endregion
