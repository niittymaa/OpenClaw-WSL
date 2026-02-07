#Requires -Version 5.1
<#
.SYNOPSIS
    WSL Distribution Management for OpenClaw WSL Automation
.DESCRIPTION
    Handles listing, installing, and managing WSL distributions
#>

#region Distribution Discovery

function Get-InstalledDistributions {
    [CmdletBinding()]
    param()
    
    $distros = @()
    
    try {
        # Use wsl --list --verbose to get detailed info
        # WSL outputs UTF-16 which can include null bytes
        $output = wsl.exe --list --verbose 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # WSL might not have any distributions
            return $distros
        }
        
        # Convert to string and remove null characters (WSL UTF-16 encoding issue)
        $outputStr = ($output | Out-String) -replace "`0", ""
        
        # Parse output (skip header line)
        $lines = $outputStr -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
        
        # Skip header
        $dataLines = $lines | Select-Object -Skip 1
        
        foreach ($line in $dataLines) {
            # Handle default marker (*) and parse columns
            $isDefault = $line.TrimStart() -match '^\*'
            $cleanLine = $line -replace '^\s*\*?\s*', ''
            
            # Split by multiple spaces (columns are space-separated)
            $parts = $cleanLine -split '\s{2,}' | Where-Object { $_ -ne "" }
            
            if ($parts.Count -ge 2) {
                $distros += [PSCustomObject]@{
                    Name      = $parts[0].Trim()
                    State     = $parts[1].Trim()
                    Version   = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "Unknown" }
                    IsDefault = $isDefault
                }
            }
        }
    }
    catch {
        Write-Warning "Error getting installed distributions: $($_.Exception.Message)"
    }
    
    return $distros
}

function Get-AvailableDistributions {
    [CmdletBinding()]
    param()
    
    $distros = @()
    
    try {
        $output = wsl.exe --list --online 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get available distributions"
        }
        
        # Parse output - look for the distribution list
        $lines = $output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
        
        $inList = $false
        foreach ($line in $lines) {
            # Skip header lines, look for NAME column
            if ($line -match '^\s*NAME\s+FRIENDLY') {
                $inList = $true
                continue
            }
            
            if ($inList -and $line -match '^\s*(\S+)\s+(.+)$') {
                $distros += [PSCustomObject]@{
                    Name         = $Matches[1].Trim()
                    FriendlyName = $Matches[2].Trim()
                }
            }
        }
    }
    catch {
        Write-Warning "Error getting available distributions: $($_.Exception.Message)"
    }
    
    return $distros
}

function Find-LatestUbuntuLTS {
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCustomObject[]]$AvailableDistros
    )
    
    if (-not $AvailableDistros) {
        $AvailableDistros = Get-AvailableDistributions
    }
    
    # Look for Ubuntu LTS versions (even numbers like 22.04, 24.04)
    $ubuntuDistros = $AvailableDistros | Where-Object {
        $_.Name -match '^Ubuntu(-\d+\.\d+)?$'
    } | Sort-Object { 
        if ($_.Name -match '(\d+)\.(\d+)') {
            [double]"$($Matches[1]).$($Matches[2])"
        }
        else {
            0
        }
    } -Descending
    
    # Find latest LTS (even year versions)
    foreach ($distro in $ubuntuDistros) {
        if ($distro.Name -match 'Ubuntu-(\d+)\.04$') {
            $year = [int]$Matches[1]
            if ($year % 2 -eq 0) {
                return $distro
            }
        }
    }
    
    # Fallback to generic Ubuntu if no specific LTS found
    $generic = $ubuntuDistros | Where-Object { $_.Name -eq 'Ubuntu' } | Select-Object -First 1
    if ($generic) {
        return $generic
    }
    
    # Return any Ubuntu
    return $ubuntuDistros | Select-Object -First 1
}

function Test-DistributionExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $installed = Get-InstalledDistributions
    return ($installed | Where-Object { $_.Name -eq $Name }) -ne $null
}

function Test-DistributionRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $installed = Get-InstalledDistributions
    $distro = $installed | Where-Object { $_.Name -eq $Name }
    
    if ($distro) {
        return $distro.State -eq "Running"
    }
    
    return $false
}

#endregion

#region Distribution Installation

# Base distribution name for OpenClaw
$Script:OpenClawDistroBaseName = "openclaw"
# Cached unique name (set during Get-OrCreateOpenClawDistribution)
$Script:OpenClawDistroName = $null

function Get-OpenClawDistroName {
    <#
    .SYNOPSIS
        Gets the OpenClaw distribution name for this installation
    .DESCRIPTION
        Returns the cached distribution name if set, otherwise returns the base name.
        The actual unique name is determined during Get-OrCreateOpenClawDistribution.
    #>
    [CmdletBinding()]
    param()
    
    if ($Script:OpenClawDistroName) {
        return $Script:OpenClawDistroName
    }
    return $Script:OpenClawDistroBaseName
}

function Get-DistroNameFromStateFile {
    <#
    .SYNOPSIS
        Reads the distribution name from a state.json file
    .DESCRIPTION
        Used to determine the correct distribution name for portable imports
        or when checking existing installations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath
    )
    
    $stateFile = Join-Path $LocalPath "state.json"
    
    if (-not (Test-Path $stateFile)) {
        return $null
    }
    
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($state -and $state.DistroName) {
            return $state.DistroName
        }
    }
    catch {
        # Ignore parse errors
    }
    
    return $null
}

