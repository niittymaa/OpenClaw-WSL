#Requires -Version 5.1
<#
.SYNOPSIS
    OpenClaw AI Profile Management Module
.DESCRIPTION
    Provides functions to read, display, and switch AI model profiles in OpenClaw.
    Manages both openclaw.json config and auth-profiles.json credentials.
    
    Dependencies: Core.psm1, WSLManager.psm1 (must be imported before this module)
#>

#region Profile Reading Functions

function Get-OpenClawConfig {
    <#
    .SYNOPSIS
        Reads OpenClaw main configuration file
    .DESCRIPTION
        Retrieves openclaw.json from WSL and parses it as JSON
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw"
    )
    
    try {
        $configPath = "~/.openclaw/openclaw.json"
        $jsonContent = & wsl -d $DistroName -u $Username -- cat $configPath 2>$null
        
        if ($LASTEXITCODE -ne 0 -or -not $jsonContent) {
            Write-LogMessage "OpenClaw config not found at $configPath" -Level Warning
            return $null
        }
        
        if ($jsonContent -is [System.Management.Automation.ErrorRecord]) {
            Write-LogMessage "Failed to read OpenClaw config" -Level Error
            return $null
        }
        
        $config = $jsonContent | ConvertFrom-Json
        return $config
    }
    catch {
        Write-LogMessage "Error reading OpenClaw config: $_" -Level Error
        return $null
    }
}

function Get-OpenClawAuthProfiles {
    <#
    .SYNOPSIS
        Reads OpenClaw authentication profiles
    .DESCRIPTION
        Retrieves auth-profiles.json from WSL agent directory
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw",
        
        [Parameter()]
        [string]$AgentName = "main"
    )
    
    try {
        $authPath = "~/.openclaw/agents/$AgentName/agent/auth-profiles.json"
        $jsonContent = & wsl -d $DistroName -u $Username -- cat $authPath 2>$null
        
        if ($LASTEXITCODE -ne 0 -or -not $jsonContent) {
            Write-LogMessage "Auth profiles not found at $authPath" -Level Warning
            return $null
        }
        
        if ($jsonContent -is [System.Management.Automation.ErrorRecord]) {
            Write-LogMessage "Failed to read auth profiles" -Level Error
            return $null
        }
        
        $authProfiles = $jsonContent | ConvertFrom-Json
        return $authProfiles
    }
    catch {
        Write-LogMessage "Error reading auth profiles: $_" -Level Error
        return $null
    }
}

function Get-CurrentProfile {
    <#
    .SYNOPSIS
        Gets the currently active AI profile
    .DESCRIPTION
        Parses the model and checks auth-profiles.json for the active profile
        Returns hashtable with ProfileId, Provider, and Model
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw",
        
        [Parameter()]
        [string]$AgentName = "main"
    )
    
    try {
        $config = Get-OpenClawConfig -DistroName $DistroName -Username $Username
        if (-not $config) {
            return $null
        }
        
        $primaryModel = $config.agents.defaults.model.primary
        if (-not $primaryModel) {
            Write-LogMessage "No primary model configured" -Level Warning
            return $null
        }
        
        # Model format is "provider/model-id" (e.g., "google/gemini-3-flash-preview")
        if ($primaryModel -match '^([^/]+)/(.+)$') {
            $provider = $matches[1]
            $modelId = $matches[2]
        }
        else {
            $provider = "unknown"
            $modelId = $primaryModel
        }
        
        # Get the active profile from auth-profiles.json lastGood setting
        $authProfiles = Get-OpenClawAuthProfiles -DistroName $DistroName -Username $Username -AgentName $AgentName
        $profileId = if ($authProfiles -and $authProfiles.lastGood.$provider) {
            $authProfiles.lastGood.$provider
        } else {
            "$provider:default"
        }
        
        return @{
            ProfileId = $profileId
            Provider = $provider
            Model = $modelId
            FullString = $primaryModel
        }
    }
    catch {
        Write-LogMessage "Error getting current profile: $_" -Level Error
        return $null
    }
}

