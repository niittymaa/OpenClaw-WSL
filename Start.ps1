#Requires -Version 5.1
<#
.SYNOPSIS
    OpenClaw Main Menu
.DESCRIPTION
    Interactive menu for OpenClaw installation, configuration, and management
.EXAMPLE
    .\Start.ps1
.NOTES
    Author: OpenClaw Team
    Version: 2.0.0
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Script:Version = "2.0.0"
$Script:RepoRoot = $PSScriptRoot

#region Module Loading

$modulePath = Join-Path $Script:RepoRoot "modules"
$toolsPath = Join-Path $Script:RepoRoot "scripts\tools"

$requiredModules = @(
    "Core.psm1",
    "PathRelocation.psm1",
    "MenuSystem.psm1",
    "WSLManager.psm1",
    "LinuxConfig.psm1",
    "SoftwareInstall.psm1",
    "SettingsManager.psm1",
    "CommandPresets.psm1"
)

$toolModules = @(
    "OllamaManager.psm1",
    "AIProviderManager.psm1"
)

foreach ($module in $requiredModules) {
    $fullPath = Join-Path $modulePath $module
    if (Test-Path $fullPath) {
        Import-Module $fullPath -Force -DisableNameChecking
    }
}

foreach ($module in $toolModules) {
    $fullPath = Join-Path $toolsPath $module
    if (Test-Path $fullPath) {
        Import-Module $fullPath -Force -DisableNameChecking
    }
}

# Initialize Settings Manager
Initialize-SettingsManager -RepoRoot $Script:RepoRoot

#endregion

#region Path Relocation Check

# Check if folder was moved and needs path repair
$continueExecution = Invoke-PathRelocationCheck -CurrentPath $Script:RepoRoot
if (-not $continueExecution) {
    exit 1
}

#endregion

#region Installation Status

function Get-InstallationStatus {
    <#
    .SYNOPSIS
        Check if OpenClaw is installed and detect portable scenarios
    .OUTPUTS
        PSCustomObject with Installed, NeedsImport, State, OpenClawInstalled, and StatusText properties
    #>
    [CmdletBinding()]
    param()
    
    $localPath = Join-Path $Script:RepoRoot ".local"
    $wslPath = Join-Path $localPath "wsl"
    $stateFile = Join-Path $localPath "state.json"
    
    $result = @{
        Installed         = $false
        NeedsImport       = $false
        State             = $null
        StatusText        = "Not Installed"
        StatusColor       = "Red"
        WSLPath           = $wslPath
        OpenClawInstalled = $false
        InstallMethod     = $null
    }
    
    # Check if WSL data exists locally
    $hasLocalWSLData = Test-LocalWSLDataExists -LocalWSLPath $wslPath
    
    # Check state file first to get the actual distribution name if stored
    $hasStateFile = Test-Path $stateFile
    $state = $null
    $distroName = $null
    
    if ($hasStateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state -and $state.DistroName) {
                $distroName = $state.DistroName
            }
        }
        catch {
            # Ignore parse errors
        }
    }
    
    # If no distro name from state, use the default
    if (-not $distroName) {
        $distroName = Get-OpenClawDistroName
    }
    
    $isRegistered = Test-DistributionExists -Name $distroName
    
    if ($hasStateFile -and $state) {
        $result.State = $state
        
        # Get install method from state
        if ($state.PSObject.Properties['InstallMethod']) {
            $result.InstallMethod = $state.InstallMethod
        }
        
        # Format install date
        $installDate = if ($state.InstallDate) {
            try { 
                ([DateTime]$state.InstallDate).ToString("yyyy-MM-dd") 
            }
            catch { 
                "Unknown" 
            }
        }
        else { 
            "Unknown" 
        }
        
        if ($isRegistered) {
            # Fully installed and registered
            $result.Installed = $true
            $result.StatusText = "Installed ($installDate)"
            $result.StatusColor = "Green"
            
            # Check if OpenClaw is actually installed (npm or git)
            $username = if ($state.LinuxUsername) { $state.LinuxUsername } else { "openclaw" }
            
            # Check npm first (command exists?)
            try {
                $npmInstalled = Test-OpenClawNpmInstalled -DistroName $distroName -User $username
                if ($npmInstalled) {
                    $result.OpenClawInstalled = $true
                    $result.InstallMethod = "npm"
                }
            }
            catch {
                # Function may not be available
            }
            
            # If not npm, check if git repo exists
            if (-not $result.OpenClawInstalled) {
                $openclawPath = if ($state.LinuxOpenClawPath) { $state.LinuxOpenClawPath } else { "/home/$username/openclaw" }
                try {
                    $gitRepoExists = Test-GitRepositoryExists -DistroName $distroName -Path $openclawPath -User $username
                    if ($gitRepoExists) {
                        $result.OpenClawInstalled = $true
                        $result.InstallMethod = "git"
                    }
                }
                catch {
                    # Function may not be available
                }
            }
            
            # Only trust state file if we couldn't check directly
            if (-not $result.OpenClawInstalled -and $state.PSObject.Properties['OpenClawCloned'] -and $state.OpenClawCloned) {
                # State says installed but we couldn't verify - mark as not installed
                # This prevents showing "Launch" when openclaw command doesn't exist
                $result.OpenClawInstalled = $false
            }
        }
        elseif ($hasLocalWSLData) {
            # Has data but needs to be re-imported (portable scenario)
            $result.NeedsImport = $true
            $result.StatusText = "Needs Import (moved/copied)"
            $result.StatusColor = "Yellow"
        }
        else {
            # State file exists but no WSL data - corrupted
            $result.StatusText = "Incomplete Installation"
            $result.StatusColor = "Yellow"
        }
    }
    elseif ($hasLocalWSLData) {
        # WSL data exists but no state file - can still import
        $result.NeedsImport = $true
        $result.StatusText = "WSL Data Found (needs import)"
        $result.StatusColor = "Yellow"
    }
    elseif ($isRegistered) {
        # Distribution registered but no local data - external install
        $result.Installed = $true
        $result.StatusText = "Registered (external)"
        $result.StatusColor = "Green"
        
        # Try to check if OpenClaw is installed via npm
        try {
            $npmInstalled = Test-OpenClawNpmInstalled -DistroName $distroName -User "openclaw"
            if ($npmInstalled) {
                $result.OpenClawInstalled = $true
                $result.InstallMethod = "npm"
            }
        }
        catch {
            # Ignore errors
        }
    }
    
    return [PSCustomObject]$result
}

function Get-UpdateStatus {
    <#
    .SYNOPSIS
        Check if script updates are available
    .OUTPUTS
        PSCustomObject with Available, CurrentHash, RemoteHash properties
    #>
    [CmdletBinding()]
    param()
    
    $result = @{
        Available   = $false
        CanCheck    = $false
        CurrentHash = $null
        RemoteHash  = $null
    }
    
    $gitDir = Join-Path $Script:RepoRoot ".git"
    if (-not (Test-Path $gitDir)) {
        return [PSCustomObject]$result
    }
    
    $result.CanCheck = $true
    
    Push-Location $Script:RepoRoot
    try {
        # Get local hash
        $localHash = git rev-parse HEAD 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.CurrentHash = $localHash.Substring(0, 7)
        }
        
        # Fetch silently and check remote
        git fetch origin --quiet 2>&1 | Out-Null
        $remoteHash = git rev-parse origin/main 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.RemoteHash = $remoteHash.Substring(0, 7)
            $result.Available = ($localHash -ne $remoteHash)
        }
    }
    catch {
        # Silently ignore errors
    }
    finally {
        Pop-Location
    }
    
    return [PSCustomObject]$result
}