function Get-UniqueDistroName {
    <#
    .SYNOPSIS
        Generates a unique distribution name to avoid conflicts
    .DESCRIPTION
        If 'openclaw' already exists but is registered in a different location,
        adds a numeric suffix (openclaw_1, openclaw_2, etc.) to avoid conflicts.
        
        Naming convention:
        - First instance: openclaw
        - Second instance: openclaw_1
        - Third instance: openclaw_2
        - etc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseName,
        
        [Parameter(Mandatory)]
        [string]$ExpectedInstallPath
    )
    
    # First, check if there's a state.json with an existing distro name for this path
    $existingName = Get-DistroNameFromStateFile -LocalPath (Split-Path $ExpectedInstallPath -Parent)
    if ($existingName) {
        # If the distro exists and is ours (vhdx is in expected path), use it
        $expectedVhdx = Join-Path $ExpectedInstallPath "ext4.vhdx"
        if ((Test-DistributionExists -Name $existingName) -and (Test-Path $expectedVhdx)) {
            return $existingName
        }
        # If distro doesn't exist but we have vhdx, use the name from state for re-registration
        if ((-not (Test-DistributionExists -Name $existingName)) -and (Test-Path $expectedVhdx)) {
            return $existingName
        }
    }
    
    $candidateName = $BaseName
    $suffix = 0
    
    while ($true) {
        if (-not (Test-DistributionExists -Name $candidateName)) {
            # Name is available
            return $candidateName
        }
        
        # Check if existing distribution is in the expected path
        # by checking if the ext4.vhdx exists where we expect it
        $expectedVhdx = Join-Path $ExpectedInstallPath "ext4.vhdx"
        if (Test-Path $expectedVhdx) {
            # This is our distribution in the expected location
            return $candidateName
        }
        
        # Distribution exists elsewhere, try next suffix
        $suffix++
        $candidateName = "${BaseName}_$suffix"
        Write-Host "  Distribution '$($BaseName)' exists in another location, trying '$candidateName'..." -ForegroundColor Yellow
        
        # Safety limit to avoid infinite loops
        if ($suffix -gt 100) {
            throw "Unable to find unique distribution name after 100 attempts"
        }
    }
}

function Install-WSLDistribution {
    <#
    .SYNOPSIS
        Installs a new WSL distribution for OpenClaw use
    .DESCRIPTION
        Creates a new WSL distribution by exporting a base distro and importing with custom name.
        Stores the WSL data in the local project folder for portability.
        If Ubuntu is not installed and needed, it will be installed first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseDistroName,
        
        [Parameter()]
        [string]$TargetName = $Script:OpenClawDistroName,
        
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    
    Write-Host "  Target distribution: $TargetName" -ForegroundColor Cyan
    Write-Host "  Install path: $InstallPath" -ForegroundColor DarkGray
    
    # Check if target distribution already exists
    if (Test-DistributionExists -Name $TargetName) {
        Write-Host "  Distribution '$TargetName' already exists" -ForegroundColor Yellow
        return @{
            Success        = $true
            DistroName     = $TargetName
            AlreadyExisted = $true
        }
    }
    
    # Check if base distribution exists (needed to export/clone)
    $baseExists = Test-DistributionExists -Name $BaseDistroName
    
    if (-not $baseExists) {
        # Need to install base first
        Write-Host "  Base distribution '$BaseDistroName' not found, installing..." -ForegroundColor Yellow
        
        $installArgs = @("--install", "-d", $BaseDistroName, "--no-launch")
        $process = Start-Process -FilePath "wsl.exe" -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -ne 0) {
            $errorMsg = "Failed to install base distribution '$BaseDistroName'. Exit code: $($process.ExitCode)"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        # Wait for WSL to register the distribution
        Write-Host "  Waiting for WSL to register '$BaseDistroName'..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
        
        # Verify it was installed
        if (-not (Test-DistributionExists -Name $BaseDistroName)) {
            $errorMsg = "Base distribution '$BaseDistroName' was not registered after installation"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        Write-Host "  [OK] Base distribution '$BaseDistroName' installed" -ForegroundColor Green
    }
    
    # Clone from base distribution
    Write-Host "  Creating '$TargetName' from '$BaseDistroName'..." -ForegroundColor Cyan
    return Copy-Distribution -SourceName $BaseDistroName -TargetName $TargetName -InstallPath $InstallPath
}

function Copy-Distribution {
    <#
    .SYNOPSIS
        Creates a copy of an existing WSL distribution with a new name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceName,
        
        [Parameter(Mandatory)]
        [string]$TargetName,
        
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    
    # Create install directory
    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }
    
    # Create temp file for export
    $tempTar = Join-Path $env:TEMP "wsl-export-$SourceName-$(Get-Date -Format 'yyyyMMddHHmmss').tar"
    
    try {
        # Export source distribution
        Write-Host "  Exporting '$SourceName'..." -ForegroundColor DarkGray
        $exportProcess = Start-Process -FilePath "wsl.exe" -ArgumentList @("--export", $SourceName, $tempTar) -Wait -PassThru -NoNewWindow
        
        if ($exportProcess.ExitCode -ne 0) {
            $errorMsg = "Failed to export distribution '$SourceName' (exit code: $($exportProcess.ExitCode))"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        # Import as new distribution
        Write-Host "  Importing as '$TargetName'..." -ForegroundColor DarkGray
        $importProcess = Start-Process -FilePath "wsl.exe" -ArgumentList @("--import", $TargetName, $InstallPath, $tempTar) -Wait -PassThru -NoNewWindow
        
        if ($importProcess.ExitCode -ne 0) {
            $errorMsg = "Failed to import distribution as '$TargetName' (exit code: $($importProcess.ExitCode))"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        Write-Host "  [OK] Distribution '$TargetName' created" -ForegroundColor Green
        
        return @{
            Success        = $true
            DistroName     = $TargetName
            InstallPath    = $InstallPath
            AlreadyExisted = $false
        }
    }
    finally {
        # Cleanup temp file
        if (Test-Path $tempTar) {
            Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-Distribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [switch]$WaitForUserSetup
    )
    
    Write-Host "  Initializing distribution: $DistroName" -ForegroundColor Cyan
    Write-Host "  You will be prompted to create a user account and password." -ForegroundColor Yellow
    Write-Host ""
    
    # Launch distribution to complete setup
    # The user will be prompted for username/password during first launch
    wsl.exe -d $DistroName -- echo "Distribution initialized"
    
    if ($LASTEXITCODE -ne 0) {
        $errorMsg = "Failed to initialize distribution '$DistroName' (exit code: $LASTEXITCODE)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    return $true
}

function Stop-Distribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    wsl.exe --terminate $DistroName 2>&1 | Out-Null
    
    # Wait a moment for it to fully stop
    Start-Sleep -Seconds 2
}

function Restart-Distribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    Stop-Distribution -DistroName $DistroName
    
    # Start it again
    wsl.exe -d $DistroName -- echo "Distribution restarted" | Out-Null
}

function Remove-Distribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [switch]$Force
    )
    
    if (-not $Force) {
        Write-Host ""
        Write-Host "  WARNING: This will permanently delete the distribution '$DistroName'" -ForegroundColor Red
        Write-Host "  and all its data. This cannot be undone!" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Continue? [y/N]: " -NoNewline -ForegroundColor Yellow
        $confirm = Read-Host
        
        if ($confirm.ToLower() -ne 'y') {
            Write-Host "  Aborted." -ForegroundColor DarkGray
            return $false
        }
    }
    
    wsl.exe --unregister $DistroName 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        $errorMsg = "Failed to unregister distribution '$DistroName' (exit code: $LASTEXITCODE)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  [OK] Distribution '$DistroName' removed" -ForegroundColor Green
    return $true
}

