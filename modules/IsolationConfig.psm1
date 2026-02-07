#Requires -Version 5.1
<#
.SYNOPSIS
    Filesystem and Network Isolation Configuration for OpenClaw WSL Automation
.DESCRIPTION
    Handles filesystem access modes and network isolation options
.NOTES
    This module depends on: WSLManager.psm1, LinuxConfig.psm1
    These must be imported before this module in the main script.
#>

#region Filesystem Access Modes

<#
Filesystem Access Modes:
1) Full - All Windows drives mounted (/mnt/c, /mnt/d, etc.)
2) Limited - Only OpenClaw data folder mounted
3) Isolated - No Windows filesystem access
#>

function Get-FilesystemModeChoices {
    [CmdletBinding()]
    param()
    
    return @(
        @{
            Id = 1
            Name = "Full Windows access"
            Description = "All Windows drives available (C:\, D:\, etc.)"
            Key = "full"
        },
        @{
            Id = 2
            Name = "Limited access (recommended)"
            Description = "Only the shared data folder inside OpenClaw directory"
            Key = "limited"
        },
        @{
            Id = 3
            Name = "Fully isolated"
            Description = "No Windows filesystem access at all"
            Key = "isolated"
        }
    )
}

function Select-FilesystemMode {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$Default = 2
    )
    
    $modes = Get-FilesystemModeChoices
    
    Write-Host ""
    Write-Host "  Select Windows filesystem access mode:" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($mode in $modes) {
        $isDefault = ($mode.Id -eq $Default)
        $defaultMark = if ($isDefault) { " (default)" } else { "" }
        $color = if ($isDefault) { "White" } else { "Gray" }
        
        Write-Host "    $($mode.Id)) $($mode.Name)$defaultMark" -ForegroundColor $color
        Write-Host "       $($mode.Description)" -ForegroundColor DarkGray
    }
    
    while ($true) {
        Write-Host ""
        Write-Host "  Enter choice (1-3) [default: $Default]: " -NoNewline -ForegroundColor Gray
        $userInput = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $mode = $modes | Where-Object { $_.Id -eq $Default }
            return $mode.Key
        }
        
        if ($userInput -match '^\d+$') {
            $choice = [int]$userInput
            $mode = $modes | Where-Object { $_.Id -eq $choice }
            if ($mode) {
                return $mode.Key
            }
        }
        
        Write-Host "  [ERROR] Please enter a number between 1 and 3." -ForegroundColor Red
    }
}

function Set-FilesystemAccessMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [ValidateSet("full", "limited", "isolated")]
        [string]$Mode,
        
        [Parameter()]
        [string]$DataFolderWindowsPath,
        
        [Parameter()]
        [string]$LinuxMountPoint = "/mnt/openclaw-data",
        
        [Parameter()]
        [string]$Username
    )
    
    Write-Host "  Configuring filesystem access mode: $Mode" -ForegroundColor Cyan
    
    # Log the configuration choice
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Set-FilesystemAccessMode: Distro=$DistroName, Mode=$Mode, DataFolder=$DataFolderWindowsPath, MountPoint=$LinuxMountPoint, User=$Username" -Level "Info"
    }
    
    # Get user UID/GID if provided
    $uid = 1000
    $gid = 1000
    if ($Username) {
        try {
            $uid = Get-LinuxUserUID -DistroName $DistroName -Username $Username
            $gid = Get-LinuxUserGID -DistroName $DistroName -Username $Username
        } catch {
            Write-Host "  [WARNING] Could not get user UID/GID, using defaults" -ForegroundColor Yellow
        }
    }
    
    switch ($Mode) {
        "full" {
            # Full access - enable automount, no custom fstab
            Set-WSLConfig -DistroName $DistroName `
                -AutomountEnabled $true `
                -MountFsTab $false `
                -InteropEnabled $true `
                -AppendWindowsPath $true `
                -DefaultUser $Username
            
            # Clear any custom mounts
            Clear-FstabEntries -DistroName $DistroName
        }
        
        "limited" {
            # Limited access - disable automount, mount only data folder
            if (-not $DataFolderWindowsPath) {
                $errorMsg = "DataFolderWindowsPath is required for limited mode isolation"
                if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                    Write-ErrorLog -Message $errorMsg
                }
                throw $errorMsg
            }
            
            Set-WSLConfig -DistroName $DistroName `
                -AutomountEnabled $false `
                -MountFsTab $true `
                -InteropEnabled $false `
                -AppendWindowsPath $false `
                -DefaultUser $Username
            
            # Clear old entries and add data folder mount
            Clear-FstabEntries -DistroName $DistroName
            
            Set-FstabEntry -DistroName $DistroName `
                -WindowsPath $DataFolderWindowsPath `
                -LinuxMountPoint $LinuxMountPoint `
                -Options "rw,metadata" `
                -UserUID $uid `
                -UserGID $gid
        }
        
        "isolated" {
            # Fully isolated - no Windows access at all
            Set-WSLConfig -DistroName $DistroName `
                -AutomountEnabled $false `
                -MountFsTab $false `
                -InteropEnabled $false `
                -AppendWindowsPath $false `
                -DefaultUser $Username
            
            # Clear all custom mounts
            Clear-FstabEntries -DistroName $DistroName
        }
    }
    
    Write-Host "  [OK] Filesystem access mode configured" -ForegroundColor Green
    return $true
}