#endregion

#region Menu Actions

function Invoke-InstallOpenClaw {
    Show-Section "Install OpenClaw"
    
    # Check if running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Show-InfoBox -Title "Administrator Required" -Type "Warning" -Lines @(
            "The installation requires administrator privileges.",
            "",
            "Please run this script as Administrator:",
            "  Right-click PowerShell > 'Run as administrator'"
        )
        Wait-ForKeyPress
        return
    }
    
    # Run the installer from scripts/internal
    $installerPath = Join-Path $Script:RepoRoot "scripts\internal\Install-OpenClaw.ps1"
    
    if (-not (Test-Path $installerPath)) {
        Show-Status "Installer not found: $installerPath" -Type "Error"
        Wait-ForKeyPress
        return
    }
    
    Write-Host ""
    Show-Status "Starting OpenClaw installation..." -Type "Info"
    Write-Host ""
    
    try {
        & $installerPath
    }
    catch {
        Show-Status "Installation error: $_" -Type "Error"
    }
    
    Wait-ForKeyPress
}

function Invoke-ConfigureOllamaNetworking {
    <#
    .SYNOPSIS
        Configure Ollama networking for WSL connectivity
    .DESCRIPTION
        Sets up WSL to communicate with Ollama running on Windows.
        Handles mirrored networking configuration and connection testing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Show-Section "Configure Ollama Networking"
    
    # Check if Ollama is installed
    if (-not (Test-OllamaInstalled)) {
        Show-OllamaNotInstalled
        Wait-ForKeyPress
        return
    }
    
    # Check if Ollama is running
    $ollamaRunning = Test-OllamaRunning
    if (-not $ollamaRunning) {
        if (Confirm-Action "Ollama is not running. Start it now?") {
            Show-Progress "Starting Ollama..."
            $startResult = Start-Ollama
            if ($startResult.Success) {
                Show-Status $startResult.Message -Type "Success"
            } else {
                Show-Status $startResult.Message -Type "Error"
                Wait-ForKeyPress
                return
            }
        } else {
            Wait-ForKeyPress
            return
        }
    }
    
    # Configure Ollama network access in WSL
    Show-Progress "Configuring Ollama network access..."
    $configResult = Set-OllamaConfigInWSL -DistroName $DistroName -Username $Username
    
    if (-not $configResult.Success) {
        $errorMsg = if ($configResult.Message) { $configResult.Message } else { "Unknown error" }
        Show-Status "Failed to configure network: $errorMsg" -Type "Error"
        Wait-ForKeyPress
        return
    }
    
    Show-Status "Network configuration updated" -Type "Success"
    Write-Host ""
    Write-Host "  OLLAMA_HOST = $($configResult.OllamaHost)" -ForegroundColor DarkGray
    Write-Host ""
    
    # Test connection from WSL
    Show-Progress "Testing Ollama connection from WSL..."
    if (Test-OllamaFromWSL -DistroName $DistroName) {
        Show-Status "WSL can connect to Ollama" -Type "Success"
        Wait-ForKeyPress
        return
    }
    
    # Connection failed - try to help
    Show-Status "WSL cannot reach Ollama" -Type "Warning"
    Write-Host ""
    
    # Check if mirrored networking is enabled
    $mirroredStatus = Test-WSLMirroredNetworking
    
    if (-not $mirroredStatus.Enabled) {
        Show-InfoBox -Title "Network Configuration Required" -Type "Warning" -Lines @(
            "Ollama runs on Windows but OpenClaw runs in WSL (Linux).",
            "WSL needs 'mirrored networking' to reach Windows services.",
            "",
            "This enables WSL to use localhost to connect to Ollama.",
            "It's a simple, secure one-time configuration change.",
            "",
            "Note: WSL will need to restart after this change."
        )
        
        $configure = Confirm-Action -Message "Enable mirrored networking for WSL?" -Default $true
        
        if ($configure) {
            Show-Progress "Enabling mirrored networking in .wslconfig..."
            $mirrorResult = Enable-WSLMirroredNetworking
            
            if ($mirrorResult.Success) {
                Show-Status $mirrorResult.Message -Type "Success"
                
                if ($mirrorResult.NeedsRestart) {
                    Write-Host ""
                    $restart = Confirm-Action -Message "Restart WSL now to apply changes?" -Default $true
                    
                    if ($restart) {
                        Show-Progress "Restarting WSL..."
                        & wsl.exe --shutdown 2>&1 | Out-Null
                        Start-Sleep -Seconds 3
                        Show-Status "WSL restarted" -Type "Success"
                        
                        # Update the bashrc to use localhost
                        Show-Progress "Updating OpenClaw configuration to use localhost..."
                        $configResult = Set-OllamaConfigInWSL -DistroName $DistroName -Username $Username -OllamaHost "http://localhost:11434"
                        
                        # Test again
                        Start-Sleep -Seconds 2
                        Show-Progress "Testing connection..."
                        if (Test-OllamaFromWSL -DistroName $DistroName) {
                            Show-Status "WSL can now connect to Ollama!" -Type "Success"
                        } else {
                            Show-Status "Connection still failing - Ollama may need restart" -Type "Warning"
                            Write-Host "  Please restart Ollama from the system tray and try again." -ForegroundColor DarkGray
                        }
                    } else {
                        Write-Host ""
                        Write-Host "  Please restart WSL manually: wsl --shutdown" -ForegroundColor DarkGray
                        Write-Host "  Then run this configuration again." -ForegroundColor DarkGray
                    }
                }
            } else {
                Show-Status "Failed: $($mirrorResult.Message)" -Type "Error"
            }
        } else {
            Write-Host ""
            Write-Host "  To enable manually, add to %USERPROFILE%\.wslconfig:" -ForegroundColor DarkGray
            Write-Host "    [wsl2]" -ForegroundColor DarkGray
            Write-Host "    networkingMode=mirrored" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Then run: wsl --shutdown" -ForegroundColor DarkGray
        }
    } else {
        # Mirrored networking is enabled but still can't connect
        Write-Host "  Mirrored networking is enabled but connection still fails." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  This usually means Ollama needs to be restarted." -ForegroundColor DarkGray
        Write-Host ""
        
        $tryRestart = Confirm-Action -Message "Try restarting Ollama now?" -Default $true
        if ($tryRestart) {
            Show-Progress "Restarting Ollama..."
            Stop-OllamaServer | Out-Null
            Start-Sleep -Seconds 2
            $startResult = Start-Ollama
            
            if ($startResult.Success) {
                Start-Sleep -Seconds 3
                Show-Progress "Testing connection..."
                if (Test-OllamaFromWSL -DistroName $DistroName) {
                    Show-Status "WSL can now connect to Ollama!" -Type "Success"
                } else {
                    Show-Status "Still cannot connect" -Type "Warning"
                    Write-Host "  Try: wsl --shutdown (then restart this launcher)" -ForegroundColor DarkGray
                }
            }
        }
    }
    
    Wait-ForKeyPress
}