#endregion

#region WSL Commands

function Invoke-WSLCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$User,
        
        [Parameter()]
        [switch]$AsRoot,
        
        [Parameter()]
        [switch]$PassThru,
        
        [Parameter()]
        [switch]$Silent,
        
        [Parameter()]
        [switch]$LoginShell
    )
    
    $wslArgs = @("-d", $DistroName)
    
    if ($AsRoot) {
        $wslArgs += @("-u", "root")
    }
    elseif ($User) {
        $wslArgs += @("-u", $User)
    }
    
    # Use login shell (-l) when LoginShell is specified for proper PATH
    $bashFlag = if ($LoginShell) { "-lc" } else { "-c" }
    $wslArgs += @("--", "bash", $bashFlag, $Command)
    
    if (-not $Silent) {
        Write-Host "  Running: $Command" -ForegroundColor DarkGray
    }
    
    # Log the command execution
    $effectiveUser = if ($AsRoot) { "root" } elseif ($User) { $User } else { "default" }
    
    $startTime = Get-Date
    
    if ($PassThru) {
        # Use SilentlyContinue to prevent stderr from throwing exceptions
        $prevErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $output = & wsl.exe @wslArgs 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevErrorAction
        }
        $duration = (Get-Date) - $startTime
        
        # Log to file if Logger module is available
        if (Get-Command Write-WSLCommandLog -ErrorAction SilentlyContinue) {
            Write-WSLCommandLog -DistroName $DistroName -Command $Command -Output ($output -join "`n") -ExitCode $exitCode -User $effectiveUser
        }
        
        return @{
            Output   = $output
            ExitCode = $exitCode
        }
    }
    else {
        & wsl.exe @wslArgs
        $exitCode = $LASTEXITCODE
        $duration = (Get-Date) - $startTime
        
        # Log to file if Logger module is available
        if (Get-Command Write-WSLCommandLog -ErrorAction SilentlyContinue) {
            Write-WSLCommandLog -DistroName $DistroName -Command $Command -ExitCode $exitCode -User $effectiveUser
        }
        
        return $exitCode
    }
}

function Invoke-WSLCommandWithOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$User,
        
        [Parameter()]
        [switch]$AsRoot,
        
        [Parameter()]
        [switch]$LoginShell
    )
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $Command -User $User -AsRoot:$AsRoot -LoginShell:$LoginShell -PassThru -Silent
    
    return $result.Output
}

function Test-WSLCommandSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [switch]$AsRoot
    )
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $Command -AsRoot:$AsRoot -PassThru -Silent
    return $result.ExitCode -eq 0
}

