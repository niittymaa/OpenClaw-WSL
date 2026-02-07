#Requires -Version 5.1
<#
.SYNOPSIS
    Core utilities for OpenClaw WSL Automation
.DESCRIPTION
    Provides logging, user prompts, input validation, and admin checks.
    Integrates with Logger module for file-based logging.
#>

# Script-level variables
$Script:LogLevel = "Info"
$Script:UseColors = $true
$Script:FileLoggingEnabled = $false

#region Logging Functions

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes a log message to console and optionally to log file
    .DESCRIPTION
        Dual-output logging function that writes to console with colors
        and to log file via Logger module when enabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("Debug", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        
        [Parameter()]
        [switch]$NoNewline,
        
        [Parameter()]
        [switch]$NoConsole,
        
        [Parameter()]
        [switch]$NoFile
    )
    
    $colors = @{
        Debug   = "Gray"
        Info    = "White"
        Warning = "Yellow"
        Error   = "Red"
        Success = "Green"
    }
    
    $prefixes = @{
        Debug   = "[DEBUG]"
        Info    = "[INFO]"
        Warning = "[WARN]"
        Error   = "[ERROR]"
        Success = "[OK]"
    }
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = $prefixes[$Level]
    $color = $colors[$Level]
    
    # Write to console unless suppressed
    if (-not $NoConsole) {
        $params = @{
            Object = "$timestamp $prefix $Message"
        }
        
        if ($Script:UseColors) {
            $params.ForegroundColor = $color
        }
        
        if ($NoNewline) {
            $params.NoNewline = $true
        }
        
        Write-Host @params
    }
    
    # Write to file if logging is enabled and not suppressed
    if (-not $NoFile -and $Script:FileLoggingEnabled) {
        try {
            # Use Logger module's Write-Log function if available
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message $Message -Level $Level
            }
        }
        catch {
            # Silently fail file logging to not interrupt console output
        }
    }
}

function Enable-FileLogging {
    <#
    .SYNOPSIS
        Enables file logging integration with Logger module
    #>
    [CmdletBinding()]
    param()
    
    $Script:FileLoggingEnabled = $true
}

function Disable-FileLogging {
    <#
    .SYNOPSIS
        Disables file logging
    #>
    [CmdletBinding()]
    param()
    
    $Script:FileLoggingEnabled = $false
}

function Test-FileLoggingEnabled {
    <#
    .SYNOPSIS
        Returns whether file logging is enabled
    #>
    [CmdletBinding()]
    param()
    
    return $Script:FileLoggingEnabled
}

function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [int]$Step,
        
        [Parameter()]
        [int]$TotalSteps
    )
    
    $stepInfo = if ($Step -and $TotalSteps) { "[$Step/$TotalSteps] " } else { "" }
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host "  $stepInfo$Message" -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-SubStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )
    
    Write-Host "  -> $Message" -ForegroundColor DarkCyan
}

function Write-Success {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )
    
    Write-LogMessage $Message -Level Success
}

function Write-ErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )
    
    Write-LogMessage $Message -Level Error
}

function Write-WarningMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message
    )
    
    Write-LogMessage $Message -Level Warning
}

#endregion

#region Input Validation Functions

function Read-ValidatedInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter()]
        [string]$Default,
        
        [Parameter()]
        [scriptblock]$Validator,
        
        [Parameter()]
        [string]$ValidationErrorMessage = "Invalid input. Please try again.",
        
        [Parameter()]
        [switch]$Required,
        
        [Parameter()]
        [switch]$Secret
    )
    
    $displayPrompt = $Prompt
    if ($Default) {
        $displayPrompt = "$Prompt [default: $Default]"
    }
    
    while ($true) {
        Write-Host ""
        Write-Host "  $displayPrompt" -ForegroundColor Yellow
        Write-Host "  > " -NoNewline -ForegroundColor Gray
        
        if ($Secret) {
            $secureInput = Read-Host -AsSecureString
            $userInput = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
            )
        } else {
            $userInput = Read-Host
        }
        
        # Trim and sanitize
        $userInput = $userInput.Trim()
        
        # Apply default if empty
        if ([string]::IsNullOrWhiteSpace($userInput) -and $Default) {
            $userInput = $Default
            Write-Host "  Using default: $Default" -ForegroundColor DarkGray
        }
        
        # Check required
        if ($Required -and [string]::IsNullOrWhiteSpace($userInput)) {
            Write-ErrorMessage "This field is required."
            continue
        }
        
        # Allow empty if not required
        if (-not $Required -and [string]::IsNullOrWhiteSpace($userInput)) {
            return $userInput
        }
        
        # Run validator if provided
        if ($Validator) {
            $validationResult = & $Validator $userInput
            if ($validationResult -eq $true) {
                return $userInput
            } else {
                if ($validationResult -is [string]) {
                    Write-ErrorMessage $validationResult
                } else {
                    Write-ErrorMessage $ValidationErrorMessage
                }
                continue
            }
        }
        
        return $userInput
    }
}