function Invoke-ConfigureOllamaSetup {
    <#
    .SYNOPSIS
        Configure local Ollama integration for OpenClaw
    .DESCRIPTION
        Provides menu interface for Ollama-specific configuration:
        - Select Ollama model from locally installed models
        - Configure WSL networking for Ollama access
        - Enable/disable Ollama as AI provider
        
        Note: For other AI providers (Claude, GPT, etc.), configure them
        directly in the OpenClaw terminal using 'openclaw setup'.
    #>
    [CmdletBinding()]
    param()
    
    Show-Section "Ollama Setup"
    
    # Check if Ollama is installed on Windows
    $ollamaInstalled = Test-OllamaInstalled
    if (-not $ollamaInstalled) {
        Show-OllamaNotInstalled
        Wait-ForKeyPress
        return
    }
    
    # Get WSL info
    $distroName = Get-OpenClawDistroName
    $username = "openclaw"
    
    # Check if WSL distro exists
    $distros = Get-InstalledDistributions
    $openclawDistro = $distros | Where-Object { $_.Name -eq $distroName }
    
    if (-not $openclawDistro) {
        Show-InfoBox -Title "WSL Not Configured" -Type "Warning" -Lines @(
            "OpenClaw WSL distribution not found.",
            "",
            "Please run 'Install OpenClaw' first to set up the WSL environment."
        )
        Wait-ForKeyPress
        return
    }
    
    # Check if OpenClaw is installed
    $openclawInstalled = Test-OpenClawInstalled -DistroName $distroName -Username $username
    if (-not $openclawInstalled) {
        Show-InfoBox -Title "OpenClaw Not Installed" -Type "Warning" -Lines @(
            "OpenClaw is not installed in the WSL environment.",
            "",
            "Please complete the installation first."
        )
        Wait-ForKeyPress
        return
    }
    
    while ($true) {
        # Check Ollama status
        $ollamaRunning = Test-OllamaRunning
        $ollamaModels = if ($ollamaRunning) { Get-OllamaModels } else { @() }
        $ollamaProviderStatus = Get-OllamaProviderStatus -DistroName $distroName -Username $username
        
        # Get current OpenClaw model to show if it's an Ollama model
        $currentModel = Get-OpenClawCurrentModel -DistroName $distroName -Username $username
        $currentOllamaModel = if ($currentModel -match '^ollama/(.+)$') { $Matches[1] } else { $null }
        
        # Show status info
        Write-Host ""
        Write-Host "  ┌─ Ollama Status ───────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host "  │" -ForegroundColor Cyan
        
        # Version
        $version = Get-OllamaVersion
        Write-Host "  │  Version: " -ForegroundColor Cyan -NoNewline
        Write-Host "$version" -ForegroundColor White
        
        # Running status
        Write-Host "  │  Status: " -ForegroundColor Cyan -NoNewline
        if ($ollamaRunning) {
            Write-Host "Running" -ForegroundColor Green
        } else {
            Write-Host "Not running" -ForegroundColor Yellow
        }
        
        # Models count
        Write-Host "  │  Models: " -ForegroundColor Cyan -NoNewline
        if ($ollamaModels.Count -gt 0) {
            Write-Host "$($ollamaModels.Count) installed" -ForegroundColor White
        } else {
            Write-Host "None installed" -ForegroundColor Yellow
        }
        
        # Provider enabled status
        Write-Host "  │  Provider: " -ForegroundColor Cyan -NoNewline
        if ($ollamaProviderStatus.Enabled) {
            Write-Host "Enabled" -ForegroundColor Green
        } else {
            Write-Host "Disabled" -ForegroundColor DarkGray
        }
        
        # Current Ollama model in use
        Write-Host "  │" -ForegroundColor Cyan
        if ($currentOllamaModel) {
            Write-Host "  │  Active Model: " -ForegroundColor Cyan -NoNewline
            Write-Host "ollama/$currentOllamaModel" -ForegroundColor Green
        } elseif ($currentModel) {
            Write-Host "  │  Active Model: " -ForegroundColor Cyan -NoNewline
            Write-Host "$currentModel (not Ollama)" -ForegroundColor DarkGray
        }
        
        Write-Host "  │" -ForegroundColor Cyan
        Write-Host "  └──────────────────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host ""
        
        # Build menu options
        $menuOptions = @()
        
        # Change Model option - select from local Ollama models
        $menuOptions += @{
            Text        = "Change Ollama Model"
            Description = "Select from locally installed Ollama models"
            Action      = "ChangeModel"
            Disabled    = ($ollamaModels.Count -eq 0) -or (-not $ollamaRunning)
        }
        
        # Configure networking
        $menuOptions += @{
            Text        = "Configure Networking"
            Description = "Set up WSL to communicate with Ollama on Windows"
            Action      = "Network"
        }
        
        # Enable/Disable provider
        if ($ollamaProviderStatus.Enabled) {
            $menuOptions += @{
                Text        = "Disable Ollama Provider"
                Description = "Turn off Ollama integration in OpenClaw"
                Action      = "DisableProvider"
            }
        } else {
            $menuOptions += @{
                Text        = "Enable Ollama Provider"
                Description = "Turn on Ollama integration in OpenClaw"
                Action      = "EnableProvider"
            }
        }
        
        # Back
        $menuOptions += @{
            Text        = "← Back"
            Description = ""
            Action      = "Back"
        }
        
        $selection = Show-SelectMenu -Title "Ollama Setup" -Options $menuOptions -Footer "Select an option"
        
        switch ($selection.Action) {
            "ChangeModel" {
                # Show local Ollama models for selection
                $selectedModel = Show-OllamaModelSelectionMenu -Models $ollamaModels -CurrentModel $currentOllamaModel
                
                if ($selectedModel) {
                    # Warn if another non-Ollama provider is currently in use
                    if ($currentModel -and -not $currentOllamaModel) {
                        Show-InfoBox -Title "Warning" -Type "Warning" -Lines @(
                            "You are currently using a different AI provider:",
                            "  $currentModel",
                            "",
                            "Activating this Ollama model will replace your current model."
                        )
                        
                        if (-not (Confirm-Action "Switch to ollama/$($selectedModel)?")) {
                            continue
                        }
                    }
                    
                    Show-Progress "Setting OpenClaw to use 'ollama/$selectedModel'..."
                    $result = Set-OpenClawOllamaModel -DistroName $distroName -Username $username -ModelName $selectedModel
                    
                    if ($result.Success) {
                        Show-Status "Model set to ollama/$selectedModel" -Type "Success"
                        Write-LogMessage -Message "Ollama model changed to: $selectedModel" -Level "Info"
                    } else {
                        Show-Status $result.Message -Type "Error"
                        Write-LogMessage -Message "Failed to set Ollama model: $($result.Message)" -Level "Error"
                    }
                    Wait-ForKeyPress
                }
            }
            "Network" {
                Invoke-ConfigureOllamaNetworking -DistroName $distroName -Username $username
            }
            "EnableProvider" {
                Show-Progress "Enabling Ollama provider..."
                $result = Enable-OllamaProvider -DistroName $distroName -Username $username
                if ($result.Success) {
                    Show-Status "Ollama provider enabled" -Type "Success"
                    Write-LogMessage -Message "Ollama provider enabled" -Level "Info"
                    Write-Host ""
                    Write-Host "  Tip: Use 'Configure Networking' to set up WSL connectivity." -ForegroundColor DarkGray
                } else {
                    Show-Status "Failed: $($result.Message)" -Type "Error"
                }
                Wait-ForKeyPress
            }
            "DisableProvider" {
                if ($currentOllamaModel) {
                    Show-InfoBox -Title "Warning" -Type "Warning" -Lines @(
                        "You are currently using an Ollama model: ollama/$currentOllamaModel",
                        "",
                        "After disabling, configure another AI provider in the OpenClaw terminal",
                        "using 'openclaw setup' command."
                    )
                    
                    if (-not (Confirm-Action "Disable Ollama provider?")) {
                        continue
                    }
                }
                
                Show-Progress "Disabling Ollama provider..."
                $result = Disable-OllamaProvider -DistroName $distroName -Username $username
                if ($result.Success) {
                    Show-Status "Ollama provider disabled" -Type "Success"
                    Write-LogMessage -Message "Ollama provider disabled" -Level "Info"
                } else {
                    Show-Status "Failed: $($result.Message)" -Type "Error"
                }
                Wait-ForKeyPress
            }
            "Back" {
                return
            }
        }
    }
}

