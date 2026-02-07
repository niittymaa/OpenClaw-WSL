#Requires -Version 5.1
<#
.SYNOPSIS
    User Settings Manager for OpenClaw WSL Automation
.DESCRIPTION
    Manages user-configurable settings with defaults from config/defaults.json
    and user overrides stored in .local/settings.json
#>

# Script-level variables
$Script:SettingsPath = $null
$Script:DefaultsPath = $null
$Script:CachedSettings = $null
$Script:CachedDefaults = $null

#region Initialization

function Initialize-SettingsManager {
    <#
    .SYNOPSIS
        Initialize the settings manager with paths
    .PARAMETER RepoRoot
        Root directory of the OpenClaw-WSL repository
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )
    
    $Script:SettingsPath = Join-Path $RepoRoot ".local\settings.json"
    $Script:DefaultsPath = Join-Path $RepoRoot "config\defaults.json"
    $Script:CachedSettings = $null
    $Script:CachedDefaults = $null
    
    # Ensure .local directory exists
    $localDir = Join-Path $RepoRoot ".local"
    if (-not (Test-Path $localDir)) {
        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
    }
}

function Get-SettingsFilePath {
    <#
    .SYNOPSIS
        Returns the path to the user settings file
    #>
    [CmdletBinding()]
    param()
    
    return $Script:SettingsPath
}

#endregion

#region Internal Helpers

function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Converts a PSCustomObject to a hashtable (PowerShell 5.1 compatible)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )
    
    if ($null -eq $InputObject) {
        return @{}
    }
    
    if ($InputObject -is [hashtable]) {
        return $InputObject
    }
    
    $hash = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [PSCustomObject]) {
            $hash[$property.Name] = ConvertTo-Hashtable -InputObject $value
        }
        else {
            $hash[$property.Name] = $value
        }
    }
    return $hash
}

function Get-DefaultSettings {
    <#
    .SYNOPSIS
        Load default settings from config/defaults.json
    #>
    [CmdletBinding()]
    param()
    
    if ($Script:CachedDefaults) {
        return $Script:CachedDefaults
    }
    
    if (-not $Script:DefaultsPath -or -not (Test-Path $Script:DefaultsPath)) {
        # Return built-in defaults if file not found
        return @{
            launcher = @{
                autoOpenBrowser = $true
                browserCommand  = $null
            }
        }
    }
    
    try {
        $content = Get-Content $Script:DefaultsPath -Raw | ConvertFrom-Json
        $Script:CachedDefaults = $content
        return $content
    }
    catch {
        Write-Warning "Failed to load defaults: $($_.Exception.Message)"
        return @{
            launcher = @{
                autoOpenBrowser = $true
                browserCommand  = $null
            }
        }
    }
}

function Get-UserSettings {
    <#
    .SYNOPSIS
        Load user settings from .local/settings.json
    #>
    [CmdletBinding()]
    param(
        [switch]$NoCache
    )
    
    if ($Script:CachedSettings -and -not $NoCache) {
        return $Script:CachedSettings
    }
    
    if (-not $Script:SettingsPath -or -not (Test-Path $Script:SettingsPath)) {
        return @{}
    }
    
    try {
        $content = Get-Content $Script:SettingsPath -Raw | ConvertFrom-Json
        # Convert PSCustomObject to hashtable (PowerShell 5.1 compatible)
        $Script:CachedSettings = ConvertTo-Hashtable -InputObject $content
        return $Script:CachedSettings
    }
    catch {
        Write-Warning "Failed to load user settings: $($_.Exception.Message)"
        return @{}
    }
}

function Save-UserSettings {
    <#
    .SYNOPSIS
        Save user settings to .local/settings.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )
    
    if (-not $Script:SettingsPath) {
        throw "SettingsManager not initialized. Call Initialize-SettingsManager first."
    }
    
    # Ensure directory exists
    $dir = Split-Path $Script:SettingsPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    
    $Settings | ConvertTo-Json -Depth 10 | Set-Content $Script:SettingsPath -Encoding UTF8
    $Script:CachedSettings = $Settings
}

function Get-NestedValue {
    <#
    .SYNOPSIS
        Get a value from a nested hashtable/object using dot notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        $Object
    )
    
    if ($null -eq $Object) {
        return $null
    }
    
    $parts = $Path -split '\.'
    $current = $Object
    
    foreach ($part in $parts) {
        if ($null -eq $current) {
            return $null
        }
        
        if ($current -is [hashtable]) {
            if ($current.ContainsKey($part)) {
                $current = $current[$part]
            }
            else {
                return $null
            }
        }
        elseif ($current.PSObject.Properties[$part]) {
            $current = $current.$part
        }
        else {
            return $null
        }
    }
    
    return $current
}

function Set-NestedValue {
    <#
    .SYNOPSIS
        Set a value in a nested hashtable using dot notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        [hashtable]$Object,
        
        [Parameter()]
        $Value
    )
    
    $parts = $Path -split '\.'
    $current = $Object
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        
        if (-not $current.ContainsKey($part)) {
            $current[$part] = @{}
        }
        elseif ($current[$part] -isnot [hashtable]) {
            $current[$part] = @{}
        }
        
        $current = $current[$part]
    }
    
    $current[$parts[-1]] = $Value
}

