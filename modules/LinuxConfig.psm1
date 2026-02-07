#Requires -Version 5.1
<#
.SYNOPSIS
    Linux Configuration for OpenClaw WSL Automation
.DESCRIPTION
    Handles Linux user creation, sudo configuration, and wsl.conf management
#>

#region Linux User Management

function Test-LinuxUserExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command "id -u $Username 2>/dev/null" -AsRoot -PassThru -Silent
    return $result.ExitCode -eq 0
}

function New-LinuxUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$Shell = "/bin/bash"
    )
    
    # Check if user already exists
    if (Test-LinuxUserExists -DistroName $DistroName -Username $Username) {
        Write-Host "  User '$Username' already exists" -ForegroundColor DarkGray
        return $true
    }
    
    Write-Host "  Creating Linux user: $Username" -ForegroundColor Cyan
    
    # Create user with home directory
    $createCmd = "useradd -m -s $Shell $Username"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $createCmd -AsRoot -PassThru
    
    if ($result.ExitCode -ne 0) {
        $errorMsg = "Failed to create user '$Username': $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Add user to common groups
    $groupCmd = "usermod -aG sudo,adm $Username 2>/dev/null || usermod -aG wheel,adm $Username 2>/dev/null || true"
    Invoke-WSLCommand -DistroName $DistroName -Command $groupCmd -AsRoot -Silent | Out-Null
    
    Write-Host "  [OK] User '$Username' created" -ForegroundColor Green
    return $true
}

function Set-LinuxUserPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [int]$MaxAttempts = 3
    )
    
    Write-Host ""
    Write-Host "  Set password for Linux user '$Username'" -ForegroundColor Yellow
    Write-Host "  (You will be prompted in the WSL terminal)" -ForegroundColor DarkGray
    Write-Host ""
    
    $attempt = 0
    $success = $false
    
    while (-not $success -and $attempt -lt $MaxAttempts) {
        $attempt++
        
        if ($attempt -gt 1) {
            Write-Host ""
            Write-Host "  Attempt $attempt of $MaxAttempts" -ForegroundColor Cyan
            Write-Host ""
        }
        
        # Use interactive passwd command
        wsl.exe -d $DistroName -u root -- passwd $Username
        
        if ($LASTEXITCODE -eq 0) {
            $success = $true
        }
        else {
            $remainingAttempts = $MaxAttempts - $attempt
            
            if ($remainingAttempts -gt 0) {
                Write-Host ""
                Write-Host "  Password was not set. Please try again." -ForegroundColor Yellow
                Write-Host "  ($remainingAttempts attempt(s) remaining)" -ForegroundColor DarkGray
            }
        }
    }
    
    if (-not $success) {
        $errorMsg = "Failed to set password for user '$Username' after $MaxAttempts attempts"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  [OK] Password set for user '$Username'" -ForegroundColor Green
    return $true
}

function Set-DefaultWSLUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    # Get user ID
    $uid = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "id -u $Username" -AsRoot
    $uid = $uid.Trim()
    
    if (-not $uid -or $uid -notmatch '^\d+$') {
        $errorMsg = "Could not get UID for user '$Username' (got: '$uid')"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Check if wsl.conf exists
    $checkCmd = "test -f /etc/wsl.conf && echo 'exists' || echo 'notexists'"
    $exists = (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -AsRoot).Trim()
    
    if ($exists -eq 'exists') {
        # Check if [user] section exists
        $hasUserSection = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "grep -q '^\[user\]' /etc/wsl.conf && echo 'yes' || echo 'no'" -AsRoot
        
        if ($hasUserSection.Trim() -eq 'yes') {
            # Update existing default user line (handles both 'default=user' and 'default = user' formats)
            $sedCmd = "sed -i '/^\[user\]/,/^\[/ s/^default\s*=.*/default=$Username/' /etc/wsl.conf"
            Invoke-WSLCommand -DistroName $DistroName -Command $sedCmd -AsRoot -Silent | Out-Null
        } else {
            # Append user section using echo which is more reliable
            $appendCmd = "echo '' >> /etc/wsl.conf && echo '[user]' >> /etc/wsl.conf && echo 'default=$Username' >> /etc/wsl.conf"
            Invoke-WSLCommand -DistroName $DistroName -Command $appendCmd -AsRoot -Silent | Out-Null
        }
    } else {
        # Create new wsl.conf using echo
        $createCmd = "echo '[user]' > /etc/wsl.conf && echo 'default=$Username' >> /etc/wsl.conf"
        Invoke-WSLCommand -DistroName $DistroName -Command $createCmd -AsRoot -Silent | Out-Null
    }
    
    Write-Host "  [OK] Default WSL user set to '$Username'" -ForegroundColor Green
    return $true
}

