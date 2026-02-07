#Requires -Version 5.1
<#
.SYNOPSIS
    Ollama Manager Module for OpenClaw
.DESCRIPTION
    Handles Ollama detection, installation guidance, and configuration
.NOTES
    Dependencies: WSLManager.psm1, LinuxConfig.psm1 must be imported before this module
    for WSL integration functions to work (Invoke-WSLCommand, Get-LinuxUserHome, etc.)
#>

$script:OllamaDownloadUrl = "https://ollama.com/download"

#region Ollama Detection

function Test-OllamaInstalled {
    [CmdletBinding()]
    param()
    
    try {
        $result = & ollama --version 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Get-OllamaVersion {
    [CmdletBinding()]
    param()
    
    try {
        $output = & ollama --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Output format: "ollama version X.X.X"
            if ($output -match 'version\s+([\d\.]+)') {
                return $Matches[1]
            }
            return $output.ToString().Trim()
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-OllamaRunning {
    [CmdletBinding()]
    param()
    
    try {
        # Use 127.0.0.1 explicitly and longer timeout (Ollama may need time to respond, especially with GPU init)
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 10 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-OllamaModels {
    [CmdletBinding()]
    param()
    
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 10 -ErrorAction Stop
        return $response.models
    }
    catch {
        return @()
    }
}

#endregion

#region Ollama Operations

function Start-Ollama {
    [CmdletBinding()]
    param()
    
    if (Test-OllamaRunning) {
        return @{
            Success = $true
            Message = "Ollama is already running"
            AlreadyRunning = $true
        }
    }
    
    try {
        # Start ollama serve in background
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        
        # Wait for it to start (max 10 seconds)
        $timeout = 10
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
            if (Test-OllamaRunning) {
                return @{
                    Success = $true
                    Message = "Ollama started successfully"
                    AlreadyRunning = $false
                }
            }
        }
        
        return @{
            Success = $false
            Message = "Ollama started but not responding"
            AlreadyRunning = $false
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Failed to start Ollama: $_"
            AlreadyRunning = $false
        }
    }
}

function Stop-OllamaServer {
    [CmdletBinding()]
    param()
    
    try {
        $processes = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
        if ($processes) {
            $processes | ForEach-Object { Stop-Process -Id $_.Id -Force }
            return @{ Success = $true; Message = "Ollama stopped" }
        }
        return @{ Success = $true; Message = "Ollama was not running" }
    }
    catch {
        return @{ Success = $false; Message = "Failed to stop Ollama: $_" }
    }
}

#endregion

#region WSL Integration

function Test-WSLMirroredNetworking {
    <#
    .SYNOPSIS
        Check if WSL is configured with mirrored networking
    .DESCRIPTION
        Mirrored networking allows WSL to use localhost to reach Windows services.
        This is the recommended way to connect WSL to Ollama on Windows.
    #>
    [CmdletBinding()]
    param()
    
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    
    if (-not (Test-Path $wslConfigPath)) {
        return @{ Enabled = $false; ConfigExists = $false }
    }
    
    $content = Get-Content $wslConfigPath -Raw
    $hasMirrored = $content -match 'networkingMode\s*=\s*mirrored'
    
    return @{ Enabled = $hasMirrored; ConfigExists = $true }
}

function Enable-WSLMirroredNetworking {
    <#
    .SYNOPSIS
        Enable mirrored networking in WSL for localhost access to Windows services
    .DESCRIPTION
        Creates or updates .wslconfig to enable mirrored networking.
        This allows WSL to use localhost:11434 to reach Ollama on Windows.
        Requires WSL restart to take effect.
    #>
    [CmdletBinding()]
    param()
    
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    
    try {
        if (Test-Path $wslConfigPath) {
            $content = Get-Content $wslConfigPath -Raw
            
            if ($content -match 'networkingMode\s*=\s*mirrored') {
                return @{
                    Success = $true
                    Message = "Mirrored networking already enabled"
                    NeedsRestart = $false
                }
            }
            
            # Add or update networkingMode
            if ($content -match '\[wsl2\]') {
                # Add under existing [wsl2] section
                $content = $content -replace '(\[wsl2\])', "`$1`nnetworkingMode=mirrored"
            } else {
                # Add new [wsl2] section
                $content = "[wsl2]`nnetworkingMode=mirrored`n`n" + $content
            }
            
            Set-Content -Path $wslConfigPath -Value $content -Encoding UTF8
        } else {
            # Create new config file
            $config = @"
[wsl2]
networkingMode=mirrored
"@
            Set-Content -Path $wslConfigPath -Value $config -Encoding UTF8
        }
        
        return @{
            Success = $true
            Message = "Mirrored networking enabled in .wslconfig"
            NeedsRestart = $true
            ConfigPath = $wslConfigPath
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Failed to update .wslconfig: $_"
        }
    }
}

function Test-OllamaFromWSL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # First try localhost (works with mirrored networking - preferred)
    $cmd = "curl -s --connect-timeout 3 http://localhost:11434/api/tags"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -PassThru -Silent
    
    if ($result.ExitCode -eq 0) {
        $outputStr = if ($result.Output) { [string]($result.Output -join "`n") } else { "" }
        if ($outputStr -match '"models"') {
            return $true
        }
    }
    
    # Fallback: try host IP (for non-mirrored setups)
    $hostIP = Get-WindowsHostIP -DistroName $DistroName
    if ($hostIP) {
        $cmd = "curl -s --connect-timeout 3 http://${hostIP}:11434/api/tags"
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -PassThru -Silent
        
        if ($result.ExitCode -eq 0) {
            $outputStr = if ($result.Output) { [string]($result.Output -join "`n") } else { "" }
            return $outputStr -match '"models"'
        }
    }
    
    return $false
}

function Get-WindowsHostIP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # Use cut instead of awk to avoid quoting issues
    $cmd = "grep nameserver /etc/resolv.conf | cut -d' ' -f2"
    $output = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd
    
    # Handle null or empty output
    if (-not $output) {
        Write-Warning "Could not get Windows host IP from WSL"
        return $null
    }
    
    # Handle array output (multiple lines)
    if ($output -is [array]) {
        $output = $output[0]
    }
    
    # Ensure it's a string before calling Trim()
    return [string]$output.ToString().Trim()
}

function Set-OllamaConfigInWSL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$OllamaHost
    )
    
    # With mirrored networking, use localhost; otherwise use host IP
    if (-not $OllamaHost) {
        $mirroredStatus = Test-WSLMirroredNetworking
        if ($mirroredStatus.Enabled) {
            $OllamaHost = "http://localhost:11434"
        } else {
            $hostIP = Get-WindowsHostIP -DistroName $DistroName
            if (-not $hostIP) {
                return @{
                    Success = $false
                    Message = "Could not determine Windows host IP from WSL"
                }
            }
            $OllamaHost = "http://${hostIP}:11434"
        }
    }
    
    # Get user home
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return @{
            Success = $false
            Message = "Could not determine Linux user home directory"
        }
    }
    
    # Add OLLAMA_HOST to bashrc if not already present
    $bashrcPath = "$userHome/.bashrc"
    $exportLine = "export OLLAMA_HOST='$OllamaHost'"
    
    # Check if already configured (safe output handling)
    $checkCmd = "grep -q 'OLLAMA_HOST' '$bashrcPath' && echo 'yes' || echo 'no'"
    $existsOutput = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    $exists = if ($existsOutput) {
        if ($existsOutput -is [array]) { $existsOutput[0] } else { $existsOutput }
    } else { 
        'no' 
    }
    $exists = [string]$exists.ToString().Trim()
    
    if ($exists -eq 'yes') {
        # Update existing
        $updateCmd = "sed -i 's|export OLLAMA_HOST=.*|$exportLine|' '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $updateCmd -User $Username -Silent | Out-Null
    } else {
        # Add new
        $addCmd = "echo '' >> '$bashrcPath' && echo '# Ollama configuration' >> '$bashrcPath' && echo '$exportLine' >> '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $addCmd -User $Username -Silent | Out-Null
    }
    
    return @{
        Success = $true
        OllamaHost = $OllamaHost
        ConfigFile = $bashrcPath
    }
}