function Show-OllamaModelSelectionMenu {
    <#
    .SYNOPSIS
        Show menu to select from locally installed Ollama models
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Models,
        
        [Parameter()]
        [string]$CurrentModel
    )
    
    if (-not $Models -or $Models.Count -eq 0) {
        Show-InfoBox -Title "No Models" -Type "Warning" -Lines @(
            "No Ollama models are installed.",
            "",
            "Install models using: ollama pull <model-name>",
            "Popular models: llama3.2, mistral, codellama, phi3"
        )
        Wait-ForKeyPress
        return $null
    }
    
    Write-Host ""
    Write-Host "  Select an Ollama model:" -ForegroundColor White
    Write-Host ""
    
    # Build menu options from Ollama models
    $menuOptions = @()
    foreach ($model in $Models) {
        $modelName = $model.name
        $modelSize = if ($model.size) { 
            $sizeMB = [math]::Round($model.size / 1MB, 0)
            if ($sizeMB -gt 1024) {
                "$([math]::Round($sizeMB / 1024, 1)) GB"
            } else {
                "$sizeMB MB"
            }
        } else { "" }
        
        $isCurrent = $modelName -eq $CurrentModel
        $text = if ($isCurrent) { "$modelName (current)" } else { $modelName }
        $description = if ($modelSize) { "Size: $modelSize" } else { "" }
        
        $menuOptions += @{
            Text = $text
            Description = $description
            Action = $modelName
            Highlight = $isCurrent
        }
    }
    
    # Add back option
    $menuOptions += @{
        Text = "← Back"
        Description = "Return without changes"
        Action = "__BACK__"
    }
    
    $selection = Show-SelectMenu -Title "Available Ollama Models" -Options $menuOptions
    $selectedAction = if ($selection -and $selection.Action) { $selection.Action } else { $null }
    
    if ($selectedAction -eq "__BACK__" -or -not $selectedAction) {
        return $null
    }
    
    return $selectedAction
}

function Invoke-UpdateScripts {
    Show-Section "Update Scripts"
    
    Show-Progress "Checking for updates..."
    
    # Check if we're in a git repo
    $gitDir = Join-Path $Script:RepoRoot ".git"
    if (-not (Test-Path $gitDir)) {
        Show-Status "Not a git repository. Cannot update." -Type "Error"
        Wait-ForKeyPress
        return
    }
    
    try {
        Push-Location $Script:RepoRoot
        
        # Check for local changes first
        $localChanges = git status --porcelain 2>&1
        if (-not [string]::IsNullOrWhiteSpace($localChanges)) {
            Show-InfoBox -Title "Local Changes Detected" -Type "Warning" -Lines @(
                "You have uncommitted local changes.",
                "",
                "Options:",
                "  1. Stash changes: git stash",
                "  2. Commit changes: git commit",
                "  3. Discard changes: git checkout ."
            )
            Wait-ForKeyPress
            return
        }
        
        # Fetch updates
        Show-Progress "Fetching from remote..."
        $fetchResult = git fetch origin 2>&1
        
        # Check if there are updates
        $localHash = git rev-parse HEAD 2>&1
        $remoteHash = git rev-parse origin/main 2>&1
        
        if ($localHash -eq $remoteHash) {
            Show-Status "Already up to date" -Type "Success"
        }
        else {
            Show-Progress "Pulling updates..."
            $pullResult = git pull --ff-only origin main 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Show-Status "Scripts updated successfully" -Type "Success"
                Write-Host ""
                Write-Host "  Changes:" -ForegroundColor DarkGray
                git --no-pager log --oneline $localHash..HEAD 2>&1 | ForEach-Object {
                    Write-Host "    $_" -ForegroundColor DarkGray
                }
                Write-Host ""
                Write-Host "  Please restart the script to use the updated version." -ForegroundColor Yellow
            }
            else {
                Show-Status "Update failed: $pullResult" -Type "Error"
            }
        }
    }
    catch {
        Show-Status "Update error: $_" -Type "Error"
    }
    finally {
        Pop-Location
    }
    
    Wait-ForKeyPress
}