function Invoke-WSLCommandWithTimeout {
    <#
    .SYNOPSIS
        Executes a WSL command with timeout and comprehensive output capture
    .DESCRIPTION
        Runs a command in WSL with a specified timeout. Captures all output (stdout + stderr)
        and provides detailed logging on failure. Designed for long-running commands like npm install.
    .PARAMETER DistroName
        Name of the WSL distribution
    .PARAMETER Command
        The bash command to execute
    .PARAMETER User
        User to run the command as (optional)
    .PARAMETER AsRoot
        Run as root user
    .PARAMETER TimeoutSeconds
        Maximum time to wait for command completion (default: 300 = 5 minutes)
    .PARAMETER RetryCount
        Number of retries on failure (default: 0)
    .PARAMETER RetryDelaySeconds
        Delay between retries (default: 5)
    .OUTPUTS
        PSCustomObject with Output, ExitCode, TimedOut, Duration properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$User,
        
        [Parameter()]
        [switch]$AsRoot,
        
        [Parameter()]
        [int]$TimeoutSeconds = 300,
        
        [Parameter()]
        [int]$RetryCount = 0,
        
        [Parameter()]
        [int]$RetryDelaySeconds = 5,
        
        [Parameter()]
        [switch]$Silent
    )
    
    $effectiveUser = if ($AsRoot) { "root" } elseif ($User) { $User } else { "default" }
    $attempt = 0
    $lastResult = $null
    
    do {
        $attempt++
        $startTime = Get-Date
        $timedOut = $false
        
        # Build WSL arguments
        $wslArgs = @("-d", $DistroName)
        if ($AsRoot) {
            $wslArgs += @("-u", "root")
        } elseif ($User) {
            $wslArgs += @("-u", $User)
        }
        $wslArgs += @("--", "bash", "-c", $Command)
        
        if (-not $Silent) {
            $attemptInfo = if ($RetryCount -gt 0) { " (attempt $attempt/$($RetryCount + 1))" } else { "" }
            Write-Host "  Running: $Command$attemptInfo" -ForegroundColor DarkGray
        }
        
        try {
            # Use a background job with timeout for better control
            $job = Start-Job -ScriptBlock {
                param($wslArgs)
                $output = & wsl.exe @wslArgs 2>&1
                @{
                    Output = $output -join "`n"
                    ExitCode = $LASTEXITCODE
                }
            } -ArgumentList (,$wslArgs)
            
            # Wait for completion with timeout
            $completed = $job | Wait-Job -Timeout $TimeoutSeconds
            
            if ($null -eq $completed) {
                # Timed out
                $timedOut = $true
                $job | Stop-Job -PassThru | Remove-Job -Force
                
                $lastResult = @{
                    Output    = "Command timed out after $TimeoutSeconds seconds"
                    ExitCode  = -1
                    TimedOut  = $true
                    Duration  = (Get-Date) - $startTime
                }
                
                if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                    Write-ErrorLog -Message "WSL command timed out after ${TimeoutSeconds}s: $Command"
                }
            } else {
                # Completed (success or failure)
                $jobResult = $job | Receive-Job
                $job | Remove-Job -Force
                
                $lastResult = @{
                    Output    = $jobResult.Output
                    ExitCode  = $jobResult.ExitCode
                    TimedOut  = $false
                    Duration  = (Get-Date) - $startTime
                }
            }
        }
        catch {
            $lastResult = @{
                Output    = "Exception: $($_.Exception.Message)"
                ExitCode  = -1
                TimedOut  = $false
                Duration  = (Get-Date) - $startTime
            }
        }
        
        # Log the command execution
        if (Get-Command Write-WSLCommandLog -ErrorAction SilentlyContinue) {
            Write-WSLCommandLog -DistroName $DistroName -Command $Command -Output $lastResult.Output -ExitCode $lastResult.ExitCode -User $effectiveUser
        }
        
        # Success - no need to retry
        if ($lastResult.ExitCode -eq 0) {
            break
        }
        
        # Failed - retry if we have attempts left
        if ($attempt -le $RetryCount) {
            if (-not $Silent) {
                Write-Host "  Command failed, retrying in $RetryDelaySeconds seconds..." -ForegroundColor Yellow
            }
            Start-Sleep -Seconds $RetryDelaySeconds
        }
        
    } while ($attempt -le $RetryCount)
    
    return [PSCustomObject]$lastResult
}

#endregion

#region Distribution Selection UI

function Get-OrCreateOpenClawDistribution {
    <#
    .SYNOPSIS
        Gets the OpenClaw distribution, creating or importing it as needed
    .DESCRIPTION
        This is the main entry point for distribution setup.
        Handles fresh installs and portable imports.
        If 'openclaw' already exists elsewhere, uses a unique name with suffix.
        Returns the distribution name to use for OpenClaw.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PreferredBaseDistro = "Ubuntu",
        
        [Parameter(Mandatory)]
        [string]$LocalWSLPath
    )
    
    # Get a unique name for this installation location
    $targetName = Get-UniqueDistroName -BaseName $Script:OpenClawDistroBaseName -ExpectedInstallPath $LocalWSLPath
    
    # Cache the name for subsequent calls
    $Script:OpenClawDistroName = $targetName
    
    # Check if our distribution already exists at expected location
    $expectedVhdx = Join-Path $LocalWSLPath "ext4.vhdx"
    if ((Test-DistributionExists -Name $targetName) -and (Test-Path $expectedVhdx)) {
        Write-Host "  Found existing OpenClaw distribution: $targetName" -ForegroundColor Green
        return $targetName
    }
    
    # Check for portable import scenario (data exists but not registered)
    $localStatus = Get-LocalWSLStatus -LocalWSLPath $LocalWSLPath
    
    if ($localStatus.NeedsImport) {
        Write-Host "  Found existing WSL data, importing as '$targetName'..." -ForegroundColor Yellow
        $importResult = Import-DistributionFromLocal -LocalWSLPath $LocalWSLPath -DistroName $targetName
        if ($importResult.Success) {
            return $targetName
        }
        $errorMsg = "Failed to import existing distribution from $LocalWSLPath"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  OpenClaw distribution not found, creating..." -ForegroundColor Yellow
    
    # Ensure local WSL path exists
    if (-not (Test-Path $LocalWSLPath)) {
        New-Item -ItemType Directory -Path $LocalWSLPath -Force | Out-Null
    }
    
    # Try to find a suitable base distribution
    $installed = Get-InstalledDistributions
    $baseDistro = $null
    
    # Look for Ubuntu-based distros first (but not our own openclaw distros)
    foreach ($distro in $installed) {
        if ($distro.Name -match '^Ubuntu' -and $distro.Name -notmatch '^openclaw') {
            $baseDistro = $distro.Name
            break
        }
    }
    
    # If no suitable base found, use the preferred base (will be installed if needed)
    if (-not $baseDistro) {
        # Check available distributions
        $available = Get-AvailableDistributions
        
        if ($available.Count -gt 0) {
            $latestLTS = Find-LatestUbuntuLTS -AvailableDistros $available
            $baseDistro = if ($latestLTS) { $latestLTS.Name } else { $PreferredBaseDistro }
        }
        else {
            $baseDistro = $PreferredBaseDistro
        }
    }
    
    Write-Host "  Base distribution: $baseDistro" -ForegroundColor DarkGray
    
    # Install/create the distribution in local path
    $result = Install-WSLDistribution -BaseDistroName $baseDistro -TargetName $targetName -InstallPath $LocalWSLPath
    
    if ($result.Success) {
        return $result.DistroName
    }
    
    $errorMsg = "Failed to create OpenClaw distribution using base '$baseDistro' at '$LocalWSLPath'"
    if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
        Write-ErrorLog -Message $errorMsg
    }
    throw $errorMsg
}