function Set-OllamaModelInWSL {
    <#
    .SYNOPSIS
        Set the OLLAMA_MODEL environment variable in WSL user's .bashrc
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Username
        Linux username
    .PARAMETER ModelName
        Ollama model name to set (e.g., "llama3.2", "mistral")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter(Mandatory)]
        [string]$ModelName
    )
    
    # Get user home
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return @{
            Success = $false
            Message = "Could not determine Linux user home directory"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    $exportLine = "export OLLAMA_MODEL='$ModelName'"
    
    # Check if OLLAMA_MODEL already configured (safe output handling)
    $checkCmd = "grep -q 'OLLAMA_MODEL' '$bashrcPath' && echo 'yes' || echo 'no'"
    $existsOutput = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    $exists = if ($existsOutput) { 
        if ($existsOutput -is [array]) { $existsOutput[0] } else { $existsOutput }
    } else { 
        'no' 
    }
    $exists = [string]$exists.ToString().Trim()
    
    if ($exists -eq 'yes') {
        # Update existing
        $updateCmd = "sed -i 's|export OLLAMA_MODEL=.*|$exportLine|' '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $updateCmd -User $Username -Silent | Out-Null
    } else {
        # Add new (after OLLAMA_HOST if it exists, otherwise at end)
        $addCmd = "echo '$exportLine' >> '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $addCmd -User $Username -Silent | Out-Null
    }
    
    return @{
        Success = $true
        ModelName = $ModelName
        ConfigFile = $bashrcPath
    }
}

