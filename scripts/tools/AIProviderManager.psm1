#Requires -Version 5.1
<#
.SYNOPSIS
    Ollama Provider Manager Module for OpenClaw
.DESCRIPTION
    Manages Ollama integration for OpenClaw in WSL.
    Handles enabling/disabling Ollama as an AI provider.
.NOTES
    Dependencies: WSLManager.psm1 must be imported for Invoke-WSLCommand functions.
    
    For other AI providers (Claude, GPT, etc.), configure them directly
    in the OpenClaw terminal using 'openclaw setup'.
#>

# Import Core.psm1 for Write-LogMessage
$scriptRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$coreModule = Join-Path $scriptRoot "modules\Core.psm1"
if (Test-Path $coreModule) {
    Import-Module $coreModule -Force -Global -ErrorAction SilentlyContinue
}

# Safe logging wrapper - logs if Write-LogMessage is available, otherwise silent
function Write-AIProviderLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Info'
    )
    if (Get-Command Write-LogMessage -ErrorAction SilentlyContinue) {
        Write-LogMessage -Message $Message -Level $Level
    }
}

#region Ollama Toggle

function Get-OllamaProviderStatus {
    <#
    .SYNOPSIS
        Check if Ollama is enabled as a provider in OpenClaw
    .DESCRIPTION
        Checks for active (uncommented) OLLAMA_API_KEY export in bashrc.
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
    
    # Check if OLLAMA_API_KEY is actively exported in bashrc (not commented out)
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        return @{
            Enabled = $false
            CurrentModelIsOllama = $false
            Message = "Could not determine user home"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    # Only match lines that START with 'export OLLAMA_API_KEY' (not commented)
    $checkCmd = "grep -q '^export OLLAMA_API_KEY' '$bashrcPath' && echo 'yes' || echo 'no'"
    $output = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    
    $apiKeySet = $false
    if ($output) {
        $outputStr = if ($output -is [array]) { $output[0] } else { $output }
        $apiKeySet = ($outputStr.ToString().Trim() -eq "yes")
    }
    
    # Check current model using function from OllamaManager
    $currentModel = $null
    if (Get-Command Get-OpenClawCurrentModel -ErrorAction SilentlyContinue) {
        $currentModel = Get-OpenClawCurrentModel -DistroName $DistroName -Username $Username
    }
    $isOllamaModel = $currentModel -and $currentModel -match "^ollama/"
    
    return @{
        Enabled              = $apiKeySet
        CurrentModelIsOllama = $isOllamaModel
        CurrentModel         = $currentModel
    }
}

function Enable-OllamaProvider {
    <#
    .SYNOPSIS
        Enable Ollama as an AI provider
    .DESCRIPTION
        Sets OLLAMA_API_KEY in bashrc to enable Ollama auto-discovery.
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
    
    # Use existing function from OllamaManager if available
    if (Get-Command Set-OpenClawOllamaApiKey -ErrorAction SilentlyContinue) {
        $result = Set-OpenClawOllamaApiKey -DistroName $DistroName -Username $Username
        if ($result.Success) {
            Write-AIProviderLog "Ollama provider enabled for user $Username" -Level Info
        }
        return $result
    }
    
    # Fallback implementation
    $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
    if (-not $userHome) {
        Write-AIProviderLog "Enable-OllamaProvider: Could not determine user home for $Username" -Level Error
        return @{
            Success = $false
            Message = "Could not determine user home"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    $exportLine = "export OLLAMA_API_KEY='ollama-local'"
    
    # Check if already actively set (not commented)
    $checkCmd = "grep -q '^export OLLAMA_API_KEY' '$bashrcPath' && echo 'yes' || echo 'no'"
    $output = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    $exists = if ($output -is [array]) { $output[0] } else { $output }
    
    if ($exists.ToString().Trim() -ne "yes") {
        $addCmd = "echo '' >> '$bashrcPath' && echo '# Ollama API key for OpenClaw' >> '$bashrcPath' && echo `"$exportLine`" >> '$bashrcPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $addCmd -User $Username -Silent | Out-Null
    }
    
    Write-AIProviderLog "Ollama provider enabled for user $Username" -Level Info
    
    return @{
        Success = $true
        Message = "Ollama provider enabled"
    }
}

function Disable-OllamaProvider {
    <#
    .SYNOPSIS
        Disable Ollama as an AI provider
    .DESCRIPTION
        Removes the OLLAMA_API_KEY export from bashrc.
        Does NOT change the current model - user should switch to another provider first.
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
        Write-AIProviderLog "Disable-OllamaProvider: Could not determine user home for $Username" -Level Error
        return @{
            Success = $false
            Message = "Could not determine user home"
        }
    }
    
    $bashrcPath = "$userHome/.bashrc"
    
    # Remove lines that export OLLAMA_API_KEY (and the comment line before it if present)
    $sedCmd = "sed -i '/^# Ollama API key for OpenClaw/d; /^export OLLAMA_API_KEY/d; /^# DISABLED: export OLLAMA_API_KEY/d' '$bashrcPath'"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $sedCmd -User $Username -PassThru -Silent
    
    if ($result.ExitCode -ne 0) {
        Write-AIProviderLog "Disable-OllamaProvider: sed command failed with exit code $($result.ExitCode)" -Level Error
        return @{
            Success = $false
            Message = "Failed to update bashrc"
        }
    }
    
    Write-AIProviderLog "Ollama provider disabled for user $Username" -Level Info
    
    return @{
        Success = $true
        Message = "Ollama provider disabled. Switch to another model if currently using Ollama."
    }
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Ollama Provider Management
    "Get-OllamaProviderStatus",
    "Enable-OllamaProvider",
    "Disable-OllamaProvider"
)