function Invoke-RegenerateLaunchers {
    Show-Section "Regenerate Launch Scripts"
    
    $stateFile = Join-Path $Script:RepoRoot ".local\state.json"
    if (-not (Test-Path $stateFile)) {
        Show-Status "No installation found. Install OpenClaw first." -Type "Error"
        Wait-ForKeyPress
        return
    }
    
    try {
        Show-Progress "Loading state..."
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        
        # Import LauncherGenerator module
        $launcherModule = Join-Path $Script:RepoRoot "modules\LauncherGenerator.psm1"
        Import-Module $launcherModule -Force
        
        $scriptsDir = Join-Path $Script:RepoRoot ".local\scripts"
        $launchScriptPath = Join-Path $scriptsDir "launch-openclaw.ps1"
        
        Show-Progress "Regenerating launch script..."
        
        if ($state.InstallMethod -eq "npm") {
            $null = New-LaunchScript `
                -OutputPath $launchScriptPath `
                -DistroName $state.DistroName `
                -InstallMethod "npm" `
                -RepoRoot $Script:RepoRoot
        } else {
            $null = New-LaunchScript `
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
        
        Show-Status "Launch scripts regenerated successfully" -Type "Success"
        Write-Host ""
        Write-Host "  Updated files:" -ForegroundColor DarkGray
        Write-Host "    - .local\scripts\launch-openclaw.ps1" -ForegroundColor White
        Write-Host "    - .local\scripts\launch-openclaw.bat" -ForegroundColor White
        Write-Host "    - .local\scripts\open-shell.ps1" -ForegroundColor White
        Write-Host "    - .local\scripts\update-openclaw.ps1" -ForegroundColor White
        Write-Host "    - .local\scripts\stop-wsl.ps1" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Show-Status "Regenerate failed: $_" -Type "Error"
    }
    
    Wait-ForKeyPress
}

#endregion

#region Uninstall

function Invoke-UninstallOpenClaw {
    Show-Section "Uninstall OpenClaw"
    
    # Check if running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Show-InfoBox -Title "Administrator Required" -Type "Warning" -Lines @(
            "The uninstallation requires administrator privileges.",
            "",
            "Please run this script as Administrator:",
            "  Right-click PowerShell > 'Run as administrator'"
        )
        Wait-ForKeyPress
        return
    }
    
    # Run the uninstaller from scripts/internal
    $uninstallerPath = Join-Path $Script:RepoRoot "scripts\internal\Uninstall-OpenClaw.ps1"
    
    if (-not (Test-Path $uninstallerPath)) {
        Show-Status "Uninstaller not found: $uninstallerPath" -Type "Error"
        Wait-ForKeyPress
        return
    }
    
    try {
        & $uninstallerPath
    }
    catch {
        Show-Status "Uninstallation error: $_" -Type "Error"
        Wait-ForKeyPress
    }
}

#endregion

#region Launch OpenClaw

function Invoke-LaunchOpenClaw {
    <#
    .SYNOPSIS
        Launches the OpenClaw application
    .DESCRIPTION
        Supports two launch modes controlled by launcher.launchMode setting:
        - sameWindow: Gateway runs in the current terminal (blocking, all logs visible)
        - newWindow: Gateway opens in a separate terminal window (non-blocking)
    #>
    [CmdletBinding()]
    param()
    
    # Check state to see if OpenClaw was installed
    $stateFile = Join-Path $Script:RepoRoot ".local\state.json"
    $distroName = "openclaw"
    $installMethod = "npm"
    
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            
            if ($state.DistroName) {
                $distroName = $state.DistroName
            }
            
            if ($state.InstallMethod) {
                $installMethod = $state.InstallMethod
            }
            
            if ($state.OpenClawCloned -eq $false) {
                Write-Host ""
                Show-Status "OpenClaw is not installed yet." -Type "Error"
                Write-Host ""
                Write-Host "  The WSL environment is ready, but OpenClaw" -ForegroundColor Yellow
                Write-Host "  was not available during installation." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Use 'Reinstall/Reconfigure' from the main menu to:" -ForegroundColor Cyan
                Write-Host "    • Install via npm (recommended)" -ForegroundColor White
                Write-Host "    • Clone from a git repository" -ForegroundColor White
                Write-Host "    • Copy from a local Windows folder" -ForegroundColor White
                Write-Host ""
                Wait-ForKeyPress
                return
            }
        }
        catch {
            # Ignore state parsing errors, continue to try launch
        }
    }
    
    # Read launch mode setting
    $launchMode = Get-UserSetting -Name "launcher.launchMode"
    if (-not $launchMode) { $launchMode = "sameWindow" }
    
    Write-Host ""
    Show-Status "Starting OpenClaw..." -Type "Info"
    Write-Host "  Distribution: $distroName" -ForegroundColor DarkGray
    Write-Host ""
    
    # Ensure WSL is running
    $null = & wsl.exe -d $distroName -e true 2>&1
    if ($LASTEXITCODE -ne 0) {
        Show-Status "WSL distribution '$distroName' not found." -Type "Error"
        Write-Host "  Please run Install from the main menu." -ForegroundColor DarkGray
        Wait-ForKeyPress
        return
    }
    
    # Stop any existing gateway first
    Write-Host "  Stopping any existing gateway..." -ForegroundColor DarkGray
    $null = & wsl.exe -d $distroName -- bash -lc "openclaw gateway stop 2>/dev/null; systemctl --user stop openclaw-gateway.service 2>/dev/null; pkill -f 'openclaw.*gateway' 2>/dev/null; sleep 1"
    
    # Ensure TLS crash guard exists (for existing installations that predate this fix)
    $guardScript = @"
process.on('uncaughtException', (err) => {
  if (err instanceof TypeError && err.message && err.message.includes("Cannot read properties of null (reading 'setSession')")) {
    return;
  }
  throw err;
});
"@
    $guardCheck = & wsl.exe -d $distroName -- bash -c 'test -f "$HOME/.openclaw/tls-crash-guard.js" && echo exists || echo missing'
    if ($guardCheck -match 'missing') {
        $guardScript | & wsl.exe -d $distroName -- bash -c 'mkdir -p "$HOME/.openclaw" && cat > "$HOME/.openclaw/tls-crash-guard.js"'
    }
    
    try {
        # Get token
        $gatewayToken = & wsl.exe -d $distroName -- bash -lc "jq -r '.gateway.auth.token // empty' ~/.openclaw/openclaw.json 2>/dev/null"
        $gatewayToken = if ($gatewayToken) { $gatewayToken.Trim() } else { "openclaw-local-token" }
        if ([string]::IsNullOrWhiteSpace($gatewayToken)) { $gatewayToken = "openclaw-local-token" }
        $dashboardUrl = "http://127.0.0.1:18789/?token=$gatewayToken"
        
        # Get current AI profile
        $currentModel = & wsl.exe -d $distroName -- bash -lc "jq -r '.agents.defaults.model.primary // empty' ~/.openclaw/openclaw.json 2>/dev/null"
        $currentModel = if ($currentModel) { $currentModel.Trim() } else { "Not configured" }
        
        # Open browser
        $autoOpenBrowser = Get-UserSetting -Name "launcher.autoOpenBrowser"
        if ($autoOpenBrowser -ne $false) {
            Start-Process $dashboardUrl
        }
        
        # Show gateway info
        Write-Host ""
        Write-Host "  +-- Gateway Info ------------------" -ForegroundColor Cyan
        Write-Host "  |" -ForegroundColor Cyan
        Write-Host "  |  Dashboard: " -ForegroundColor Cyan -NoNewline
        Write-Host "$dashboardUrl" -ForegroundColor White
        Write-Host "  |  Token:     " -ForegroundColor Cyan -NoNewline
        Write-Host "$gatewayToken" -ForegroundColor Yellow
        Write-Host "  |  AI Model:  " -ForegroundColor Cyan -NoNewline
        Write-Host "$currentModel" -ForegroundColor Green
        Write-Host "  |  Mode:      " -ForegroundColor Cyan -NoNewline
        Write-Host $(if ($launchMode -eq "sameWindow") { "Same window (logs visible)" } else { "New window" }) -ForegroundColor White
        Write-Host "  |" -ForegroundColor Cyan
        Write-Host "  +-----------------------------------" -ForegroundColor Cyan
        Write-Host ""
        
        $launchCmd = 'export PATH="$HOME/.npm-global/bin:$PATH" && export NODE_OPTIONS="--require $HOME/.openclaw/tls-crash-guard.js" && while true; do openclaw gateway --bind lan --port 18789 --verbose; EXIT_CODE=$?; if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 130 ]; then break; fi; echo "[openclaw] Gateway crashed (exit $EXIT_CODE), restarting in 3s..."; sleep 3; done'
        
        if ($launchMode -eq "sameWindow") {
            # Same window: run gateway in current terminal (blocking, all logs visible)
            Write-Host "  Gateway is running below. Press Ctrl+C to stop." -ForegroundColor Yellow
            Write-Host "  $('-' * 50)" -ForegroundColor DarkGray
            Write-Host ""
            
            & wsl.exe -d $distroName -- bash -lc $launchCmd
            
            Write-Host ""
            Write-Host "  $('-' * 50)" -ForegroundColor DarkGray
            Write-Host "  Gateway stopped." -ForegroundColor DarkGray
        }
        else {
            # New window: launch in separate terminal (non-blocking)
            Write-Host "  Gateway is starting in a separate window." -ForegroundColor DarkGray
            Write-Host "  Close that window or press Ctrl+C there to stop." -ForegroundColor DarkGray
            Write-Host ""
            
            $wtPath = Get-Command wt.exe -ErrorAction SilentlyContinue
            if ($wtPath) {
                Start-Process wt.exe -ArgumentList "wsl.exe -d $distroName -- bash -lc '$launchCmd'"
            } else {
                Start-Process cmd.exe -ArgumentList "/c start `"OpenClaw Gateway`" wsl.exe -d $distroName -- bash -lc '$launchCmd'"
            }
        }
    }
    catch {
        Show-Status "Failed to launch OpenClaw: $_" -Type "Error"
    }
    
    Wait-ForKeyPress
}