#endregion

#region Sudo Configuration

function Set-PasswordlessSudo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Write-Host "  Configuring passwordless sudo for '$Username'" -ForegroundColor Cyan
    
    $sudoersFile = "/etc/sudoers.d/$Username"
    $sudoersContent = "$Username ALL=(ALL) NOPASSWD:ALL"
    
    # Create sudoers file
    $cmd = @"
echo '$sudoersContent' > $sudoersFile && chmod 440 $sudoersFile && chown root:root $sudoersFile
"@
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -PassThru
    
    if ($result.ExitCode -ne 0) {
        $errorMsg = "Failed to configure passwordless sudo: $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Validate sudoers syntax
    $validateCmd = "visudo -cf $sudoersFile"
    $validateResult = Invoke-WSLCommand -DistroName $DistroName -Command $validateCmd -AsRoot -PassThru -Silent
    
    if ($validateResult.ExitCode -ne 0) {
        # Remove invalid file
        Invoke-WSLCommand -DistroName $DistroName -Command "rm -f $sudoersFile" -AsRoot -Silent | Out-Null
        $errorMsg = "Invalid sudoers configuration generated (validation failed: $($validateResult.Output)). Removed for safety."
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  [OK] Passwordless sudo configured" -ForegroundColor Green
    return $true
}

function Test-PasswordlessSudo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $cmd = "sudo -n true 2>/dev/null"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $Username -PassThru -Silent
    
    return $result.ExitCode -eq 0
}

#endregion

#region WSL Configuration

function Set-WSLConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [bool]$AutomountEnabled = $false,
        
        [Parameter()]
        [bool]$MountFsTab = $true,
        
        [Parameter()]
        [bool]$InteropEnabled = $false,
        
        [Parameter()]
        [bool]$AppendWindowsPath = $false,
        
        [Parameter()]
        [string]$DefaultUser,
        
        [Parameter()]
        [bool]$SystemdEnabled = $true
    )
    
    Write-Host "  Configuring /etc/wsl.conf" -ForegroundColor Cyan
    
    # Log configuration choices
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Set-WSLConfig: Distro=$DistroName, Automount=$AutomountEnabled, MountFsTab=$MountFsTab, Interop=$InteropEnabled, AppendPath=$AppendWindowsPath, DefaultUser=$DefaultUser, Systemd=$SystemdEnabled" -Level "Debug"
    }
    
    # Build wsl.conf content
    $wslConfLines = @()
    
    # Boot section (systemd)
    $wslConfLines += "[boot]"
    $wslConfLines += "systemd = $($SystemdEnabled.ToString().ToLower())"
    $wslConfLines += ""
    
    # Automount section
    $wslConfLines += "[automount]"
    $wslConfLines += "enabled = $($AutomountEnabled.ToString().ToLower())"
    $wslConfLines += "mountFsTab = $($MountFsTab.ToString().ToLower())"
    $wslConfLines += ""
    
    # Interop section
    $wslConfLines += "[interop]"
    $wslConfLines += "enabled = $($InteropEnabled.ToString().ToLower())"
    $wslConfLines += "appendWindowsPath = $($AppendWindowsPath.ToString().ToLower())"
    
    # User section
    if ($DefaultUser) {
        $wslConfLines += ""
        $wslConfLines += "[user]"
        $wslConfLines += "default = $DefaultUser"
    }
    
    $wslConfContent = $wslConfLines -join "`n"
    
    # Log the content being written
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Writing wsl.conf content:`n$wslConfContent" -Level "Debug"
    }
    
    # Write to wsl.conf using base64 encoding for reliable transfer
    # This avoids issues with special characters and escaping
    $normalizedContent = $wslConfContent -replace "`r`n", "`n"
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedContent)
    $contentBase64 = [Convert]::ToBase64String($contentBytes)
    $cmd = "echo '$contentBase64' | base64 -d > /etc/wsl.conf"
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -PassThru
    
    if ($result.ExitCode -ne 0) {
        $errorMsg = "Failed to write /etc/wsl.conf: $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Verify the content was written correctly
    $verifyCmd = "cat /etc/wsl.conf"
    $verifyResult = Invoke-WSLCommand -DistroName $DistroName -Command $verifyCmd -AsRoot -PassThru -Silent
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Verified wsl.conf content:`n$($verifyResult.Output -join "`n")" -Level "Debug"
    }
    
    Write-Host "  [OK] /etc/wsl.conf configured" -ForegroundColor Green
    
    # Return whether restart is needed
    return $true
}