function Read-Choice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter(Mandatory)]
        [string[]]$Choices,
        
        [Parameter()]
        [int]$Default = 1,
        
        [Parameter()]
        [string[]]$Descriptions
    )
    
    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Yellow
    Write-Host ""
    
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        $num = $i + 1
        $isDefault = ($num -eq $Default)
        $defaultMarker = if ($isDefault) { " (default)" } else { "" }
        $color = if ($isDefault) { "White" } else { "Gray" }
        
        Write-Host "    $num) $($Choices[$i])$defaultMarker" -ForegroundColor $color
        
        if ($Descriptions -and $Descriptions[$i]) {
            Write-Host "       $($Descriptions[$i])" -ForegroundColor DarkGray
        }
    }
    
    while ($true) {
        Write-Host ""
        Write-Host "  Enter choice (1-$($Choices.Count)) [default: $Default]: " -NoNewline -ForegroundColor Gray
        $userInput = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            return $Default
        }
        
        if ($userInput -match '^\d+$') {
            $choice = [int]$userInput
            if ($choice -ge 1 -and $choice -le $Choices.Count) {
                return $choice
            }
        }
        
        Write-ErrorMessage "Please enter a number between 1 and $($Choices.Count)."
    }
}

function Read-YesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter()]
        [bool]$Default = $true
    )
    
    $defaultStr = if ($Default) { "Y/n" } else { "y/N" }
    
    while ($true) {
        Write-Host ""
        Write-Host "  $Prompt [$defaultStr]: " -NoNewline -ForegroundColor Yellow
        $userInput = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            return $Default
        }
        
        switch ($userInput.ToLower()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default {
                Write-ErrorMessage "Please enter 'y' or 'n'."
            }
        }
    }
}

function Read-SelectFromList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter(Mandatory)]
        [string[]]$Items,
        
        [Parameter()]
        [string]$Default
    )
    
    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Yellow
    Write-Host ""
    
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $num = $i + 1
        $isDefault = ($Items[$i] -eq $Default)
        $defaultMarker = if ($isDefault) { " (default)" } else { "" }
        $color = if ($isDefault) { "White" } else { "Gray" }
        
        Write-Host "    $num) $($Items[$i])$defaultMarker" -ForegroundColor $color
    }
    
    while ($true) {
        Write-Host ""
        $prompt = "  Enter number (1-$($Items.Count))"
        if ($Default) {
            $prompt += " or press Enter for default"
        }
        Write-Host "$prompt`: " -NoNewline -ForegroundColor Gray
        $userInput = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($userInput) -and $Default) {
            return $Default
        }
        
        if ($userInput -match '^\d+$') {
            $choice = [int]$userInput
            if ($choice -ge 1 -and $choice -le $Items.Count) {
                return $Items[$choice - 1]
            }
        }
        
        Write-ErrorMessage "Please enter a valid number."
    }
}

#endregion

#region Validation Helpers

function Test-ValidLinuxUsername {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    # Linux username rules:
    # - Must start with lowercase letter
    # - Can contain lowercase letters, digits, underscores, hyphens
    # - Max 32 characters
    # - No spaces
    
    if ($Username.Length -gt 32) {
        return "Username must be 32 characters or less."
    }
    
    if ($Username -cmatch '[A-Z]') {
        return "Username must be lowercase only."
    }
    
    if ($Username -match '\s') {
        return "Username cannot contain spaces."
    }
    
    if ($Username -notmatch '^[a-z][a-z0-9_-]*$') {
        return "Username must start with a letter and contain only letters, numbers, underscores, and hyphens."
    }
    
    return $true
}