function Get-CurrentOllamaModelInWSL {
    <#
    .SYNOPSIS
        Get the currently configured OLLAMA_MODEL from WSL user's .bashrc
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Username
        Linux username
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return $null
    }
    
    $bashrcPath = "$userHome/.bashrc"
    
    # Extract OLLAMA_MODEL value from bashrc using grep and cut
    $cmd = "grep 'export OLLAMA_MODEL=' '$bashrcPath' 2>/dev/null | cut -d= -f2 | tr -d ""'"""
    $output = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $Username
    
    if (-not $output) {
        return $null
    }
    
    # Handle array output
    if ($output -is [array]) {
        $output = $output[0]
    }
    
    $model = [string]$output.ToString().Trim()
    if ($model -and $model -ne "") {
        return $model
    }
    
    return $null
}

function Remove-OllamaModelInWSL {
    <#
    .SYNOPSIS
        Remove the OLLAMA_MODEL environment variable from WSL user's .bashrc
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Username
        Linux username
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return @{
            Success = $false
            Message = "Could not determine Linux user home directory"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    
    # Remove OLLAMA_MODEL line from bashrc
    $cmd = "sed -i '/export OLLAMA_MODEL=/d' '$bashrcPath'"
    Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $Username -Silent | Out-Null
    
    return @{
        Success = $true
        ConfigFile = $bashrcPath
    }
}

#endregion

#region OpenClaw Model Configuration

function Set-OpenClawOllamaModel {
    <#
    .SYNOPSIS
        Configure OpenClaw to use an Ollama model as the primary AI provider
    .DESCRIPTION
        Uses the OpenClaw CLI to set the model. This properly configures
        OpenClaw's config file (~/.openclaw/openclaw.json) to use Ollama.
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Username
        Linux username  
    .PARAMETER ModelName
        Ollama model name (e.g., "llama3.1:8b")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter(Mandatory)]
        [string]$ModelName
    )
    
    # First ensure OLLAMA_API_KEY is set (required for OpenClaw to detect Ollama)
    $apiKeyResult = Set-OpenClawOllamaApiKey -DistroName $DistroName -Username $Username
    if (-not $apiKeyResult.Success) {
        return $apiKeyResult
    }
    
    # Format the model reference for OpenClaw (ollama/modelname)
    $ollamaModelRef = "ollama/$ModelName"
    
    # Use OpenClaw CLI to set the model (LoginShell required for PATH)
    $cmd = "openclaw models set '$ollamaModelRef'"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $Username -PassThru -Silent -LoginShell
    
    if ($result.ExitCode -ne 0) {
        # Try alternative: use config set command
        $configCmd = "openclaw config set agents.defaults.model.primary '$ollamaModelRef'"
        $configResult = Invoke-WSLCommand -DistroName $DistroName -Command $configCmd -User $Username -PassThru -Silent -LoginShell
        
        if ($configResult.ExitCode -ne 0) {
            return @{
                Success = $false
                Message = "Failed to set OpenClaw model. Run 'openclaw onboard' first."
                Output = $result.Output
            }
        }
    }
    
    return @{
        Success = $true
        ModelRef = $ollamaModelRef
        Message = "OpenClaw configured to use $ollamaModelRef"
    }
}