function Remove-NestedValue {
    <#
    .SYNOPSIS
        Remove a value from a nested hashtable using dot notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        [hashtable]$Object
    )
    
    $parts = $Path -split '\.'
    $current = $Object
    
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        
        if (-not $current.ContainsKey($part) -or $current[$part] -isnot [hashtable]) {
            return  # Path doesn't exist
        }
        
        $current = $current[$part]
    }
    
    $current.Remove($parts[-1])
    
    # Clean up empty parent hashtables
    CleanupEmptyParents -Object $Object -Path $Path
}

function CleanupEmptyParents {
    <#
    .SYNOPSIS
        Remove empty parent hashtables after removing a nested value
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Object,
        
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $parts = $Path -split '\.'
    
    # Check from innermost to outermost
    for ($depth = $parts.Count - 2; $depth -ge 0; $depth--) {
        $parentPath = ($parts[0..$depth]) -join '.'
        $parentValue = Get-NestedValue -Path $parentPath -Object $Object
        
        if ($parentValue -is [hashtable] -and $parentValue.Count -eq 0) {
            # Remove empty parent
            if ($depth -eq 0) {
                $Object.Remove($parts[0])
            }
            else {
                $grandparentPath = ($parts[0..($depth - 1)]) -join '.'
                $grandparent = Get-NestedValue -Path $grandparentPath -Object $Object
                if ($grandparent -is [hashtable]) {
                    $grandparent.Remove($parts[$depth])
                }
            }
        }
        else {
            break  # Stop if parent is not empty
        }
    }
}

#endregion

#region Public API

function Get-UserSetting {
    <#
    .SYNOPSIS
        Get a setting value (user override takes precedence over default)
    .PARAMETER Name
        Setting name in dot notation (e.g., "launcher.autoOpenBrowser")
    .EXAMPLE
        Get-UserSetting -Name "launcher.autoOpenBrowser"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    # Try user settings first
    $userSettings = Get-UserSettings
    $userValue = Get-NestedValue -Path $Name -Object $userSettings
    
    if ($null -ne $userValue) {
        return $userValue
    }
    
    # Fall back to defaults
    $defaults = Get-DefaultSettings
    return Get-NestedValue -Path $Name -Object $defaults
}

function Set-UserSetting {
    <#
    .SYNOPSIS
        Set a user setting (overrides default)
    .PARAMETER Name
        Setting name in dot notation (e.g., "launcher.autoOpenBrowser")
    .PARAMETER Value
        Value to set
    .EXAMPLE
        Set-UserSetting -Name "launcher.autoOpenBrowser" -Value $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        $Value
    )
    
    $settings = Get-UserSettings -NoCache
    if (-not $settings) {
        $settings = @{}
    }
    
    Set-NestedValue -Path $Name -Object $settings -Value $Value
    Save-UserSettings -Settings $settings
}

function Reset-UserSetting {
    <#
    .SYNOPSIS
        Remove a user setting override (reverts to default)
    .PARAMETER Name
        Setting name in dot notation (e.g., "launcher.autoOpenBrowser")
    .EXAMPLE
        Reset-UserSetting -Name "launcher.autoOpenBrowser"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $settings = Get-UserSettings -NoCache
    if (-not $settings -or $settings.Count -eq 0) {
        return  # Nothing to reset
    }
    
    Remove-NestedValue -Path $Name -Object $settings
    Save-UserSettings -Settings $settings
}

function Get-AllSettings {
    <#
    .SYNOPSIS
        Get all settings (merged: user overrides + defaults)
    .OUTPUTS
        Hashtable with all settings
    #>
    [CmdletBinding()]
    param()
    
    $defaults = Get-DefaultSettings
    $userSettings = Get-UserSettings
    
    # Deep merge user settings over defaults
    $result = @{}
    
    # Copy defaults
    if ($defaults -is [hashtable]) {
        $result = $defaults.Clone()
    }
    else {
        # Convert PSCustomObject to hashtable
        $defaults.PSObject.Properties | ForEach-Object {
            $result[$_.Name] = $_.Value
        }
    }
    
    # Merge user settings
    if ($userSettings -and $userSettings.Count -gt 0) {
        Merge-Hashtable -Target $result -Source $userSettings
    }
    
    return $result
}

function Merge-Hashtable {
    <#
    .SYNOPSIS
        Deep merge source hashtable into target
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Target,
        
        [Parameter(Mandatory)]
        [hashtable]$Source
    )
    
    foreach ($key in $Source.Keys) {
        if ($Target.ContainsKey($key) -and $Target[$key] -is [hashtable] -and $Source[$key] -is [hashtable]) {
            Merge-Hashtable -Target $Target[$key] -Source $Source[$key]
        }
        else {
            $Target[$key] = $Source[$key]
        }
    }
}

function Get-SettingDefault {
    <#
    .SYNOPSIS
        Get the default value for a setting (ignoring user overrides)
    .PARAMETER Name
        Setting name in dot notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $defaults = Get-DefaultSettings
    return Get-NestedValue -Path $Name -Object $defaults
}

function Test-SettingOverridden {
    <#
    .SYNOPSIS
        Check if a setting has a user override
    .PARAMETER Name
        Setting name in dot notation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $userSettings = Get-UserSettings
    $value = Get-NestedValue -Path $Name -Object $userSettings
    return $null -ne $value
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Initialization
    'Initialize-SettingsManager',
    'Get-SettingsFilePath',
    
    # Core API
    'Get-UserSetting',
    'Set-UserSetting',
    'Reset-UserSetting',
    'Get-AllSettings',
    
    # Utilities
    'Get-SettingDefault',
    'Test-SettingOverridden'
)