#endregion

#region Portable Distribution Management

function Test-LocalWSLDataExists {
    <#
    .SYNOPSIS
        Checks if WSL data exists in the local folder (for portability detection)
    .DESCRIPTION
        Returns true if either ext4.vhdx (WSL2 disk) or a .tar backup exists
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalWSLPath
    )
    
    if (-not (Test-Path $LocalWSLPath)) {
        return $false
    }
    
    # Check for WSL2 virtual disk
    $vhdxPath = Join-Path $LocalWSLPath "ext4.vhdx"
    if (Test-Path $vhdxPath) {
        return $true
    }
    
    # Check for portable backup tar
    $tarPath = Join-Path $LocalWSLPath "openclaw.tar"
    if (Test-Path $tarPath) {
        return $true
    }
    
    return $false
}

function Get-LocalWSLStatus {
    <#
    .SYNOPSIS
        Gets detailed status of local WSL data
    .OUTPUTS
        PSCustomObject with HasData, HasVhdx, HasTar, IsRegistered, NeedsImport, DistroName
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalWSLPath,
        
        [Parameter()]
        [string]$DistroName
    )
    
    # Determine the distro name - prefer state.json, then cached name, then base name
    if (-not $DistroName) {
        $localPath = Split-Path $LocalWSLPath -Parent
        $DistroName = Get-DistroNameFromStateFile -LocalPath $localPath
        if (-not $DistroName) {
            $DistroName = Get-OpenClawDistroName
        }
    }
    
    $status = @{
        HasData      = $false
        HasVhdx      = $false
        HasTar       = $false
        IsRegistered = Test-DistributionExists -Name $DistroName
        NeedsImport  = $false
        VhdxPath     = $null
        TarPath      = $null
        DistroName   = $DistroName
    }
    
    if (Test-Path $LocalWSLPath) {
        $vhdxPath = Join-Path $LocalWSLPath "ext4.vhdx"
        $tarPath = Join-Path $LocalWSLPath "openclaw.tar"
        
        $status.HasVhdx = Test-Path $vhdxPath
        $status.HasTar = Test-Path $tarPath
        $status.HasData = $status.HasVhdx -or $status.HasTar
        
        if ($status.HasVhdx) { $status.VhdxPath = $vhdxPath }
        if ($status.HasTar) { $status.TarPath = $tarPath }
    }
    
    # Needs import if we have data but distribution is not registered
    $status.NeedsImport = $status.HasData -and (-not $status.IsRegistered)
    
    return [PSCustomObject]$status
}