function Set-OpenClawOllamaApiKey {
    <#
    .SYNOPSIS
        Set the OLLAMA_API_KEY environment variable for OpenClaw
    .DESCRIPTION
        OpenClaw requires OLLAMA_API_KEY to be set to enable Ollama auto-discovery.
        Any non-empty value works since Ollama doesn't require authentication.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return @{
            Success = $false
            Message = "Could not determine Linux user home directory"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    $exportLine = "export OLLAMA_API_KEY='ollama-local'"
    
    # Check if already actively configured (not commented out)
    $checkCmd = "grep -q '^export OLLAMA_API_KEY' '$bashrcPath' && echo 'yes' || echo 'no'"
    $existsOutput = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    $exists = if ($existsOutput) { 
        if ($existsOutput -is [array]) { $existsOutput[0] } else { $existsOutput }
    } else { 
        'no' 
    }
    $exists = [string]$exists.ToString().Trim()
    
    if ($exists -ne 'yes') {
        # First remove any commented/disabled OLLAMA_API_KEY lines
        $cleanupCmd = "sed -i '/DISABLED.*OLLAMA_API_KEY/d' '$bashrcPath'; sed -i '/^#.*OLLAMA_API_KEY/d' '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $cleanupCmd -User $Username -Silent | Out-Null
        
        # Add OLLAMA_API_KEY to bashrc
        $addCmd = "echo '' >> '$bashrcPath' && echo '# Ollama API key for OpenClaw' >> '$bashrcPath' && echo '$exportLine' >> '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $addCmd -User $Username -Silent | Out-Null
    }
    
    return @{
        Success = $true
        ConfigFile = $bashrcPath
    }
}

function Get-OpenClawCurrentModel {
    <#
    .SYNOPSIS
        Get the currently configured model in OpenClaw
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    # Use openclaw config get to retrieve the current model (LoginShell for PATH)
    $cmd = "openclaw config get agents.defaults.model.primary 2>/dev/null || echo ''"
    $output = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $Username -LoginShell
    
    if (-not $output) {
        return $null
    }
    
    if ($output -is [array]) {
        $output = $output[0]
    }
    
    $model = [string]$output.ToString().Trim()
    if ($model -and $model -ne "" -and $model -ne "null" -and $model -ne "undefined") {
        return $model
    }
    
    return $null
}

function Test-OpenClawOllamaConfigured {
    <#
    .SYNOPSIS
        Check if OpenClaw is configured to use Ollama
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $currentModel = Get-OpenClawCurrentModel -DistroName $DistroName -Username $Username
    
    if ($currentModel -and $currentModel -match '^ollama/') {
        return @{
            Configured = $true
            Model = $currentModel
        }
    }
    
    return @{
        Configured = $false
        Model = $currentModel
    }
}