function Test-ValidDistributionName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    if ($Name.Length -gt 64) {
        return "Distribution name must be 64 characters or less."
    }
    
    if ($Name -match '\s') {
        return "Distribution name cannot contain spaces."
    }
    
    if ($Name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') {
        return "Distribution name must start with a letter and contain only letters, numbers, underscores, and hyphens."
    }
    
    return $true
}

#endregion

#region Admin & Prerequisites

function Test-AdminPrivileges {
    [CmdletBinding()]
    param()
    
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-AdminPrivileges {
    [CmdletBinding()]
    param()
    
    if (-not (Test-AdminPrivileges)) {
        Write-ErrorMessage "This script requires Administrator privileges."
        Write-Host ""
        Write-Host "  Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
        Write-Host ""
        $errorMsg = "Insufficient privileges - Administrator rights required"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
}

function Test-WSLAvailable {
    [CmdletBinding()]
    param()
    
    try {
        $null = Get-Command wsl.exe -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Assert-WSLAvailable {
    [CmdletBinding()]
    param()
    
    if (-not (Test-WSLAvailable)) {
        Write-ErrorMessage "WSL is not available on this system."
        Write-Host ""
        Write-Host "  Please enable WSL first:" -ForegroundColor Yellow
        Write-Host "    wsl --install" -ForegroundColor Gray
        Write-Host ""
        $errorMsg = "WSL not available - wsl.exe not found"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
}

#endregion

#region Installation State

function Get-InstallationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    
    $stateFile = Join-Path $InstallPath ".openclaw-install.json"
    
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            return $state
        }
        catch {
            Write-WarningMessage "Could not read installation state file."
            return $null
        }
    }
    
    return $null
}

function Save-InstallationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallPath,
        
        [Parameter(Mandatory)]
        [hashtable]$State
    )
    
    $stateFile = Join-Path $InstallPath ".openclaw-install.json"
    
    $State.LastModified = (Get-Date).ToString("o")
    $State.Version = "1.0"
    
    $State | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
    
    Write-LogMessage "Installation state saved." -Level Debug
}

function Test-ExistingInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    
    $stateFile = Join-Path $InstallPath ".openclaw-install.json"
    return Test-Path $stateFile
}

#endregion

#region Utility Functions

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [int]$MaxRetries = 3,
        
        [Parameter()]
        [int]$DelaySeconds = 2,
        
        [Parameter()]
        [string]$OperationName = "Operation"
    )
    
    $attempt = 0
    $lastError = $null
    
    while ($attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            return & $ScriptBlock
        }
        catch {
            $lastError = $_
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "$OperationName failed (attempt $attempt/$MaxRetries): $($_.Exception.Message)" -Level "Warning"
            }
            if ($attempt -lt $MaxRetries) {
                Write-WarningMessage "$OperationName failed (attempt $attempt/$MaxRetries). Retrying in $DelaySeconds seconds..."
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
    
    Write-ErrorMessage "$OperationName failed after $MaxRetries attempts."
    if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
        Write-ErrorLog -Message "$OperationName failed after $MaxRetries attempts" -ErrorRecord $lastError
    }
    throw $lastError
}

function Format-Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )
    
    $sizes = @("B", "KB", "MB", "GB", "TB")
    $order = 0
    
    while ($Bytes -ge 1024 -and $order -lt $sizes.Count - 1) {
        $order++
        $Bytes = $Bytes / 1024
    }
    
    return "{0:N2} {1}" -f $Bytes, $sizes[$order]
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Logging
    'Write-LogMessage',
    'Write-Step',
    'Write-SubStep',
    'Write-Success',
    'Write-ErrorMessage',
    'Write-WarningMessage',
    'Enable-FileLogging',
    'Disable-FileLogging',
    'Test-FileLoggingEnabled',
    
    # Input
    'Read-ValidatedInput',
    'Read-Choice',
    'Read-YesNo',
    'Read-SelectFromList',
    
    # Validation
    'Test-ValidLinuxUsername',
    'Test-ValidDistributionName',
    
    # Admin & Prerequisites
    'Test-AdminPrivileges',
    'Assert-AdminPrivileges',
    'Test-WSLAvailable',
    'Assert-WSLAvailable',
    
    # Installation State
    'Get-InstallationState',
    'Save-InstallationState',
    'Test-ExistingInstallation',
    
    # Utilities
    'Invoke-WithRetry',
    'Format-Bytes'
)