function Get-WSLConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    $cmd = "cat /etc/wsl.conf 2>/dev/null || echo ''"
    $content = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -AsRoot
    
    return $content
}

#endregion

#region Fstab Management

function Set-FstabEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$WindowsPath,
        
        [Parameter(Mandatory)]
        [string]$LinuxMountPoint,
        
        [Parameter()]
        [string]$Options = "rw,uid=1000,gid=1000,metadata",
        
        [Parameter()]
        [int]$UserUID = 1000,
        
        [Parameter()]
        [int]$UserGID = 1000
    )
    
    Write-Host "  Configuring fstab mount: $WindowsPath -> $LinuxMountPoint" -ForegroundColor Cyan
    
    # Convert Windows path to drvfs format
    # D:\folder -> D:\folder (WSL handles the conversion)
    $drvfsPath = $WindowsPath -replace '\\', '/'
    
    # Update options with actual UID/GID
    $finalOptions = $Options -replace 'uid=\d+', "uid=$UserUID" -replace 'gid=\d+', "gid=$UserGID"
    
    # Create mount point
    $mkdirCmd = "mkdir -p '$LinuxMountPoint'"
    Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -AsRoot -Silent | Out-Null
    
    # Create fstab entry
    $fstabLine = "$drvfsPath $LinuxMountPoint drvfs $finalOptions 0 0"
    
    # Check if entry already exists
    $checkCmd = "grep -qF '$LinuxMountPoint' /etc/fstab 2>/dev/null && echo 'exists' || echo 'notexists'"
    $exists = (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -AsRoot).Trim()
    
    if ($exists -eq 'exists') {
        # Remove old entry first
        $removeCmd = "sed -i '\|$LinuxMountPoint|d' /etc/fstab"
        Invoke-WSLCommand -DistroName $DistroName -Command $removeCmd -AsRoot -Silent | Out-Null
    }
    
    # Append new entry
    $appendCmd = "echo '$fstabLine' >> /etc/fstab"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $appendCmd -AsRoot -PassThru
    
    if ($result.ExitCode -ne 0) {
        $errorMsg = "Failed to update fstab: $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Log the fstab entry
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Added fstab entry: $fstabLine" -Level "Debug"
    }
    
    Write-Host "  [OK] Fstab entry added" -ForegroundColor Green
    return $true
}

function Clear-FstabEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$MountPointPattern = "/mnt/openclaw"
    )
    
    $cmd = "sed -i '\|$MountPointPattern|d' /etc/fstab 2>/dev/null || true"
    Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -Silent | Out-Null
}

function Mount-FstabEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    Write-Host "  Mounting fstab entries" -ForegroundColor Cyan
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command "mount -a 2>&1" -AsRoot -PassThru
    
    if ($result.ExitCode -ne 0) {
        Write-Host "  [WARNING] Some mounts may have failed: $($result.Output)" -ForegroundColor Yellow
        return $false
    }
    
    Write-Host "  [OK] Mounts applied" -ForegroundColor Green
    return $true
}

#endregion