#endregion

#region User Interface

function Show-OllamaNotInstalled {
    [CmdletBinding()]
    param()
    
    Write-Host ""
    Write-Host "  +-- Ollama Not Found ----------------------------------------" -ForegroundColor Yellow
    Write-Host "  |" -ForegroundColor Yellow
    Write-Host "  |  Ollama is not installed on this system." -ForegroundColor Yellow
    Write-Host "  |" -ForegroundColor Yellow
    Write-Host "  |  Please install Ollama first:" -ForegroundColor Yellow
    Write-Host "  |" -ForegroundColor Yellow
    Write-Host "  |    $script:OllamaDownloadUrl" -ForegroundColor Cyan
    Write-Host "  |" -ForegroundColor Yellow
    Write-Host "  |  After installation, restart this menu and try again." -ForegroundColor Yellow
    Write-Host "  |" -ForegroundColor Yellow
    Write-Host "  +------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
}

function Show-OllamaStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName,
        
        [Parameter()]
        [string]$Username
    )
    
    $installed = Test-OllamaInstalled
    $running = if ($installed) { Test-OllamaRunning } else { $false }
    $version = if ($installed) { Get-OllamaVersion } else { "N/A" }
    $models = if ($running) { Get-OllamaModels } else { @() }
    $currentModel = $null
    
    # Get current model selection from WSL if distro info provided
    if ($DistroName -and $Username) {
        $currentModel = Get-CurrentOllamaModelInWSL -DistroName $DistroName -Username $Username
    }
    
    Write-Host ""
    Write-Host "  +-- Ollama Status -------------------------------------------" -ForegroundColor Cyan
    Write-Host "  |" -ForegroundColor Cyan
    
    $installedStatus = if ($installed) { "[OK] Installed" } else { "[X] Not installed" }
    $installedColor = if ($installed) { "Green" } else { "Red" }
    Write-Host "  |  Installation: " -ForegroundColor Cyan -NoNewline
    Write-Host $installedStatus -ForegroundColor $installedColor
    
    if ($installed) {
        Write-Host "  |  Version: $version" -ForegroundColor Cyan
        
        $runningStatus = if ($running) { "[OK] Running" } else { "[X] Not running" }
        $runningColor = if ($running) { "Green" } else { "Yellow" }
        Write-Host "  |  Status: " -ForegroundColor Cyan -NoNewline
        Write-Host $runningStatus -ForegroundColor $runningColor
        
        if ($running -and $models.Count -gt 0) {
            Write-Host "  |  Models: $($models.Count) installed" -ForegroundColor Cyan
            foreach ($model in $models | Select-Object -First 5) {
                Write-Host "  |    - $($model.name)" -ForegroundColor DarkGray
            }
            if ($models.Count -gt 5) {
                Write-Host "  |    ... and $($models.Count - 5) more" -ForegroundColor DarkGray
            }
        }
        
        # Show OpenClaw model configuration if distro info provided
        if ($DistroName -and $Username) {
            $openclawStatus = Test-OpenClawOllamaConfigured -DistroName $DistroName -Username $Username
            Write-Host "  |" -ForegroundColor Cyan
            if ($openclawStatus.Configured) {
                Write-Host "  |  OpenClaw Model: " -ForegroundColor Cyan -NoNewline
                Write-Host $openclawStatus.Model -ForegroundColor Green
            } elseif ($openclawStatus.Model) {
                Write-Host "  |  OpenClaw Model: " -ForegroundColor Cyan -NoNewline
                Write-Host "$($openclawStatus.Model) (not Ollama)" -ForegroundColor Yellow
            } else {
                Write-Host "  |  OpenClaw Model: " -ForegroundColor Cyan -NoNewline
                Write-Host "Not configured" -ForegroundColor DarkGray
            }
        }
    }
    
    Write-Host "  |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    
    return @{
        Installed = $installed
        Running = $running
        Version = $version
        Models = $models
    }
}