#endregion

#region Network Isolation

<#
Network Isolation Modes:
1) Full - Normal network access
2) Local - localhost + internal WSL only
3) Offline - No network access
#>

function Get-NetworkModeChoices {
    [CmdletBinding()]
    param()
    
    return @(
        @{
            Id = 1
            Name = "Full network access"
            Description = "Normal network access (default)"
            Key = "full"
        },
        @{
            Id = 2
            Name = "Local-only"
            Description = "localhost + internal WSL only"
            Key = "local"
        },
        @{
            Id = 3
            Name = "Fully offline"
            Description = "No network access at all"
            Key = "offline"
        }
    )
}

function Select-NetworkMode {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$Default = 1
    )
    
    $modes = Get-NetworkModeChoices
    
    Write-Host ""
    Write-Host "  Restrict WSL network access?" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($mode in $modes) {
        $isDefault = ($mode.Id -eq $Default)
        $defaultMark = if ($isDefault) { " (default)" } else { "" }
        $color = if ($isDefault) { "White" } else { "Gray" }
        
        Write-Host "    $($mode.Id)) $($mode.Name)$defaultMark" -ForegroundColor $color
        Write-Host "       $($mode.Description)" -ForegroundColor DarkGray
    }
    
    while ($true) {
        Write-Host ""
        Write-Host "  Enter choice (1-3) [default: $Default]: " -NoNewline -ForegroundColor Gray
        $userInput = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $mode = $modes | Where-Object { $_.Id -eq $Default }
            return $mode.Key
        }
        
        if ($userInput -match '^\d+$') {
            $choice = [int]$userInput
            $mode = $modes | Where-Object { $_.Id -eq $choice }
            if ($mode) {
                return $mode.Key
            }
        }
        
        Write-Host "  [ERROR] Please enter a number between 1 and 3." -ForegroundColor Red
    }
}

function Set-NetworkIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [ValidateSet("full", "local", "offline")]
        [string]$Mode,
        
        [Parameter()]
        [string]$Username
    )
    
    Write-Host "  Configuring network isolation mode: $Mode" -ForegroundColor Cyan
    
    # Create network isolation script
    $scriptPath = "/etc/openclaw/network-isolation.sh"
    $enableScriptPath = "/etc/openclaw/enable-network-isolation.sh"
    $disableScriptPath = "/etc/openclaw/disable-network-isolation.sh"
    
    # Ensure directory exists
    Invoke-WSLCommand -DistroName $DistroName -Command "mkdir -p /etc/openclaw" -AsRoot -Silent | Out-Null
    
    switch ($Mode) {
        "full" {
            # Remove any existing network restrictions
            Remove-NetworkRestrictions -DistroName $DistroName
            Write-Host "  [OK] Full network access enabled" -ForegroundColor Green
        }
        
        "local" {
            # Allow localhost and WSL internal network only
            Set-LocalOnlyNetwork -DistroName $DistroName
            Write-Host "  [OK] Local-only network configured" -ForegroundColor Green
        }
        
        "offline" {
            # Block all network access
            Set-OfflineNetwork -DistroName $DistroName
            Write-Host "  [OK] Offline mode configured" -ForegroundColor Green
        }
    }
    
    # Create management scripts for later use
    New-NetworkManagementScripts -DistroName $DistroName -CurrentMode $Mode
    
    return $true
}