function Export-DistributionForPortability {
    <#
    .SYNOPSIS
        Exports the WSL distribution to a tar file for portability
    .DESCRIPTION
        Creates a backup that can be imported on another system
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    
    $tarPath = Join-Path $OutputPath "openclaw.tar"
    
    Write-Host "  Exporting distribution for portability..." -ForegroundColor Cyan
    Write-Host "  This may take a few minutes..." -ForegroundColor DarkGray
    
    # Stop the distribution first
    Stop-Distribution -DistroName $DistroName
    
    # Export
    $exportProcess = Start-Process -FilePath "wsl.exe" `
        -ArgumentList @("--export", $DistroName, $tarPath) `
        -Wait -PassThru -NoNewWindow
    
    if ($exportProcess.ExitCode -ne 0) {
        $errorMsg = "Failed to export distribution '$DistroName' (exit code: $($exportProcess.ExitCode))"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  [OK] Distribution exported to: $tarPath" -ForegroundColor Green
    
    return @{
        Success = $true
        TarPath = $tarPath
    }
}

function Import-DistributionFromLocal {
    <#
    .SYNOPSIS
        Imports/registers a WSL distribution from local data
    .DESCRIPTION
        Used when the folder is moved to a new system - registers the existing WSL data
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalWSLPath,
        
        [Parameter()]
        [string]$DistroName
    )
    
    # Default to the base name if not specified
    if (-not $DistroName) {
        $DistroName = if ($Script:OpenClawDistroName) { $Script:OpenClawDistroName } else { $Script:OpenClawDistroBaseName }
    }
    
    $status = Get-LocalWSLStatus -LocalWSLPath $LocalWSLPath
    
    if (-not $status.HasData) {
        $errorMsg = "No WSL data found in $LocalWSLPath (checked for ext4.vhdx and .tar files)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    if ($status.IsRegistered) {
        Write-Host "  Distribution '$DistroName' is already registered" -ForegroundColor Yellow
        return @{
            Success           = $true
            DistroName        = $DistroName
            AlreadyRegistered = $true
        }
    }
    
    # Prefer importing from tar if available (cleaner)
    if ($status.HasTar) {
        Write-Host "  Importing distribution from portable backup..." -ForegroundColor Cyan
        
        $importProcess = Start-Process -FilePath "wsl.exe" `
            -ArgumentList @("--import", $DistroName, $LocalWSLPath, $status.TarPath) `
            -Wait -PassThru -NoNewWindow
        
        if ($importProcess.ExitCode -ne 0) {
            $errorMsg = "Failed to import distribution from tar: $($status.TarPath) (exit code: $($importProcess.ExitCode))"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        # Remove tar after successful import (vhdx is now the source of truth)
        Remove-Item $status.TarPath -Force -ErrorAction SilentlyContinue
        
        Write-Host "  [OK] Distribution imported successfully" -ForegroundColor Green
    }
    elseif ($status.HasVhdx) {
        # Import directly from vhdx (WSL2 only)
        Write-Host "  Registering distribution from existing disk..." -ForegroundColor Cyan
        
        # For vhdx, we need to import with --vhd flag
        $importProcess = Start-Process -FilePath "wsl.exe" `
            -ArgumentList @("--import-in-place", $DistroName, $status.VhdxPath) `
            -Wait -PassThru -NoNewWindow
        
        if ($importProcess.ExitCode -ne 0) {
            $errorMsg = "Failed to register distribution from vhdx: $($status.VhdxPath) (exit code: $($importProcess.ExitCode))"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
        
        Write-Host "  [OK] Distribution registered successfully" -ForegroundColor Green
    }
    
    return @{
        Success           = $true
        DistroName        = $DistroName
        AlreadyRegistered = $false
    }
}

#endregion

#region Installation Detection and Uninstallation

function Get-ExistingInstallationInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath
    )
    
    $wslPath = Join-Path $LocalPath "wsl"
    $stateFile = Join-Path $LocalPath "state.json"
    $vhdxFile = Join-Path $wslPath "ext4.vhdx"
    
    # Determine distro name - check state.json first, then fall back to cached/base name
    $distroName = Get-DistroNameFromStateFile -LocalPath $LocalPath
    if (-not $distroName) {
        $distroName = Get-OpenClawDistroName
    }
    
    $info = @{
        Exists = $false
        DistroName = $distroName
        HasDistro = $false
        HasWSLData = $false
        HasStateFile = $false
        StateFile = $stateFile
        State = $null
        Components = @()
    }
    
    # Check for state file first (to get accurate distro name)
    if (Test-Path $stateFile) {
        $info.HasStateFile = $true
        $info.Exists = $true
        try {
            $info.State = Get-Content $stateFile -Raw | ConvertFrom-Json
            # Update distro name from state if available
            if ($info.State -and $info.State.DistroName) {
                $distroName = $info.State.DistroName
                $info.DistroName = $distroName
            }
        } catch {
            $info.State = $null
        }
    }
    
    # Check if WSL distribution is registered
    if (Test-DistributionExists -Name $distroName) {
        $info.HasDistro = $true
        $info.Exists = $true
        $info.Components += @{
            Type = "WSL Distribution"
            Name = $distroName
            Description = "Linux environment with installed software"
        }
    }
    
    # Check for WSL virtual disk (the actual installation data)
    # This is the real indicator of an installation, not just logs folder
    if (Test-Path $vhdxFile) {
        $info.HasWSLData = $true
        $info.Exists = $true
        
        # Calculate size of WSL data
        $vhdxSize = (Get-Item $vhdxFile -ErrorAction SilentlyContinue).Length
        $sizeStr = if ($vhdxSize -gt 1GB) { 
            "{0:N2} GB" -f ($vhdxSize / 1GB) 
        } elseif ($vhdxSize -gt 1MB) { 
            "{0:N2} MB" -f ($vhdxSize / 1MB) 
        } else { 
            "{0:N2} KB" -f ($vhdxSize / 1KB) 
        }
        
        $info.Components += @{
            Type = "WSL Data"
            Name = "Virtual disk (ext4.vhdx)"
            Path = $vhdxFile
            Size = $sizeStr
            Description = "WSL virtual disk ($sizeStr)"
        }
    }
    
    # Add state file as component only if not already covered by WSL data
    if ($info.HasStateFile -and -not $info.HasWSLData) {
        $info.Components += @{
            Type = "Installation State"
            Name = "state.json"
            Path = $stateFile
            Description = "Previous installation configuration"
        }
    }
    
    return [PSCustomObject]$info
}