#region Windows Ollama Configuration

function Get-OllamaHostEnvVar {
    <#
    .SYNOPSIS
        Get the current OLLAMA_HOST environment variable from Windows
    #>
    [CmdletBinding()]
    param()
    
    # Check user environment variable first, then system
    $userValue = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "User")
    $machineValue = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "Machine")
    
    return @{
        User = $userValue
        Machine = $machineValue
        Effective = if ($userValue) { $userValue } elseif ($machineValue) { $machineValue } else { $null }
    }
}

function Test-OllamaNetworkAccessEnabled {
    <#
    .SYNOPSIS
        Check if Ollama is configured to accept connections from WSL
    #>
    [CmdletBinding()]
    param()
    
    $envVar = Get-OllamaHostEnvVar
    $effective = $envVar.Effective
    
    if (-not $effective) {
        return $false
    }
    
    # Check if it's bound to 0.0.0.0 (all interfaces) or a specific non-localhost IP
    return $effective -match '^0\.0\.0\.0:' -or ($effective -match '^\d+\.\d+\.\d+\.\d+:' -and $effective -notmatch '^127\.')
}

function Set-OllamaNetworkAccess {
    <#
    .SYNOPSIS
        Configure Ollama to listen on all interfaces (required for WSL access)
    .DESCRIPTION
        Sets the OLLAMA_HOST environment variable to 0.0.0.0:11434 so WSL can connect.
        Requires the script to be running with admin privileges to set machine-level variable,
        or will fall back to user-level variable.
    .PARAMETER Scope
        "User" or "Machine" - where to set the environment variable
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet("User", "Machine")]
        [string]$Scope = "User"
    )
    
    $targetValue = "0.0.0.0:11434"
    
    try {
        [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $targetValue, $Scope)
        
        # Also set in current process so it takes effect immediately if Ollama is restarted
        $env:OLLAMA_HOST = $targetValue
        
        return @{
            Success = $true
            Scope = $Scope
            Value = $targetValue
            Message = "OLLAMA_HOST set to $targetValue ($Scope scope)"
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Failed to set environment variable: $_"
        }
    }
}

function Restart-OllamaWithNetworkAccess {
    <#
    .SYNOPSIS
        Stop Ollama, ensure network access is configured, and restart it
    #>
    [CmdletBinding()]
    param()
    
    # Stop Ollama if running
    $stopResult = Stop-OllamaServer
    
    # Wait a moment for process to fully terminate
    Start-Sleep -Seconds 2
    
    # Start Ollama (it will pick up the new environment variable)
    $startResult = Start-Ollama
    
    return $startResult
}

#endregion

#region Windows Firewall Configuration

function Test-OllamaFirewallRule {
    <#
    .SYNOPSIS
        Check if a firewall rule exists allowing Ollama port 11434
    #>
    [CmdletBinding()]
    param()
    
    try {
        $rules = Get-NetFirewallRule -DisplayName "*Ollama*" -ErrorAction SilentlyContinue
        if ($rules) {
            foreach ($rule in $rules) {
                $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                if ($portFilter.LocalPort -eq 11434 -and $rule.Direction -eq "Inbound" -and $rule.Action -eq "Allow" -and $rule.Enabled -eq "True") {
                    return @{
                        Exists = $true
                        RuleName = $rule.DisplayName
                        Enabled = $true
                    }
                }
            }
        }
        return @{ Exists = $false; Enabled = $false }
    }
    catch {
        return @{ Exists = $false; Enabled = $false; Error = $_.Exception.Message }
    }
}