function Set-LocalOnlyNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # Use iptables to restrict network to localhost and WSL internal only
    $iptablesScript = @'
#!/bin/bash
# OpenClaw Local-only Network Configuration

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true

# Allow localhost
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow WSL internal network (typically 172.x.x.x)
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT

# Allow link-local
iptables -A OUTPUT -d 169.254.0.0/16 -j ACCEPT

# Allow localhost IPs
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT

# Drop everything else
iptables -A OUTPUT -j DROP

echo "Local-only network restrictions applied"
'@
    
    # Use base64 encoding for reliable transfer
    $normalizedScript = $iptablesScript -replace "`r`n", "`n"
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedScript)
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    $writeCmd = "echo '$scriptBase64' | base64 -d > /etc/openclaw/apply-local-network.sh && chmod +x /etc/openclaw/apply-local-network.sh"

    Invoke-WSLCommand -DistroName $DistroName -Command $writeCmd -AsRoot -Silent | Out-Null
    
    # Apply restrictions
    Invoke-WSLCommand -DistroName $DistroName -Command "/etc/openclaw/apply-local-network.sh" -AsRoot -Silent | Out-Null
    
    # Add to startup
    Add-NetworkStartupHook -DistroName $DistroName -ScriptPath "/etc/openclaw/apply-local-network.sh"
}

function Set-OfflineNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # Use iptables to block all network except localhost
    $iptablesScript = @'
#!/bin/bash
# OpenClaw Offline Network Configuration

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true

# Allow localhost only
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT

# Drop everything else
iptables -A OUTPUT -j DROP

echo "Offline network restrictions applied"
'@

    # Use base64 encoding for reliable transfer
    $normalizedScript = $iptablesScript -replace "`r`n", "`n"
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedScript)
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    $writeCmd = "echo '$scriptBase64' | base64 -d > /etc/openclaw/apply-offline-network.sh && chmod +x /etc/openclaw/apply-offline-network.sh"

    Invoke-WSLCommand -DistroName $DistroName -Command $writeCmd -AsRoot -Silent | Out-Null
    
    # Apply restrictions
    Invoke-WSLCommand -DistroName $DistroName -Command "/etc/openclaw/apply-offline-network.sh" -AsRoot -Silent | Out-Null
    
    # Add to startup
    Add-NetworkStartupHook -DistroName $DistroName -ScriptPath "/etc/openclaw/apply-offline-network.sh"
}

function Remove-NetworkRestrictions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # Flush iptables OUTPUT chain
    $cmd = "iptables -F OUTPUT 2>/dev/null || true; iptables -P OUTPUT ACCEPT 2>/dev/null || true"
    Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -Silent | Out-Null
    
    # Remove startup hook
    Remove-NetworkStartupHook -DistroName $DistroName
}

function Add-NetworkStartupHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )
    
    # Add to /etc/profile.d for execution on login
    $hookScript = @"
#!/bin/bash
# OpenClaw network isolation startup hook
if [ -x "$ScriptPath" ]; then
    sudo "$ScriptPath" >/dev/null 2>&1
fi
"@
    
    # Use base64 encoding for reliable transfer
    $normalizedScript = $hookScript -replace "`r`n", "`n"
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedScript)
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    $writeCmd = "echo '$scriptBase64' | base64 -d > /etc/profile.d/openclaw-network.sh && chmod +x /etc/profile.d/openclaw-network.sh"

    Invoke-WSLCommand -DistroName $DistroName -Command $writeCmd -AsRoot -Silent | Out-Null
}