function Get-ProfileDetails {
    <#
    .SYNOPSIS
        Gets detailed information about a specific profile
    .DESCRIPTION
        Combines config and auth data to provide complete profile information
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileId,
        
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw",
        
        [Parameter()]
        [string]$AgentName = "main"
    )
    
    try {
        $authProfiles = Get-OpenClawAuthProfiles -DistroName $DistroName -Username $Username -AgentName $AgentName
        if (-not $authProfiles) {
            return $null
        }
        
        $profile = $authProfiles.profiles.$ProfileId
        if (-not $profile) {
            Write-LogMessage "Profile '$ProfileId' not found in auth profiles" -Level Warning
            return $null
        }
        
        $keyPreview = "****"
        if ($profile.key) {
            $keyLength = $profile.key.Length
            if ($keyLength -gt 4) {
                $keyPreview = "..." + $profile.key.Substring($keyLength - 4)
            }
        }
        
        $usageStats = $authProfiles.usageStats.$ProfileId
        $lastUsed = if ($usageStats.lastUsed) { 
            [DateTimeOffset]::FromUnixTimeMilliseconds($usageStats.lastUsed).LocalDateTime 
        } else { 
            "Never" 
        }
        $errorCount = if ($usageStats) { $usageStats.errorCount } else { 0 }
        
        return @{
            ProfileId = $ProfileId
            Provider = $profile.provider
            Type = $profile.type
            ApiKeyPreview = $keyPreview
            LastUsed = $lastUsed
            ErrorCount = $errorCount
        }
    }
    catch {
        Write-LogMessage "Error getting profile details for '$ProfileId': $_" -Level Error
        return $null
    }
}

function Get-AllProfiles {
    <#
    .SYNOPSIS
        Gets all available AI profiles with details
    .DESCRIPTION
        Returns array of profile objects with full details and active status
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw",
        
        [Parameter()]
        [string]$AgentName = "main"
    )
    
    try {
        $authProfiles = Get-OpenClawAuthProfiles -DistroName $DistroName -Username $Username -AgentName $AgentName
        if (-not $authProfiles -or -not $authProfiles.profiles) {
            Write-LogMessage "No auth profiles found" -Level Warning
            return @()
        }
        
        $currentProfile = Get-CurrentProfile -DistroName $DistroName -Username $Username -AgentName $AgentName
        $currentProfileId = if ($currentProfile) { $currentProfile.ProfileId } else { $null }
        
        $profiles = @()
        foreach ($profileId in $authProfiles.profiles.PSObject.Properties.Name) {
            $details = Get-ProfileDetails -ProfileId $profileId -DistroName $DistroName -Username $Username -AgentName $AgentName
            if ($details) {
                $details.IsActive = ($profileId -eq $currentProfileId)
                # Show current model for all profiles of the same provider
                if ($currentProfile -and $details.Provider -eq $currentProfile.Provider) {
                    $details.CurrentModel = $currentProfile.Model
                } else {
                    $details.CurrentModel = ""
                }
                $profiles += $details
            }
        }
        
        return $profiles
    }
    catch {
        Write-LogMessage "Error getting all profiles: $_" -Level Error
        return @()
    }
}

#endregion

#region Profile Switching Functions

function Set-OpenClawProfile {
    <#
    .SYNOPSIS
        Switches OpenClaw to use a different AI profile
    .DESCRIPTION
        Updates model and sets the profile as the preferred one for the provider
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileId,
        
        [Parameter(Mandatory)]
        [string]$ModelId,
        
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw",
        
        [Parameter()]
        [string]$AgentName = "main"
    )
    
    try {
        $details = Get-ProfileDetails -ProfileId $ProfileId -DistroName $DistroName -Username $Username -AgentName $AgentName
        if (-not $details) {
            Write-LogMessage "Profile '$ProfileId' does not exist" -Level Error
            return $false
        }
        
        $provider = $details.Provider
        $modelString = "$provider/$ModelId"
        
        Write-LogMessage "Switching to profile: $ProfileId with model: $modelString" -Level Info
        
        # Update the model
        $jqCommand = "jq `".agents.defaults.model.primary = \`"$modelString\`"`" ~/.openclaw/openclaw.json > /tmp/oc.json && mv /tmp/oc.json ~/.openclaw/openclaw.json"
        $result = & wsl -d $DistroName -u $Username -- bash -c $jqCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage "Failed to update model config: $result" -Level Error
            return $false
        }
        
        # Set this profile as the lastGood for the provider in auth-profiles.json
        $authPath = "~/.openclaw/agents/$AgentName/agent/auth-profiles.json"
        $jqAuthCommand = "jq `".lastGood[\`"$provider\`"] = \`"$ProfileId\`"`" $authPath > /tmp/auth.json && mv /tmp/auth.json $authPath"
        $authResult = & wsl -d $DistroName -u $Username -- bash -c $jqAuthCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage "Failed to update auth profile: $authResult" -Level Warning
        }
        
        Write-LogMessage "Profile updated successfully" -Level Success
        
        $gatewayRunning = Test-GatewayRunning -DistroName $DistroName -Username $Username
        if ($gatewayRunning) {
            Write-LogMessage "Gateway is running. Changes will take effect after restart." -Level Info
            return $true
        }
        else {
            Write-LogMessage "Gateway is not running. Start it to use the new profile." -Level Info
            return $true
        }
    }
    catch {
        Write-LogMessage "Error switching profile: $_" -Level Error
        return $false
    }
}