function Add-OllamaFirewallRule {
    <#
    .SYNOPSIS
        Create Windows Firewall rule to allow Ollama connections from WSL only
    .DESCRIPTION
        Creates an inbound firewall rule allowing TCP port 11434 for Ollama.
        SECURITY: Rule is restricted to WSL2 virtual network subnets only.
        Requires administrator privileges.
    #>
    [CmdletBinding()]
    param()
    
    $ruleName = "Ollama LLM Server (OpenClaw WSL)"
    
    # WSL2 typically uses these subnets for the virtual network
    # We restrict to these ranges for security (not open to entire LAN)
    $wslSubnets = @(
        "172.16.0.0/12",    # WSL2 commonly uses 172.x.x.x range
        "192.168.0.0/16",   # Some WSL configs use this
        "10.0.0.0/8"        # Fallback for other virtual network configs
    )
    
    try {
        # Check if rule already exists
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existing) {
            # Enable it if disabled
            if ($existing.Enabled -ne "True") {
                Set-NetFirewallRule -DisplayName $ruleName -Enabled True
            }
            return @{
                Success = $true
                Message = "Firewall rule already exists and is enabled"
                RuleName = $ruleName
                Created = $false
            }
        }
        
        # Create new rule with restricted source addresses
        # This limits access to local/virtual networks only, not the internet
        $rule = New-NetFirewallRule `
            -DisplayName $ruleName `
            -Description "Allow Ollama AI server connections from WSL2 virtual network only (OpenClaw)" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 11434 `
            -RemoteAddress $wslSubnets `
            -Action Allow `
            -Profile Private `
            -Enabled True
        
        return @{
            Success = $true
            Message = "Firewall rule created successfully"
            RuleName = $ruleName
            Created = $true
        }
    }
    catch {
        return @{
            Success = $false
            Message = "Failed to create firewall rule: $_"
        }
    }
}

function Remove-OllamaFirewallRule {
    <#
    .SYNOPSIS
        Remove the Ollama firewall rule
    #>
    [CmdletBinding()]
    param()
    
    $ruleName = "Ollama LLM Server (OpenClaw WSL)"
    
    try {
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        return @{ Success = $true; Message = "Firewall rule removed" }
    }
    catch {
        return @{ Success = $false; Message = "Failed to remove firewall rule: $_" }
    }
}

function Set-OllamaFullNetworkAccess {
    <#
    .SYNOPSIS
        Configure both environment variable and firewall for WSL access
    .DESCRIPTION
        Complete setup: sets OLLAMA_HOST=0.0.0.0:11434 and creates firewall rule.
        This is the recommended single function to call for WSL connectivity.
    #>
    [CmdletBinding()]
    param()
    
    $results = @{
        EnvVar = $null
        Firewall = $null
        Success = $false
    }
    
    # Set environment variable
    $results.EnvVar = Set-OllamaNetworkAccess -Scope "User"
    
    # Add firewall rule
    $results.Firewall = Add-OllamaFirewallRule
    
    $results.Success = $results.EnvVar.Success -and $results.Firewall.Success
    
    return $results
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'Test-OllamaInstalled',
    'Get-OllamaVersion',
    'Test-OllamaRunning',
    'Get-OllamaModels',
    'Start-Ollama',
    'Stop-OllamaServer',
    'Test-OllamaFromWSL',
    'Get-WindowsHostIP',
    'Set-OllamaConfigInWSL',
    'Show-OllamaNotInstalled',
    'Show-OllamaStatus',
    # WSL Mirrored Networking (recommended)
    'Test-WSLMirroredNetworking',
    'Enable-WSLMirroredNetworking',
    # OpenClaw model configuration
    'Set-OpenClawOllamaModel',
    'Set-OpenClawOllamaApiKey',
    'Get-OpenClawCurrentModel',
    'Test-OpenClawOllamaConfigured',
    # Legacy network access configuration (fallback)
    'Get-OllamaHostEnvVar',
    'Test-OllamaNetworkAccessEnabled',
    'Set-OllamaNetworkAccess',
    'Restart-OllamaWithNetworkAccess',
    # Firewall configuration (fallback for non-mirrored)
    'Test-OllamaFirewallRule',
    'Add-OllamaFirewallRule',
    'Remove-OllamaFirewallRule',
    'Set-OllamaFullNetworkAccess'
)