function Remove-NetworkStartupHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    $cmd = "rm -f /etc/profile.d/openclaw-network.sh"
    Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -Silent | Out-Null
}

function New-NetworkManagementScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$CurrentMode
    )
    
    # Create enable script content
    $enableScript = @"
#!/bin/bash
# Re-enable network restrictions
echo "Re-enabling network restrictions..."

if [ -x /etc/openclaw/apply-local-network.sh ]; then
    /etc/openclaw/apply-local-network.sh
elif [ -x /etc/openclaw/apply-offline-network.sh ]; then
    /etc/openclaw/apply-offline-network.sh
else
    echo "No network restriction script found"
fi
"@

    # Create disable script content
    $disableScript = @"
#!/bin/bash
# Temporarily disable network restrictions
echo "Disabling network restrictions..."
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
echo "Network restrictions disabled. Run enable-network-isolation.sh to re-enable."
"@

    # Use base64 encoding for reliable transfer
    $normalizedEnable = $enableScript -replace "`r`n", "`n"
    $enableBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedEnable)
    $enableBase64 = [Convert]::ToBase64String($enableBytes)
    
    $normalizedDisable = $disableScript -replace "`r`n", "`n"
    $disableBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedDisable)
    $disableBase64 = [Convert]::ToBase64String($disableBytes)
    
    $writeEnableCmd = "echo '$enableBase64' | base64 -d > /etc/openclaw/enable-network-isolation.sh && chmod +x /etc/openclaw/enable-network-isolation.sh"
    $writeDisableCmd = "echo '$disableBase64' | base64 -d > /etc/openclaw/disable-network-isolation.sh && chmod +x /etc/openclaw/disable-network-isolation.sh"

    Invoke-WSLCommand -DistroName $DistroName -Command $writeEnableCmd -AsRoot -Silent | Out-Null
    Invoke-WSLCommand -DistroName $DistroName -Command $writeDisableCmd -AsRoot -Silent | Out-Null
}

#endregion

#region Status Checking

function Get-IsolationStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    $status = @{
        FilesystemMode = "unknown"
        NetworkMode = "unknown"
        Mounts = @()
    }
    
    # Check automount setting
    $wslConf = Get-WSLConfig -DistroName $DistroName
    if ($wslConf -match 'enabled\s*=\s*true') {
        $status.FilesystemMode = "full"
    } elseif ($wslConf -match 'mountFsTab\s*=\s*true') {
        $status.FilesystemMode = "limited"
    } else {
        $status.FilesystemMode = "isolated"
    }
    
    # Check network mode
    $iptablesCheck = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "iptables -L OUTPUT -n 2>/dev/null | grep -c DROP || echo 0" -AsRoot
    $dropCount = [int]($iptablesCheck.Trim())
    
    if ($dropCount -eq 0) {
        $status.NetworkMode = "full"
    } else {
        # Check if local IPs are allowed
        $localAllowed = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "iptables -L OUTPUT -n 2>/dev/null | grep -c '172.16.0.0' || echo 0" -AsRoot
        if ([int]($localAllowed.Trim()) -gt 0) {
            $status.NetworkMode = "local"
        } else {
            $status.NetworkMode = "offline"
        }
    }
    
    # Get current mounts
    $mounts = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "mount | grep drvfs || true"
    if ($mounts) {
        $status.Mounts = $mounts -split "`n" | Where-Object { $_ -ne "" }
    }
    
    return $status
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Filesystem
    'Get-FilesystemModeChoices',
    'Select-FilesystemMode',
    'Set-FilesystemAccessMode',
    
    # Network
    'Get-NetworkModeChoices',
    'Select-NetworkMode',
    'Set-NetworkIsolation',
    'Remove-NetworkRestrictions',
    
    # Status
    'Get-IsolationStatus'
)