function Invoke-OpenWSLTerminal {
    <#
    .SYNOPSIS
        Opens an interactive bash terminal in the WSL environment
    #>
    [CmdletBinding()]
    param()
    
    # Get distro name from state
    $stateFile = Join-Path $Script:RepoRoot ".local\state.json"
    $distroName = "openclaw"
    
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.DistroName) {
                $distroName = $state.DistroName
            }
        }
        catch {
            # Use default distro name
        }
    }
    
    Write-Host ""
    Show-Status "Opening WSL terminal for '$distroName'..." -Type "Info"
    Write-Host ""
    Write-Host "  Type 'exit' to return to this menu." -ForegroundColor DarkGray
    Write-Host ""
    
    try {
        # Launch interactive bash shell
        & wsl.exe -d $distroName
    }
    catch {
        Show-Status "Failed to open terminal: $_" -Type "Error"
        Wait-ForKeyPress
    }
}

#endregion

#region Command Presets

function Invoke-CommandPresets {
    <#
    .SYNOPSIS
        Shows the Command Presets menu for quick access to common OpenClaw commands
    #>
    [CmdletBinding()]
    param()
    
    # Get distro name and username from state
    $stateFile = Join-Path $Script:RepoRoot ".local\state.json"
    $distroName = "openclaw"
    $username = $null
    
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.DistroName) {
                $distroName = $state.DistroName
            }
            if ($state.LinuxUsername) {
                $username = $state.LinuxUsername
            }
        }
        catch {
            # Use defaults
        }
    }
    
    Show-CommandPresetMenu -RepoRoot $Script:RepoRoot -DistroName $distroName -Username $username
}

#endregion

#region Import WSL

function Invoke-ImportWSL {
    <#
    .SYNOPSIS
        Imports existing WSL data when folder was copied/moved to new system
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WSLPath
    )
    
    Show-Section "Import Existing WSL Data"
    
    # Check if running as admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Show-InfoBox -Title "Administrator Required" -Type "Warning" -Lines @(
            "Importing WSL requires administrator privileges.",
            "",
            "Please run this script as Administrator:",
            "  Right-click PowerShell > 'Run as administrator'"
        )
        Wait-ForKeyPress
        return
    }
    
    # Get WSL status details
    $wslStatus = Get-LocalWSLStatus -LocalWSLPath $WSLPath
    
    # Show what will be imported
    Write-Host ""
    Write-Host "  Found existing OpenClaw WSL data:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  │ Location: $WSLPath" -ForegroundColor DarkGray
    if ($wslStatus.HasVhdx) {
        $vhdxSize = (Get-Item $wslStatus.VhdxPath).Length
        $sizeStr = "{0:N2} GB" -f ($vhdxSize / 1GB)
        Write-Host "  │ WSL Disk: ext4.vhdx ($sizeStr)" -ForegroundColor DarkGray
    }
    if ($wslStatus.HasTar) {
        $tarSize = (Get-Item $wslStatus.TarPath).Length
        $sizeStr = "{0:N2} GB" -f ($tarSize / 1GB)
        Write-Host "  │ Backup: openclaw.tar ($sizeStr)" -ForegroundColor DarkGray
    }
    Write-Host "  └─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    
    Write-Host "  This will register the existing WSL data with Windows." -ForegroundColor Yellow
    Write-Host "  Your Linux environment and all installed software will be available." -ForegroundColor Yellow
    Write-Host ""
    
    # Ask for confirmation
    if (-not (Confirm-Action "Proceed with import?")) {
        Write-Host ""
        Show-Status "Import cancelled" -Type "Info"
        Wait-ForKeyPress
        return
    }
    
    Write-Host ""
    Show-Progress "Importing WSL distribution..."
    
    try {
        $result = Import-DistributionFromLocal -LocalWSLPath $WSLPath
        
        if ($result.Success) {
            # Create/update state.json to reflect imported state
            $localPath = Join-Path $Script:RepoRoot ".local"
            $stateFile = Join-Path $localPath "state.json"
            
            # Check if state.json already exists (may have been copied with the data)
            $existingState = $null
            if (Test-Path $stateFile) {
                try {
                    $existingState = Get-Content $stateFile -Raw | ConvertFrom-Json
                }
                catch {
                    # Ignore parse errors, will create new state
                }
            }
            
            # Create or update state with current import info
            $state = @{
                WindowsInstallPath = $Script:RepoRoot
                LocalPath          = $localPath
                DistroName         = $result.DistroName
                InstallDate        = if ($existingState -and $existingState.InstallDate) { $existingState.InstallDate } else { (Get-Date).ToString("o") }
                ImportDate         = (Get-Date).ToString("o")
                LinuxUsername      = if ($existingState -and $existingState.LinuxUsername) { $existingState.LinuxUsername } else { "openclaw" }
                OpenClawCloned     = if ($existingState -and $null -ne $existingState.OpenClawCloned) { $existingState.OpenClawCloned } else { $true }
            }
            
            # Copy over additional fields from existing state if present
            if ($existingState) {
                @('LinuxOpenClawPath', 'FilesystemMode', 'NetworkMode', 'DataFolderPath', 
                    'DataFolderLinuxPath', 'LaunchScriptPath', 'LaunchCommand', 'OpenClawWindowsPath') | ForEach-Object {
                    if ($existingState.PSObject.Properties[$_]) {
                        $state[$_] = $existingState.$_
                    }
                }
            }
            
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Force
            
            Write-Host ""
            Show-Status "WSL distribution imported successfully!" -Type "Success"
            Write-Host ""
            Write-Host "  Distribution: $($result.DistroName)" -ForegroundColor DarkGray
            Write-Host "  You can now use OpenClaw on this system." -ForegroundColor DarkGray
            Write-Host ""
        }
        else {
            Show-Status "Import failed" -Type "Error"
        }
    }
    catch {
        Write-Host ""
        Show-Status "Import failed: $_" -Type "Error"
    }
    
    Wait-ForKeyPress
}

#endregion

#region Settings Menu