function Show-ExistingInstallationPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$InstallationInfo
    )
    
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host "           EXISTING INSTALLATION DETECTED" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  An existing OpenClaw installation was found:" -ForegroundColor White
    Write-Host ""
    
    foreach ($component in $InstallationInfo.Components) {
        $typeStr = $component.Type
        $nameStr = $component.Name
        Write-Host "  * ${typeStr}: " -ForegroundColor Cyan -NoNewline
        Write-Host "$nameStr" -ForegroundColor White
        if ($component.Description) {
            $descStr = $component.Description
            Write-Host "    $descStr" -ForegroundColor DarkGray
        }
    }
    
    if ($InstallationInfo.State -and $InstallationInfo.State.InstallDate) {
        Write-Host ""
        $dateStr = $InstallationInfo.State.InstallDate
        Write-Host "  Installed: $dateStr" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    Write-Host "  WARNING: The existing installation must be removed before reinstalling." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor White
    Write-Host "    1 - Uninstall existing and continue with fresh install" -ForegroundColor Green
    Write-Host "    2 - Abort installation" -ForegroundColor Red
    Write-Host ""
    
    while ($true) {
        Write-Host "  Enter choice [1-2]: " -ForegroundColor White -NoNewline
        $choice = Read-Host
        
        switch ($choice) {
            "1" { return "uninstall" }
            "2" { return "abort" }
            default {
                Write-Host "  Invalid choice. Please enter 1 or 2." -ForegroundColor Yellow
            }
        }
    }
}

function Remove-WindowsTerminalProfiles {
    <#
    .SYNOPSIS
        Removes Windows Terminal profiles for a specific WSL distribution
    .DESCRIPTION
        Cleans up stale Windows Terminal profiles when a WSL distribution is uninstalled.
        This prevents "distribution not found" errors when users click on old profiles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [switch]$Silent
    )
    
    $result = @{
        Success = $true
        Removed = 0
        Error = $null
    }
    
    try {
        $wtSettingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        
        if (-not (Test-Path $wtSettingsPath)) {
            # Windows Terminal not installed or settings not found
            return [PSCustomObject]$result
        }
        
        $settings = Get-Content $wtSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        
        if (-not $settings.profiles -or -not $settings.profiles.list) {
            return [PSCustomObject]$result
        }
        
        $beforeCount = $settings.profiles.list.Count
        
        # Filter out profiles matching the distribution name
        $settings.profiles.list = @($settings.profiles.list | Where-Object { $_.name -ne $DistroName })
        
        $afterCount = $settings.profiles.list.Count
        $result.Removed = $beforeCount - $afterCount
        
        if ($result.Removed -gt 0) {
            # Save updated settings
            $settings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding UTF8
            
            if (-not $Silent) {
                Write-Host "  [OK] Removed $($result.Removed) Windows Terminal profile(s)" -ForegroundColor Green
            }
        }
        else {
            if (-not $Silent) {
                Write-Host "  [OK] No Windows Terminal profiles to clean up" -ForegroundColor Green
            }
        }
    }
    catch {
        $result.Success = $false
        $result.Error = $_.Exception.Message
        
        if (-not $Silent) {
            Write-Host "  [WARN] Could not clean Windows Terminal profiles: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    return [PSCustomObject]$result
}

function Uninstall-OpenClawInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [switch]$KeepLocalData,
        
        [Parameter()]
        [switch]$Silent
    )
    
    $result = @{
        Success = $true
        RemovedComponents = @()
        Errors = @()
    }
    
    $info = Get-ExistingInstallationInfo -LocalPath $LocalPath
    
    if (-not $info.Exists) {
        if (-not $Silent) {
            Write-Host "  No existing installation found." -ForegroundColor DarkGray
        }
        return [PSCustomObject]$result
    }
    
    # Remove WSL distribution first (must be done before removing VHDX)
    if ($info.HasDistro) {
        $distroName = $info.DistroName
        if (-not $Silent) {
            Write-Host "  Stopping WSL distribution: $distroName" -ForegroundColor Cyan
        }
        
        # Terminate the distribution
        wsl.exe --terminate $distroName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        
        if (-not $Silent) {
            Write-Host "  Unregistering WSL distribution..." -ForegroundColor Cyan
        }
        
        $wslResult = wsl.exe --unregister $distroName 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            if (-not $Silent) {
                Write-Host "  [OK] WSL distribution removed: $distroName" -ForegroundColor Green
            }
            $result.RemovedComponents += "WSL Distribution: $distroName"
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Uninstalled WSL distribution: $distroName" -Level "Info"
            }
        } else {
            $errorMsg = "Failed to unregister WSL distribution: $wslResult"
            $result.Errors += $errorMsg
            $result.Success = $false
            
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            
            if (-not $Silent) {
                Write-Host "  [FAIL] $errorMsg" -ForegroundColor Red
            }
        }
        
        # Clean up Windows Terminal profiles for this distribution
        if (-not $Silent) {
            Write-Host "  Cleaning Windows Terminal profiles..." -ForegroundColor Cyan
        }
        $wtCleanup = Remove-WindowsTerminalProfiles -DistroName $distroName -Silent:$Silent
        if ($wtCleanup.Removed -gt 0) {
            $result.RemovedComponents += "Windows Terminal Profiles: $($wtCleanup.Removed) removed"
        }
    }
    
    # Remove local data (WSL disk, state file) unless KeepLocalData is specified
    # Only remove if there was actual WSL data or state file, not just logs
    if (($info.HasWSLData -or $info.HasStateFile) -and -not $KeepLocalData) {
        if (-not $Silent) {
            Write-Host "  Removing local data folder..." -ForegroundColor Cyan
        }
        
        try {
            # First try to remove just the contents to avoid permission issues
            Get-ChildItem -Path $LocalPath -Force -ErrorAction SilentlyContinue | 
                Remove-Item -Recurse -Force -ErrorAction Stop
            
            # Then remove the folder itself
            if (Test-Path $LocalPath) {
                Remove-Item -Path $LocalPath -Force -ErrorAction SilentlyContinue
            }
            
            if (-not $Silent) {
                Write-Host "  [OK] Local data folder removed" -ForegroundColor Green
            }
            $result.RemovedComponents += "Local Data: $LocalPath"
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Removed local data folder: $LocalPath" -Level "Info"
            }
        }
        catch {
            $excMsg = $_.Exception.Message
            $errorMsg = "Failed to remove local data: $excMsg"
            $result.Errors += $errorMsg
            
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            
            if (-not $Silent) {
                Write-Host "  [WARN] $errorMsg" -ForegroundColor Yellow
                Write-Host "      You may need to remove it manually: $LocalPath" -ForegroundColor DarkGray
            }
        }
    }
    
    return [PSCustomObject]$result
}