#region User Info Helpers

function Get-LinuxUserUID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $uid = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "id -u $Username" -AsRoot
    return [int]($uid.Trim())
}

function Get-LinuxUserGID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $gid = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "id -g $Username" -AsRoot
    return [int]($gid.Trim())
}

function Get-LinuxUserHome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $home = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "getent passwd $Username | cut -d: -f6" -AsRoot
    return $home.Trim()
}

#endregion

#region Systemd Configuration

function Enable-SystemdLingering {
    <#
    .SYNOPSIS
        Enables systemd user lingering for a user
    .DESCRIPTION
        Runs 'loginctl enable-linger' to allow systemd user services to run
        even when the user is not logged in. This is required for OpenClaw
        gateway services to work properly in WSL2.
        
        Note: This must be called AFTER systemd is enabled in wsl.conf
        and the WSL distribution has been restarted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Write-Host "  Enabling systemd user lingering for '$Username'..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Enabling systemd lingering for $Username on $DistroName" -Level "Info"
    }
    
    # Check if systemd is running
    $systemdCheck = Invoke-WSLCommand -DistroName $DistroName -Command "systemctl --version 2>/dev/null && echo 'available' || echo 'not-available'" -AsRoot -PassThru -Silent
    $systemdOutput = if ($systemdCheck.Output) { ($systemdCheck.Output -join " ") } else { "" }
    
    if ($systemdOutput -notmatch "available") {
        Write-Host "  [WARNING] Systemd not available, skipping lingering setup" -ForegroundColor Yellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Systemd not available, cannot enable lingering" -Level "Warning"
        }
        return $false
    }
    
    # Enable lingering for the user
    $lingerCmd = "loginctl enable-linger $Username 2>&1"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $lingerCmd -AsRoot -PassThru -Silent
    
    if ($result.ExitCode -ne 0) {
        $errorOutput = if ($result.Output) { ($result.Output -join " ") } else { "unknown error" }
        Write-Host "  [WARNING] Could not enable lingering: $errorOutput" -ForegroundColor Yellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Failed to enable lingering: $errorOutput" -Level "Warning"
        }
        return $false
    }
    
    # Verify lingering is enabled
    $verifyCmd = "loginctl show-user $Username 2>/dev/null | grep -q 'Linger=yes' && echo 'enabled' || echo 'disabled'"
    $verifyResult = Invoke-WSLCommand -DistroName $DistroName -Command $verifyCmd -AsRoot -PassThru -Silent
    $verifyOutput = if ($verifyResult.Output) { ($verifyResult.Output -join " ").Trim() } else { "" }
    
    if ($verifyOutput -eq "enabled") {
        Write-Host "  [OK] Systemd user lingering enabled" -ForegroundColor Green
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Systemd lingering enabled for $Username" -Level "Info"
        }
        return $true
    } else {
        Write-Host "  [WARNING] Lingering may not be fully enabled (verification inconclusive)" -ForegroundColor Yellow
        return $true  # Don't fail installation, this is optional
    }
}

function Test-SystemdAvailable {
    <#
    .SYNOPSIS
        Tests if systemd is available in the WSL distribution
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command "pidof systemd >/dev/null 2>&1 && echo yes || echo no" -AsRoot -PassThru -Silent
    $output = if ($result.Output) { ($result.Output -join "").Trim() } else { "no" }
    
    return $output -eq "yes"
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # User Management
    'Test-LinuxUserExists',
    'New-LinuxUser',
    'Set-LinuxUserPassword',
    'Set-DefaultWSLUser',
    
    # Sudo
    'Set-PasswordlessSudo',
    'Test-PasswordlessSudo',
    
    # WSL Config
    'Set-WSLConfig',
    'Get-WSLConfig',
    
    # Fstab
    'Set-FstabEntry',
    'Clear-FstabEntries',
    'Mount-FstabEntries',
    
    # User Info
    'Get-LinuxUserUID',
    'Get-LinuxUserGID',
    'Get-LinuxUserHome',
    
    # Systemd
    'Enable-SystemdLingering',
    'Test-SystemdAvailable'
)