function Show-LauncherSettingsMenu {
    <#
    .SYNOPSIS
        Shows the Launcher Settings submenu for configuring startup behavior
    #>
    [CmdletBinding()]
    param()
    
    while ($true) {
        # Get current settings
        $autoOpenBrowser = Get-UserSetting -Name "launcher.autoOpenBrowser"
        $browserCommand = Get-UserSetting -Name "launcher.browserCommand"
        $startupWait = Get-UserSetting -Name "launcher.gatewayStartupWaitSeconds"
        $launchMode = Get-UserSetting -Name "launcher.launchMode"
        $bannerTitle = Get-UserSetting -Name "ui.bannerTitle"
        $maxTitleLength = Get-UserSetting -Name "ui.bannerTitleMaxLength"
        if (-not $maxTitleLength) { $maxTitleLength = 8 }
        
        # Format current values for display
        $browserStatus = if ($autoOpenBrowser) { "ON" } else { "OFF" }
        $browserCmdStatus = if ($browserCommand) { $browserCommand } else { "System default" }
        $waitStatus = "${startupWait}s"
        $launchModeStatus = if ($launchMode -eq "sameWindow") { "Same window" } else { "New window" }
        
        $menuOptions = @(
            @{
                Text        = "Banner title: $bannerTitle"
                Description = "Customize the ASCII art title (max $maxTitleLength chars, A-Z 0-9 - space)"
                Action      = "BannerTitle"
            },
            @{
                Text        = "Launch mode: $launchModeStatus"
                Description = "Open OpenClaw in new WSL window or run in same terminal"
                Action      = "ToggleLaunchMode"
            },
            @{
                Text        = "Auto-open browser: $browserStatus"
                Description = "Automatically open dashboard URL when launching OpenClaw"
                Action      = "ToggleBrowser"
            },
            @{
                Text        = "Browser command: $browserCmdStatus"
                Description = "Specify custom browser or use system default"
                Action      = "BrowserCommand"
            },
            @{
                Text        = "Startup wait: $waitStatus"
                Description = "Seconds to wait for gateway before opening browser"
                Action      = "StartupWait"
            },
            @{
                Text        = "Reset to defaults"
                Description = "Restore all launcher settings to default values"
                Action      = "Reset"
            },
            @{
                Text        = "← Back"
                Description = ""
                Action      = "Back"
            }
        )
        
        $selection = Show-SelectMenu -Title "Launcher Settings" -Options $menuOptions -ShowBanner -Footer "Select an option"
        
        switch ($selection.Action) {
            "BannerTitle" {
                Show-Section "Banner Title"
                Write-Host "  Current: $bannerTitle" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  Enter a new banner title (1-$maxTitleLength characters)." -ForegroundColor Yellow
                Write-Host "  Allowed: A-Z, 0-9, hyphen (-), space" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  > " -NoNewline -ForegroundColor Gray
                $newTitle = Read-Host
                
                if ([string]::IsNullOrWhiteSpace($newTitle)) {
                    Show-Status "No changes made" -Type "Info"
                    Start-Sleep -Milliseconds 800
                    continue
                }
                
                $newTitle = $newTitle.Trim()
                $validation = Test-BannerTitleValid -Title $newTitle -MaxLength $maxTitleLength
                
                if ($validation.Valid) {
                    Set-UserSetting -Name "ui.bannerTitle" -Value $newTitle
                    Show-Status "Banner title set to: $newTitle" -Type "Success"
                    Start-Sleep -Seconds 1
                } else {
                    Show-Status $validation.Message -Type "Error"
                    Wait-ForKeyPress
                }
            }
            "ToggleLaunchMode" {
                $newValue = if ($launchMode -eq "sameWindow") { "newWindow" } else { "sameWindow" }
                Set-UserSetting -Name "launcher.launchMode" -Value $newValue
                $status = if ($newValue -eq "sameWindow") { "Same window" } else { "New window" }
                Show-Status "Launch mode set to: $status" -Type "Success"
                Start-Sleep -Milliseconds 500
            }
            "ToggleBrowser" {
                $newValue = -not $autoOpenBrowser
                Set-UserSetting -Name "launcher.autoOpenBrowser" -Value $newValue
                $status = if ($newValue) { "enabled" } else { "disabled" }
                Show-Status "Auto-open browser $status" -Type "Success"
                Start-Sleep -Milliseconds 500
            }
            "BrowserCommand" {
                Show-Section "Browser Command"
                Write-Host "  Current: $browserCmdStatus" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  Enter a custom browser command or path." -ForegroundColor Yellow
                Write-Host "  Leave empty to use system default." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Examples:" -ForegroundColor DarkGray
                Write-Host "    chrome" -ForegroundColor DarkGray
                Write-Host "    firefox" -ForegroundColor DarkGray
                Write-Host "    C:\Program Files\Mozilla Firefox\firefox.exe" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  > " -NoNewline -ForegroundColor Gray
                $userInput = Read-Host
                
                if ([string]::IsNullOrWhiteSpace($userInput)) {
                    Reset-UserSetting -Name "launcher.browserCommand"
                    Show-Status "Browser command reset to system default" -Type "Success"
                } else {
                    Set-UserSetting -Name "launcher.browserCommand" -Value $userInput.Trim()
                    Show-Status "Browser command set to: $($userInput.Trim())" -Type "Success"
                }
                Start-Sleep -Seconds 1
            }
            "StartupWait" {
                Show-Section "Gateway Startup Wait"
                Write-Host "  Current: $startupWait seconds" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  How many seconds to wait for the gateway to start" -ForegroundColor Yellow
                Write-Host "  before attempting to open the browser." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Recommended: 3-10 seconds" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  > " -NoNewline -ForegroundColor Gray
                $userInput = Read-Host
                
                if ($userInput -match '^\d+$') {
                    $newWait = [int]$userInput
                    if ($newWait -lt 1) { $newWait = 1 }
                    if ($newWait -gt 60) { $newWait = 60 }
                    Set-UserSetting -Name "launcher.gatewayStartupWaitSeconds" -Value $newWait
                    Show-Status "Startup wait set to $newWait seconds" -Type "Success"
                } else {
                    Show-Status "Invalid input. Please enter a number." -Type "Error"
                }
                Start-Sleep -Seconds 1
            }
            "Reset" {
                if (Confirm-Action "Reset all launcher settings to defaults?") {
                    Reset-UserSetting -Name "launcher.autoOpenBrowser"
                    Reset-UserSetting -Name "launcher.browserCommand"
                    Reset-UserSetting -Name "launcher.gatewayStartupWaitSeconds"
                    Reset-UserSetting -Name "launcher.launchMode"
                    Reset-UserSetting -Name "ui.bannerTitle"
                    Show-Status "Launcher settings reset to defaults" -Type "Success"
                    Start-Sleep -Seconds 1
                }
            }
            "Back" {
                return
            }
        }
    }
}