function Resize-WSLDisk {
    <#
    .SYNOPSIS
        Resizes the WSL2 virtual disk to allow more space
    .DESCRIPTION
        WSL2 virtual disks are dynamic but have a maximum size limit.
        Default is 256GB-1TB depending on WSL version.
        This function increases the maximum size to accommodate large installations
        like OpenAI Whisper, PyTorch, etc.
        
        Requires WSL 2.0+ with --manage support.
    .PARAMETER DistroName
        Name of the WSL distribution to resize
    .PARAMETER SizeGB
        New maximum size in gigabytes (default: 256)
    .PARAMETER Silent
        Suppress output messages
    .OUTPUTS
        Hashtable with Success and Message properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [int]$SizeGB = 256,
        
        [Parameter()]
        [switch]$Silent
    )
    
    $result = @{
        Success = $false
        Message = ""
        PreviousSize = $null
        NewSize = $null
    }
    
    # Check if distribution exists
    if (-not (Test-DistributionExists -Name $DistroName)) {
        $result.Message = "Distribution '$DistroName' not found"
        return $result
    }
    
    # Check WSL version supports --manage
    $wslVersion = wsl.exe --version 2>&1 | Out-String
    if ($wslVersion -notmatch "WSL version" -and $wslVersion -notmatch "WSL バージョン") {
        # Older WSL doesn't support --version, likely doesn't support --manage
        $result.Message = "WSL version does not support disk resize (requires WSL 2.0+)"
        if (-not $Silent) {
            Write-Host "  [INFO] $($result.Message)" -ForegroundColor DarkGray
        }
        return $result
    }
    
    if (-not $Silent) {
        Write-Host "  Configuring WSL disk size (max ${SizeGB}GB)..." -ForegroundColor DarkGray
    }
    
    # Terminate distribution first (required for resize)
    wsl.exe --terminate $DistroName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Try to resize using wsl --manage
    $resizeOutput = wsl.exe --manage $DistroName --set-sparse true 2>&1 | Out-String
    
    # Check if sparse mode was set (this enables dynamic growth)
    if ($LASTEXITCODE -eq 0) {
        if (-not $Silent) {
            Write-Host "  [OK] WSL disk configured for dynamic growth" -ForegroundColor Green
        }
        $result.Success = $true
        $result.Message = "Sparse mode enabled - disk will grow dynamically up to system limit"
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "WSL disk sparse mode enabled for $DistroName" -Level "Info"
        }
    } else {
        # --set-sparse might not be available on older WSL, try --resize
        $resizeOutput = wsl.exe --manage $DistroName --resize "${SizeGB}GB" 2>&1 | Out-String
        
        if ($LASTEXITCODE -eq 0) {
            if (-not $Silent) {
                Write-Host "  [OK] WSL disk resized to ${SizeGB}GB maximum" -ForegroundColor Green
            }
            $result.Success = $true
            $result.Message = "Disk resized to ${SizeGB}GB maximum"
            $result.NewSize = $SizeGB
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "WSL disk resized to ${SizeGB}GB for $DistroName" -Level "Info"
            }
        } else {
            # Resize not supported - that's OK, WSL2 disks are already dynamic
            $result.Message = "Disk resize command not available (WSL disks are already dynamic by default)"
            $result.Success = $true  # Not a failure - just not needed
            
            if (-not $Silent) {
                Write-Host "  [INFO] WSL disk is already dynamic (grows automatically)" -ForegroundColor DarkGray
            }
        }
    }
    
    return $result
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Discovery
    'Get-InstalledDistributions',
    'Get-AvailableDistributions',
    'Find-LatestUbuntuLTS',
    'Test-DistributionExists',
    'Test-DistributionRunning',
    'Get-OpenClawDistroName',
    'Get-UniqueDistroName',
    'Get-DistroNameFromStateFile',
    
    # Installation
    'Install-WSLDistribution',
    'Copy-Distribution',
    'Initialize-Distribution',
    'Stop-Distribution',
    'Restart-Distribution',
    'Remove-Distribution',
    
    # Commands
    'Invoke-WSLCommand',
    'Invoke-WSLCommandWithOutput',
    'Invoke-WSLCommandWithTimeout',
    'Test-WSLCommandSuccess',
    
    # Portable Distribution
    'Test-LocalWSLDataExists',
    'Get-LocalWSLStatus',
    'Export-DistributionForPortability',
    'Import-DistributionFromLocal',
    
    # Installation Detection and Uninstallation
    'Get-ExistingInstallationInfo',
    'Show-ExistingInstallationPrompt',
    'Uninstall-OpenClawInstallation',
    'Remove-WindowsTerminalProfiles',
    
    # Main Entry Point
    'Get-OrCreateOpenClawDistribution'
)