function Test-GatewayRunning {
    <#
    .SYNOPSIS
        Checks if OpenClaw gateway is currently running
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw"
    )
    
    try {
        $processes = & wsl -d $DistroName -u $Username -- bash -c "pgrep -f 'openclaw.*gateway' 2>/dev/null"
        
        if ($LASTEXITCODE -eq 0 -and $processes) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Restart-OpenClawGateway {
    <#
    .SYNOPSIS
        Restarts the OpenClaw gateway
    .DESCRIPTION
        Gracefully stops and starts the gateway service
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw"
    )
    
    try {
        Write-LogMessage "Restarting OpenClaw gateway..." -Level Info
        
        $stopResult = & wsl -d $DistroName -u $Username -- bash -lc "openclaw gateway stop" 2>&1
        Start-Sleep -Seconds 2
        
        $startResult = & wsl -d $DistroName -u $Username -- bash -lc "openclaw gateway start" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage "Gateway restarted successfully" -Level Success
            return $true
        }
        else {
            Write-LogMessage "Gateway restart may have failed: $startResult" -Level Warning
            return $false
        }
    }
    catch {
        Write-LogMessage "Error restarting gateway: $_" -Level Error
        return $false
    }
}

#endregion

#region Display Functions

function Show-ProfileStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DistroName = "openclaw",
        
        [Parameter()]
        [string]$Username = "openclaw"
    )
    
    $currentProfile = Get-CurrentProfile -DistroName $DistroName -Username $Username
    
    if (-not $currentProfile) {
        Write-Host "  +-- Current AI Profile --------" -ForegroundColor Yellow
        Write-Host "  |  No profile configured" -ForegroundColor Gray
        Write-Host "  +-------------------------------" -ForegroundColor Yellow
        return
    }
    
    $details = Get-ProfileDetails -ProfileId $currentProfile.ProfileId -DistroName $DistroName -Username $Username
    
    Write-Host "  +-- Current AI Profile --------" -ForegroundColor Cyan
    Write-Host "  |  Profile: " -ForegroundColor Cyan -NoNewline
    Write-Host $currentProfile.ProfileId -ForegroundColor White
    Write-Host "  |  Provider: " -ForegroundColor Cyan -NoNewline
    Write-Host $currentProfile.Provider.ToUpper() -ForegroundColor White
    Write-Host "  |  Model: " -ForegroundColor Cyan -NoNewline
    Write-Host $currentProfile.Model -ForegroundColor White
    
    if ($details) {
        Write-Host "  |  API Key: " -ForegroundColor Cyan -NoNewline
        Write-Host $details.ApiKeyPreview -ForegroundColor Gray
    }
    
    Write-Host "  +-------------------------------" -ForegroundColor Cyan
}

#endregion

Export-ModuleMember -Function @(
    'Get-OpenClawConfig',
    'Get-OpenClawAuthProfiles',
    'Get-CurrentProfile',
    'Get-ProfileDetails',
    'Get-AllProfiles',
    'Set-OpenClawProfile',
    'Test-GatewayRunning',
    'Restart-OpenClawGateway',
    'Show-ProfileStatus'
)