function Get-OpenClawConfigStatus {
    <#
    .SYNOPSIS
        Gets the OpenClaw configuration status
    .OUTPUTS
        PSCustomObject with Configured property and status text
    #>
    [CmdletBinding()]
    param()
    
    $distroName = Get-OpenClawDistroName
    $stateFile = Join-Path $Script:RepoRoot ".local\state.json"
    $username = "openclaw"
    
    # Get username from state if available
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.LinuxUsername) {
                $username = $state.LinuxUsername
            }
        }
        catch {
            # Ignore corrupt/unreadable state file; fall back to defaults
        }
    }
    
    $result = @{
        Configured = $false
        StatusText = "Not configured"
    }
    
    try {
        $configured = Test-OpenClawConfigured -DistroName $distroName -User $username
        if ($configured) {
            $result.Configured = $true
            $result.StatusText = "Configured"
        }
    }
    catch {
        # Could not check - assume not configured
    }
    
    return [PSCustomObject]$result
}

function Show-SettingsMenu {
    <#
    .SYNOPSIS
        Shows the Settings submenu
    #>
    [CmdletBinding()]
    param()
    
    while ($true) {
        # Check Ollama status for indicator
        $ollamaInstalled = Test-OllamaInstalled
        $ollamaIndicator = if ($ollamaInstalled) { "" } else { " (Not installed)" }
        
        # Check if OpenClaw is installed for certain options
        $installStatus = Get-InstallationStatus
        $openClawInstalled = $installStatus.OpenClawInstalled -eq $true
        
        $menuOptions = @(
            @{
                Text        = "Ollama Setup$ollamaIndicator"
                Description = "Configure local Ollama for AI processing"
                Action      = "OllamaSetup"
                Disabled    = -not $ollamaInstalled
            },
            @{
                Text        = "Launcher Settings"
                Description = "Configure banner title, browser, startup options"
                Action      = "Launcher"
            }
        )
        
        # Command Presets - only if OpenClaw is installed
        $presetsOption = @{
            Text        = "Command Presets"
            Description = "Quick access to common OpenClaw commands"
            Action      = "Presets"
        }
        if (-not $openClawInstalled) {
            $presetsOption.Disabled = $true
            $presetsOption.Description = "Requires OpenClaw to be installed"
        }
        $menuOptions += $presetsOption
        
        # Update launcher scripts option
        $menuOptions += @{ 
            Text        = "Update Launcher Scripts"
            Description = "Pull latest OpenClaw-WSL updates from repository"
            Action      = "Update"
        }
        
        # Regenerate launchers option - only if installed
        $regenerateOption = @{ 
            Text        = "Regenerate Launchers"
            Description = "Recreate .bat/.ps1 launch scripts if corrupted or after updates"
            Action      = "Regenerate"
        }
        if (-not $installStatus.Installed) {
            $regenerateOption.Disabled = $true
            $regenerateOption.Description = "Requires OpenClaw to be installed first"
        }
        $menuOptions += $regenerateOption
        
        # Back option
        $menuOptions += @{
            Text        = "← Back to Main Menu"
            Description = ""
            Action      = "Back"
        }
        
        $selection = Show-SelectMenu -Title "Settings" -Options $menuOptions -ShowBanner -Footer "Select an option"
        
        switch ($selection.Action) {
            "OllamaSetup" {
                Invoke-ConfigureOllamaSetup
            }
            "Launcher" {
                Show-LauncherSettingsMenu
            }
            "Presets" {
                Invoke-CommandPresets
            }
            "Update" {
                Invoke-UpdateScripts
            }
            "Regenerate" {
                Invoke-RegenerateLaunchers
            }
            "Back" {
                return
            }
        }
    }
}

#endregion

#region Main Menu

function Show-MainMenu {
    while ($true) {
        # Get installation status (refresh each loop)
        $installStatus = Get-InstallationStatus
        
        # Check if OpenClaw is actually installed - ONLY trust actual detection, not state file
        # State file may be incorrect if installation was interrupted
        $openClawInstalled = $installStatus.OpenClawInstalled -eq $true
        
        # Get install method for display
        $installMethod = $installStatus.InstallMethod
        
        # Build menu options dynamically based on status
        $menuOptions = @()
        
        # Launch OpenClaw - only if WSL installed AND OpenClaw is available
        if ($installStatus.Installed) {
            if ($openClawInstalled) {
                $methodText = if ($installMethod) { " ($installMethod)" } else { "" }
                $menuOptions += @{ 
                    Text        = "Launch OpenClaw"
                    Description = "Start OpenClaw application$methodText"
                    Action      = "Launch"
                }
            }
            else {
                $menuOptions += @{ 
                    Text        = "Launch OpenClaw (not available)"
                    Description = "OpenClaw not installed - uninstall and reinstall"
                    Action      = "Launch"
                    Disabled    = $true
                }
            }
            
            # Open WSL Terminal - available when WSL is installed
            $menuOptions += @{ 
                Text        = "Open WSL Terminal"
                Description = "Open a bash terminal in the WSL environment"
                Action      = "Terminal"
            }
        }
        
        # Import option - only show when WSL data exists but not registered
        if ($installStatus.NeedsImport) {
            $menuOptions += @{ 
                Text        = "Import Existing WSL [Portable]"
                Description = "Register existing WSL data from copied/moved folder"
                Action      = "Import"
            }
        }
        
        # Install option - only show when NOT installed
        if (-not $installStatus.Installed) {
            if ($installStatus.NeedsImport) {
                $menuOptions += @{ 
                    Text        = "Fresh Install"
                    Description = "Ignore existing data and perform fresh installation"
                    Action      = "Install"
                }
            }
            else {
                $menuOptions += @{ 
                    Text        = "Install OpenClaw"
                    Description = "Set up WSL environment and install OpenClaw"
                    Action      = "Install"
                }
            }
        }
        
        # Settings submenu (only if installed)
        $settingsOption = @{ 
            Text        = "Settings"
            Description = "Configure OpenClaw, Ollama, and other options"
            Action      = "Settings"
        }
        if (-not $installStatus.Installed) {
            $settingsOption.Disabled = $true
            $settingsOption.Description = "Requires OpenClaw to be installed first"
        }
        $menuOptions += $settingsOption
        
        # Uninstall option (available if installed or has data to clean)
        $uninstallOption = @{ 
            Text        = "Uninstall OpenClaw"
            Description = "Remove WSL distribution and all OpenClaw data"
            Action      = "Uninstall"
        }
        if (-not $installStatus.Installed -and -not $installStatus.NeedsImport) {
            $uninstallOption.Disabled = $true
            $uninstallOption.Description = "Nothing to uninstall"
        }
        $menuOptions += $uninstallOption
        
        # Exit option
        $menuOptions += @{ 
            Text        = "Exit"
            Description = ""
            Action      = "Exit"
        }
        
        $selection = Show-SelectMenu -Title "Main Menu" -Options $menuOptions -ShowBanner -Footer "Select an option to continue"
        
        switch ($selection.Action) {
            "Launch" {
                Invoke-LaunchOpenClaw
            }
            "Terminal" {
                Invoke-OpenWSLTerminal
            }
            "Import" {
                Invoke-ImportWSL -WSLPath $installStatus.WSLPath
            }
            "Install" { 
                Invoke-InstallOpenClaw 
            }
            "Settings" { 
                Show-SettingsMenu 
            }
            "Uninstall" {
                Invoke-UninstallOpenClaw
            }
            "Exit" {
                Write-Host ""
                Write-Host "  Goodbye!" -ForegroundColor Cyan
                Write-Host ""
                return 
            }
        }
    }
}

#endregion

# Run main menu
Show-MainMenu
