#Requires -Version 5.1
<#
.SYNOPSIS
    Software Installation for OpenClaw WSL Automation
.DESCRIPTION
    Handles apt packages, Python dependencies, and OpenClaw installation
#>

#region Helper Functions

function Get-SafeTrimmedString {
    <#
    .SYNOPSIS
        Safely trims a string, handling null/error objects and arrays
    #>
    param(
        [Parameter()]
        $Value,
        
        [Parameter()]
        [string]$Default = ""
    )
    
    if ($null -eq $Value) {
        return $Default
    }
    
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ($trimmed -eq "") { return $Default } else { return $trimmed }
    }
    
    # Handle arrays (common from WSL command output)
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IEnumerable]) {
        $joined = ($Value | ForEach-Object { 
            if ($_ -is [string]) { $_ } 
            elseif ($null -ne $_) { $_.ToString() }
        }) -join "`n"
        $trimmed = $joined.Trim()
        if ($trimmed -eq "") { return $Default } else { return $trimmed }
    }
    
    # Handle other non-string objects (errors, etc.)
    try {
        $trimmed = $Value.ToString().Trim()
        if ($trimmed -eq "") { return $Default } else { return $trimmed }
    }
    catch {
        return $Default
    }
}

#endregion

#region Package Management

function Switch-AptMirror {
    <#
    .SYNOPSIS
        Switches apt sources to a different mirror to recover from hash mismatch errors
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [int]$MirrorIndex = 0
    )
    
    # List of alternative mirrors (0 = default archive.ubuntu.com)
    $mirrors = @(
        "archive.ubuntu.com",      # Default
        "mirrors.edge.kernel.org", # Fast global CDN
        "mirror.arizona.edu",      # US mirror
        "mirror.math.princeton.edu" # Another US mirror
    )
    
    if ($MirrorIndex -ge $mirrors.Count) {
        return $false
    }
    
    $newMirror = $mirrors[$MirrorIndex]
    Write-Host "  Switching to mirror: $newMirror" -ForegroundColor DarkGray
    
    # Switch all ubuntu mirrors in sources.list
    $switchCmd = @"
sed -i 's|http://[a-zA-Z0-9.\-]*ubuntu.com/ubuntu|http://$newMirror/ubuntu|g' /etc/apt/sources.list 2>/dev/null || true
sed -i 's|http://[a-zA-Z0-9.\-]*ubuntu.com/ubuntu|http://$newMirror/ubuntu|g' /etc/apt/sources.list.d/*.list 2>/dev/null || true
"@
    Invoke-WSLCommand -DistroName $DistroName -Command $switchCmd -AsRoot -Silent | Out-Null
    return $true
}

function Update-AptPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [int]$MaxRetries = 3
    )
    
    Write-Host "  Updating package lists..." -ForegroundColor Cyan
    
    # Log the operation
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Updating apt packages on $DistroName" -Level "Info"
    }
    
    $mirrorIndex = 0
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $result = Invoke-WSLCommand -DistroName $DistroName -Command "apt-get update -qq --allow-releaseinfo-change 2>&1" -AsRoot -PassThru
        
        # Check output for errors even if exit code is 0 (apt sometimes returns 0 with errors)
        $outputStr = Get-SafeTrimmedString $result.Output -Default ""
        $hasHashError = $outputStr -match "Hash Sum mismatch"
        $hasFetchError = $outputStr -match "Failed to fetch|Could not connect|Temporary failure"
        
        if ($result.ExitCode -eq 0 -and -not $hasHashError) {
            Write-Host "  [OK] Package lists updated" -ForegroundColor Green
            return $true
        }
        
        # Hash mismatch requires mirror switch
        if ($hasHashError) {
            Write-Host "  [WARNING] Hash mismatch detected (attempt $attempt/$MaxRetries), switching mirror..." -ForegroundColor Yellow
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "apt-get update hash mismatch on $DistroName, switching mirror" -Level "Warning"
            }
            
            # Clean apt state completely
            Invoke-WSLCommand -DistroName $DistroName -Command "apt-get clean && rm -rf /var/lib/apt/lists/* && mkdir -p /var/lib/apt/lists/partial" -AsRoot -Silent | Out-Null
            
            # Try next mirror
            $mirrorIndex++
            if (-not (Switch-AptMirror -DistroName $DistroName -MirrorIndex $mirrorIndex)) {
                Write-Host "  [WARNING] No more mirrors to try" -ForegroundColor Yellow
                break
            }
            Start-Sleep -Seconds 2
            continue
        }
        
        # Other transient errors - just retry with cleanup
        if ($hasFetchError -and $attempt -lt $MaxRetries) {
            Write-Host "  [WARNING] Package update failed (attempt $attempt/$MaxRetries), retrying..." -ForegroundColor Yellow
            Invoke-WSLCommand -DistroName $DistroName -Command "apt-get clean && rm -rf /var/lib/apt/lists/*" -AsRoot -Silent | Out-Null
            Start-Sleep -Seconds 3
        } else {
            Write-Host "  [WARNING] Package update had issues, but continuing..." -ForegroundColor Yellow
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "apt-get update completed with warnings on $DistroName" -Level "Warning"
            }
            break
        }
    }
    
    return $true
}

function Install-AptPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string[]]$Packages,
        
        [Parameter()]
        [switch]$SkipUpdate,
        
        [Parameter()]
        [int]$MaxRetries = 3
    )
    
    if (-not $SkipUpdate) {
        $null = Update-AptPackages -DistroName $DistroName
    }
    
    # Fix any broken packages first (common after interrupted installs or upgrades)
    Write-Host "  Fixing any broken packages..." -ForegroundColor DarkGray
    $fixResult = Invoke-WSLCommand -DistroName $DistroName -Command "dpkg --configure -a 2>&1; DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y -qq 2>&1" -AsRoot -PassThru -Silent
    
    $packageList = $Packages -join " "
    Write-Host "  Installing packages: $packageList" -ForegroundColor Cyan
    
    # Log the operation
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Installing apt packages on $DistroName`: $packageList" -Level "Info"
    }
    
    $cmd = "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --fix-missing $packageList 2>&1"
    $lastError = $null
    $mirrorIndex = 0
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -AsRoot -PassThru -Silent
        $outputStr = Get-SafeTrimmedString $result.Output -Default ""
        
        # Check for actual dpkg errors (not just informational messages)
        $hasDpkgErrors = $outputStr -match "dpkg: error processing|dpkg: dependency problems prevent|Sub-process /usr/bin/dpkg returned"
        $hasHashError = $outputStr -match "Hash Sum mismatch"
        $hasFetchError = $outputStr -match "Failed to fetch|Could not connect|Temporary failure|Unable to fetch"
        
        if ($result.ExitCode -eq 0 -and -not $hasDpkgErrors -and -not $hasHashError) {
            Write-Host "  [OK] Packages installed" -ForegroundColor Green
            return $true
        }
        
        $lastError = $outputStr
        
        # Hash mismatch - switch mirror
        if ($hasHashError -and $attempt -lt $MaxRetries) {
            Write-Host "  [WARNING] Hash mismatch during install (attempt $attempt/$MaxRetries), switching mirror..." -ForegroundColor Yellow
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "apt-get install hash mismatch (attempt $attempt), switching mirror" -Level "Warning"
            }
            
            # Clean and switch mirror
            $cleanupCmd = "dpkg --configure -a 2>/dev/null || true; apt --fix-broken install -y -qq 2>/dev/null || true; apt-get clean; rm -rf /var/lib/apt/lists/*"
            Invoke-WSLCommand -DistroName $DistroName -Command $cleanupCmd -AsRoot -Silent | Out-Null
            
            $mirrorIndex++
            if (Switch-AptMirror -DistroName $DistroName -MirrorIndex $mirrorIndex) {
                # Update package lists with new mirror
                Invoke-WSLCommand -DistroName $DistroName -Command "apt-get update -qq --allow-releaseinfo-change 2>&1" -AsRoot -Silent | Out-Null
            }
            Start-Sleep -Seconds 3
            continue
        }
        
        # dpkg errors or fetch errors - try to fix and retry
        if (($hasDpkgErrors -or $hasFetchError) -and $attempt -lt $MaxRetries) {
            Write-Host "  [WARNING] Package installation failed (attempt $attempt/$MaxRetries), repairing..." -ForegroundColor Yellow
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "apt-get install failed (attempt $attempt): $lastError - retrying" -Level "Warning"
            }
            
            # Aggressive cleanup: configure pending, fix broken, clean cache, rebuild lists
            $cleanupCmd = "dpkg --configure -a 2>/dev/null || true; apt --fix-broken install -y -qq 2>/dev/null || true; apt-get clean; rm -rf /var/lib/apt/lists/*; apt-get update -qq --allow-releaseinfo-change 2>&1"
            Invoke-WSLCommand -DistroName $DistroName -Command $cleanupCmd -AsRoot -Silent | Out-Null
            
            Start-Sleep -Seconds 5
        } else {
            break
        }
    }
    
    $errorMsg = "Failed to install packages after $MaxRetries attempts: $lastError"
    if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
        Write-ErrorLog -Message $errorMsg
    }
    throw $errorMsg
}

function Test-PackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$PackageName
    )
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command "dpkg -l $PackageName 2>/dev/null | grep -q '^ii'" -AsRoot -PassThru -Silent
    return $result.ExitCode -eq 0
}

function Get-RequiredPackages {
    [CmdletBinding()]
    param()
    
    # Note: nodejs/npm installed separately via NodeSource
    # openssl is required for proper SSL certificate handling
    # cmake and build-essential are required for node-llama-cpp
    # procps, file, unzip are required for Homebrew (unzip extracts brew packages)
    # dbus, dbus-user-session are required for systemd user services
    # jq is useful for JSON manipulation in scripts
    return @(
        "python3",
        "python3-pip",
        "python3-venv",
        "git",
        "curl",
        "wget",
        "ca-certificates",
        "openssl",
        "gnupg",
        "cmake",
        "build-essential",
        "procps",
        "file",
        "unzip",
        "jq",
        "dbus",
        "dbus-user-session"
    )
}

function Install-NodeJS {
    <#
    .SYNOPSIS
        Installs Node.js 22 (required by OpenClaw)
    .DESCRIPTION
        OpenClaw requires Node.js >= 22.12.0
        Uses Windows-side download to bypass WSL2 SSL bug (GitHub #12340)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$Version = "22",
        
        [Parameter()]
        [string]$NodeVersion = "22.22.0"
    )
    
    Write-Host "  Installing Node.js $Version (required by OpenClaw)..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Installing Node.js $Version on $DistroName" -Level "Info"
    }
    
    # Check if node is already installed with correct version
    $nodeCheck = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "node --version 2>/dev/null || echo 'not-installed'"
    $currentVersion = Get-SafeTrimmedString $nodeCheck -Default "not-installed"
    
    if ($currentVersion -ne 'not-installed') {
        # Check if version is 22+
        if ($currentVersion -match '^v(\d+)') {
            $majorVersion = [int]$Matches[1]
            if ($majorVersion -ge 22) {
                Write-Host "  Node.js already installed: $currentVersion" -ForegroundColor DarkGray
                return $true
            }
            Write-Host "  Node.js $currentVersion found, upgrading to v$Version..." -ForegroundColor DarkGray
        }
    }
    
    # Try NodeSource setup first (uses small script, usually succeeds)
    $setupCmd = "curl -fsSL https://deb.nodesource.com/setup_$Version.x 2>&1 | bash - 2>&1"
    Write-Host "  Running NodeSource setup..." -ForegroundColor DarkGray
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $setupCmd -AsRoot -PassThru -Silent
    
    if ($result.ExitCode -eq 0) {
        # Install nodejs package
        $installCmd = "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs 2>&1"
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $installCmd -AsRoot -PassThru -Silent
        
        if ($result.ExitCode -eq 0) {
            # Verify version
            $verifyCmd = "node --version 2>/dev/null"
            $version = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $verifyCmd) -Default "unknown"
            Write-Host "  [OK] Node.js installed via NodeSource: $version" -ForegroundColor Green
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Node.js installed via NodeSource: $version" -Level "Info"
            }
            return $true
        } else {
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message "apt-get install nodejs failed: $($result.Output)"
            }
        }
    } else {
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message "NodeSource setup failed: $($result.Output)"
        }
    }
    
    # Fallback: Download from Windows to bypass WSL2 SSL bug (GitHub #12340)
    # Large file downloads in WSL2 can fail with SSL errors due to networking stack bug
    Write-Host "  [!] NodeSource failed, downloading from Windows..." -ForegroundColor Yellow
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "NodeSource failed, using Windows-side download to bypass WSL2 SSL bug" -Level "Warning"
    }
    
    $nodeUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-linux-x64.tar.xz"
    $tempDir = Join-Path $env:TEMP "openclaw-install"
    $nodeTarball = Join-Path $tempDir "node-v$NodeVersion-linux-x64.tar.xz"
    
    # Create temp directory
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    
    # Download Node.js from Windows (bypasses WSL2 SSL bug)
    Write-Host "  Downloading Node.js v$NodeVersion..." -ForegroundColor DarkGray
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($nodeUrl, $nodeTarball)
        Write-Host "  [OK] Downloaded Node.js" -ForegroundColor Green
    }
    catch {
        $errorMsg = "Failed to download Node.js from Windows: $_"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Get WSL path for the downloaded file
    $wslTempPath = $tempDir -replace '\\', '/'
    if ($wslTempPath -match '^([A-Za-z]):(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        $wslTarball = "/mnt/$drive$rest/node-v$NodeVersion-linux-x64.tar.xz"
    }
    
    # Install in WSL from local file
    $installCmd = @"
cd /tmp && cp '$wslTarball' . && tar -xf node-v$NodeVersion-linux-x64.tar.xz && cp -r node-v$NodeVersion-linux-x64/* /usr/ && rm -rf node-v$NodeVersion-linux-x64* && echo done 2>&1
"@
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $installCmd -AsRoot -PassThru -Silent
    
    # Clean up Windows temp file
    Remove-Item -Path $nodeTarball -Force -ErrorAction SilentlyContinue
    
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'done') {
        $errorMsg = "Failed to install Node.js: $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    # Verify installation
    $verifyCmd = "node --version 2>/dev/null"
    $version = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $verifyCmd) -Default "unknown"
    Write-Host "  [OK] Node.js installed: $version" -ForegroundColor Green
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Node.js installed via Windows download: $version" -Level "Info"
    }
    
    return $true
}

function Test-HomebrewInstalled {
    <#
    .SYNOPSIS
        Checks if Homebrew is installed in WSL
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$Username
    )
    
    $brewPath = "/home/linuxbrew/.linuxbrew/bin/brew"
    $cmd = "test -x '$brewPath' && echo 'yes' || echo 'no'"
    $result = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $Username
    
    return (Get-SafeTrimmedString $result) -eq 'yes'
}

function Test-BuildToolsWorking {
    <#
    .SYNOPSIS
        Verifies that build tools (gcc, g++) are properly installed and working
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    # Test that gcc can actually compile something
    $testCmd = @"
echo 'int main() { return 0; }' > /tmp/test.c && gcc /tmp/test.c -o /tmp/test 2>&1 && rm -f /tmp/test /tmp/test.c && echo 'OK'
"@
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $testCmd -AsRoot -PassThru -Silent
    $output = Get-SafeTrimmedString $result.Output -Default ""
    
    return ($result.ExitCode -eq 0 -and $output -match 'OK')
}

function Get-WSLArchitecture {
    <#
    .SYNOPSIS
        Detects the CPU architecture inside WSL
    .DESCRIPTION
        Returns the system architecture (x86_64, arm64, etc.) which is important
        for Homebrew packages that have architecture requirements.
    .OUTPUTS
        Hashtable with:
          - Raw: uname -m output (x86_64, aarch64, etc.)
          - Normalized: Friendly name (x86_64, arm64)
          - IsArm64: Boolean indicating ARM architecture
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    $archCmd = "uname -m 2>/dev/null || echo 'unknown'"
    $rawArch = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $archCmd) -Default "unknown"
    
    # Normalize architecture names
    $normalized = switch ($rawArch) {
        "x86_64"  { "x86_64" }
        "amd64"   { "x86_64" }
        "aarch64" { "arm64" }
        "arm64"   { "arm64" }
        "armv7l"  { "arm32" }
        "i686"    { "x86" }
        "i386"    { "x86" }
        default   { $rawArch }
    }
    
    $isArm64 = $normalized -eq "arm64"
    
    return @{
        Raw = $rawArch
        Normalized = $normalized
        IsArm64 = $isArm64
    }
}

function Set-HomebrewEnvironment {
    <#
    .SYNOPSIS
        Configures Homebrew environment variables in user's shell profile
    .DESCRIPTION
        Sets environment variables to:
        - HOMEBREW_NO_AUTO_UPDATE=1: Disable auto-updates (speeds up brew commands)
        - HOMEBREW_NO_ENV_HINTS=1: Suppress environment hints in output
        - HOMEBREW_NO_INSTALL_FROM_API=1: Force local formula metadata (prevents "Broken pipe" errors)
        
        These improve the user experience by reducing noise, wait times, and network errors.
        
        Note: Some OpenClaw skills require arm64 architecture (Apple Silicon).
        On x86_64 (Intel/AMD), these skills will show "arm64 architecture required" errors.
        This is a hardware limitation and cannot be fixed by software configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [switch]$DisableAutoUpdate = $true,
        
        [Parameter()]
        [switch]$DisableEnvHints = $true,
        
        [Parameter()]
        [switch]$DisableInstallFromAPI = $true
    )
    
    Write-Host "  Configuring Homebrew environment..." -ForegroundColor DarkGray
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Configuring Homebrew environment for $Username on $DistroName" -Level "Info"
    }
    
    # Build environment variable exports
    $envLines = @()
    
    if ($DisableAutoUpdate) {
        $envLines += 'export HOMEBREW_NO_AUTO_UPDATE=1'
    }
    
    if ($DisableEnvHints) {
        $envLines += 'export HOMEBREW_NO_ENV_HINTS=1'
    }
    
    if ($DisableInstallFromAPI) {
        # This forces Homebrew to use local taps instead of API
        # Prevents "Broken pipe" errors during skill installation
        $envLines += 'export HOMEBREW_NO_INSTALL_FROM_API=1'
    }
    
    if ($envLines.Count -eq 0) {
        return $true
    }
    
    # Create the environment block to add
    $envBlock = "# Homebrew environment`n" + ($envLines -join "`n")
    $envBlockBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($envBlock))
    
    # Add to .bashrc if not already present
    $bashrcCmd = "if ! grep -q 'HOMEBREW_NO_AUTO_UPDATE' ~/.bashrc 2>/dev/null; then printf '\\n' >> ~/.bashrc && echo '$envBlockBase64' | base64 -d >> ~/.bashrc && printf '\\n' >> ~/.bashrc; fi"
    Invoke-WSLCommand -DistroName $DistroName -Command $bashrcCmd -User $Username -Silent | Out-Null
    
    # Add to .profile as well for login shells
    $profileCmd = "if ! grep -q 'HOMEBREW_NO_AUTO_UPDATE' ~/.profile 2>/dev/null; then printf '\\n' >> ~/.profile && echo '$envBlockBase64' | base64 -d >> ~/.profile && printf '\\n' >> ~/.profile; fi"
    Invoke-WSLCommand -DistroName $DistroName -Command $profileCmd -User $Username -Silent | Out-Null
    
    Write-Host "  [OK] Homebrew environment configured" -ForegroundColor Green
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Homebrew environment configured: NO_AUTO_UPDATE=$DisableAutoUpdate, NO_ENV_HINTS=$DisableEnvHints, NO_INSTALL_FROM_API=$DisableInstallFromAPI" -Level "Debug"
    }
    
    return $true
}

function Install-Homebrew {
    <#
    .SYNOPSIS
        Installs Homebrew (Linuxbrew) in WSL
    .DESCRIPTION
        Homebrew is recommended for OpenClaw skill dependencies.
        Installs to /home/linuxbrew/.linuxbrew and configures PATH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Write-Host "  Installing Homebrew (recommended for skill dependencies)..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Installing Homebrew on $DistroName for user $Username" -Level "Info"
    }
    
    # Detect and display system architecture
    $archInfo = Get-WSLArchitecture -DistroName $DistroName
    Write-Host "  System architecture: $($archInfo.Normalized)" -ForegroundColor DarkGray
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Detected architecture: $($archInfo.Raw) (normalized: $($archInfo.Normalized))" -Level "Debug"
    }
    
    # Show architecture note for x86_64 (most common on Windows WSL)
    if ($archInfo.Normalized -eq "x86_64") {
        Write-Host ""
        Write-Host "  ┌─ Architecture Note (x86_64) ────────────────────────────" -ForegroundColor Yellow
        Write-Host "  │" -ForegroundColor Yellow
        Write-Host "  │  Some OpenClaw skills require arm64 (Apple Silicon) and" -ForegroundColor Yellow
        Write-Host "  │  will not work on x86_64. You may see these errors:" -ForegroundColor Yellow
        Write-Host "  │" -ForegroundColor Yellow
        Write-Host "  │  • 'arm64 architecture required' - Hardware limitation" -ForegroundColor Yellow
        Write-Host "  │  • 'missing brew formula' - Not available for x86_64" -ForegroundColor Yellow
        Write-Host "  │  • 'Broken pipe' - Network issue (retry usually works)" -ForegroundColor Yellow
        Write-Host "  │" -ForegroundColor Yellow
        Write-Host "  │  These are normal on x86_64. Most skills still work!" -ForegroundColor Yellow
        Write-Host "  │  Run 'openclaw doctor' to see available skills." -ForegroundColor Yellow
        Write-Host "  │" -ForegroundColor Yellow
        Write-Host "  └────────────────────────────────────────────────────────" -ForegroundColor Yellow
        Write-Host ""
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "x86_64 architecture detected - some arm64-only skills will not be available" -Level "Info"
        }
    }
    
    # Check if already installed
    if (Test-HomebrewInstalled -DistroName $DistroName -Username $Username) {
        $brewVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "/home/linuxbrew/.linuxbrew/bin/brew --version 2>/dev/null | head -1" -User $Username) -Default "unknown"
        Write-Host "  Homebrew already installed: $brewVersion" -ForegroundColor DarkGray
        
        # Ensure environment is configured even for existing installations
        $null = Set-HomebrewEnvironment -DistroName $DistroName -Username $Username
        
        return $true
    }
    
    # Homebrew requires these packages (most already in required packages)
    $brewDeps = @("build-essential", "procps", "curl", "file", "git")
    Write-Host "  Ensuring Homebrew dependencies..." -ForegroundColor DarkGray
    
    try {
        $null = Install-AptPackages -DistroName $DistroName -Packages $brewDeps -SkipUpdate
    }
    catch {
        Write-Host "  [WARNING] Could not install Homebrew dependencies: $_" -ForegroundColor Yellow
        Write-Host "  Skipping Homebrew installation" -ForegroundColor DarkGray
        return $false
    }
    
    # Verify build tools actually work before proceeding
    Write-Host "  Verifying build tools..." -ForegroundColor DarkGray
    if (-not (Test-BuildToolsWorking -DistroName $DistroName)) {
        Write-Host "  [WARNING] Build tools (gcc) not working properly - skipping Homebrew" -ForegroundColor Yellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Homebrew skipped: build tools not working on $DistroName" -Level "Warning"
        }
        Write-Host "  You can try installing Homebrew manually later after fixing apt packages" -ForegroundColor DarkGray
        return $false
    }
    
    # Install Homebrew non-interactively as the user (NOT root)
    # NONINTERACTIVE=1 prevents prompts
    # NOTE: We download the script first then run it to avoid PowerShell escaping issues
    # with the $(...) command substitution in: /bin/bash -c "$(curl ...)"
    Write-Host "  Running Homebrew installer (this may take a few minutes)..." -ForegroundColor DarkGray
    
    # Step 1: Download the installer script
    $downloadCmd = "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew_install.sh 2>&1"
    $downloadResult = Invoke-WSLCommand -DistroName $DistroName -Command $downloadCmd -User $Username -PassThru -Silent
    
    if ($downloadResult.ExitCode -ne 0) {
        $errorOutput = Get-SafeTrimmedString $downloadResult.Output -Default "Failed to download installer"
        Write-Host "  [WARNING] Failed to download Homebrew installer: $errorOutput" -ForegroundColor Yellow
        return $false
    }
    
    # Step 2: Run the downloaded installer script
    $installCmd = "NONINTERACTIVE=1 bash /tmp/brew_install.sh 2>&1"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $installCmd -User $Username -PassThru -Silent
    
    # Clean up the installer script
    $null = Invoke-WSLCommand -DistroName $DistroName -Command "rm -f /tmp/brew_install.sh" -User $Username -Silent
    
    if ($result.ExitCode -ne 0) {
        # Log error but don't fail - Homebrew is optional
        $errorOutput = Get-SafeTrimmedString $result.Output -Default "Unknown error"
        
        # Try to extract the most relevant error message (last few lines often have the cause)
        $errorLines = ($errorOutput -split "`n") | Where-Object { $_.Trim() -ne "" }
        $relevantError = if ($errorLines.Count -gt 5) {
            ($errorLines | Select-Object -Last 5) -join "`n"
        } else {
            $errorOutput
        }
        
        Write-Host "  [WARNING] Homebrew installation failed (exit code $($result.ExitCode)):" -ForegroundColor Yellow
        Write-Host "  $relevantError" -ForegroundColor DarkGray
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Homebrew installation failed (exit $($result.ExitCode)): $errorOutput" -Level "Warning"
        }
        
        Write-Host "  You can install Homebrew manually later with:" -ForegroundColor DarkGray
        Write-Host "    /bin/bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)`"" -ForegroundColor DarkGray
        return $false
    }
    
    # Configure PATH in user's shell profile
    Write-Host "  Configuring Homebrew PATH..." -ForegroundColor DarkGray
    
    # The line to add: eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    # Use base64 encoding and pipe directly to file to avoid $() being executed during variable assignment
    $brewLine = 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    $brewLineBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($brewLine))
    
    # Add to .bashrc if not already present - pipe base64 directly to file to avoid shell evaluation
    $bashrcCmd = "if ! grep -q 'linuxbrew' ~/.bashrc 2>/dev/null; then printf '\\n# Homebrew\\n' >> ~/.bashrc && echo '$brewLineBase64' | base64 -d >> ~/.bashrc && printf '\\n' >> ~/.bashrc; fi"
    Invoke-WSLCommand -DistroName $DistroName -Command $bashrcCmd -User $Username -Silent | Out-Null
    
    # Add to .profile as well for login shells
    $profileCmd = "if ! grep -q 'linuxbrew' ~/.profile 2>/dev/null; then printf '\\n# Homebrew\\n' >> ~/.profile && echo '$brewLineBase64' | base64 -d >> ~/.profile && printf '\\n' >> ~/.profile; fi"
    Invoke-WSLCommand -DistroName $DistroName -Command $profileCmd -User $Username -Silent | Out-Null
    
    # Verify installation
    $brewVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "/home/linuxbrew/.linuxbrew/bin/brew --version 2>/dev/null | head -1" -User $Username) -Default "not found"
    
    if ($brewVersion -ne "not found" -and $brewVersion -ne "") {
        Write-Host "  [OK] Homebrew installed: $brewVersion" -ForegroundColor Green
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Homebrew installed: $brewVersion" -Level "Info"
        }
        
        # Configure Homebrew environment (disable auto-update, env hints)
        $null = Set-HomebrewEnvironment -DistroName $DistroName -Username $Username
        
        return $true
    } else {
        Write-Host "  [WARNING] Homebrew installation could not be verified" -ForegroundColor Yellow
        return $false
    }
}

function Install-RequiredPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$Username
    )
    
    $packages = Get-RequiredPackages
    
    Write-Host ""
    Write-Host "  Installing required packages..." -ForegroundColor Cyan
    
    # Detect and display system architecture early
    $archInfo = Get-WSLArchitecture -DistroName $DistroName
    Write-Host "  System architecture: $($archInfo.Normalized)" -ForegroundColor DarkGray
    
    $null = Install-AptPackages -DistroName $DistroName -Packages $packages
    
    # Update CA certificates
    Write-Host "  Updating CA certificates..." -ForegroundColor DarkGray
    $caUpdateCmd = 'update-ca-certificates 2>/dev/null || true'
    Invoke-WSLCommand -DistroName $DistroName -Command $caUpdateCmd -AsRoot -Silent | Out-Null
    
    # Install Node.js (uses Windows-side download to bypass WSL2 SSL bug if needed)
    $null = Install-NodeJS -DistroName $DistroName
    
    # Install Homebrew if username provided (Homebrew must be installed as user, not root)
    if ($Username) {
        $null = Install-Homebrew -DistroName $DistroName -Username $Username
    }
    
    # Verify Python
    $pythonVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "python3 --version 2>/dev/null || echo 'not found'") -Default "not found"
    Write-Host "  Python version: $pythonVersion" -ForegroundColor DarkGray
    
    # Verify pip
    $pipVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "pip3 --version 2>/dev/null || echo 'not found'") -Default "not found"
    Write-Host "  Pip version: $pipVersion" -ForegroundColor DarkGray
    
    # Verify git
    $gitVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "git --version 2>/dev/null || echo 'not found'") -Default "not found"
    Write-Host "  Git version: $gitVersion" -ForegroundColor DarkGray
    
    # Verify Node.js
    $nodeVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "node --version 2>/dev/null || echo 'not found'") -Default "not found"
    Write-Host "  Node.js version: $nodeVersion" -ForegroundColor DarkGray
    
    # Verify npm
    $npmVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "npm --version 2>/dev/null || echo 'not found'") -Default "not found"
    Write-Host "  npm version: $npmVersion" -ForegroundColor DarkGray
    
    # Verify Homebrew (if username was provided)
    if ($Username) {
        $brewVersion = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "/home/linuxbrew/.linuxbrew/bin/brew --version 2>/dev/null | head -1 || echo 'not found'" -User $Username) -Default "not found"
        Write-Host "  Homebrew version: $brewVersion" -ForegroundColor DarkGray
    }
    
    # Enable systemd user services (loginctl linger) if systemd is available
    if ($Username) {
        $null = Enable-SystemdUserServices -DistroName $DistroName -Username $Username
    }
    
    return $true
}

function Enable-SystemdUserServices {
    <#
    .SYNOPSIS
        Enables systemd user services support by enabling user lingering
    .DESCRIPTION
        Runs `loginctl enable-linger $USER` to allow systemd user services
        to run persistently (even after logout). Required for OpenClaw's
        systemd service integration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Write-Host "  Configuring systemd user services..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Enabling systemd user services for $Username on $DistroName" -Level "Info"
    }
    
    # Check if systemd is running (PID 1 should be systemd after WSL restart)
    $systemdCheck = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command "ps -p 1 -o comm= 2>/dev/null || echo 'unknown'"
    $initSystem = Get-SafeTrimmedString $systemdCheck -Default "unknown"
    
    if ($initSystem -ne "systemd") {
        Write-Host "  [INFO] systemd not yet active (init=$initSystem)" -ForegroundColor DarkGray
        Write-Host "  User services will be enabled after WSL restart" -ForegroundColor DarkGray
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "systemd not active yet (init=$initSystem), linger will be enabled after restart" -Level "Debug"
        }
        return $false
    }
    
    # Enable user lingering so systemd user services persist after logout
    $lingerCmd = "loginctl enable-linger $Username 2>&1 || echo 'linger-failed'"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $lingerCmd -AsRoot -PassThru -Silent
    $output = Get-SafeTrimmedString $result.Output -Default ""
    
    if ($result.ExitCode -eq 0 -and $output -notmatch 'linger-failed') {
        Write-Host "  [OK] systemd user services enabled (linger)" -ForegroundColor Green
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "loginctl enable-linger succeeded for $Username" -Level "Info"
        }
        return $true
    } else {
        Write-Host "  [INFO] Could not enable user lingering (non-critical)" -ForegroundColor DarkGray
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "loginctl enable-linger failed (non-critical): $output" -Level "Debug"
        }
        return $false
    }
}

#endregion

#region Git Operations

function Test-GitRepositoryExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [string]$User
    )
    
    $cmd = "test -d '$Path/.git' && echo 'yes' || echo 'no'"
    $result = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $User
    
    return (Get-SafeTrimmedString $result) -eq 'yes'
}

function Clone-GitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$RepositoryUrl,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [Parameter()]
        [string]$Branch = "main",
        
        [Parameter()]
        [string]$User
    )
    
    Write-Host "  Cloning repository: $RepositoryUrl" -ForegroundColor Cyan
    Write-Host "  Destination: $DestinationPath" -ForegroundColor DarkGray
    
    # Log the operation
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Cloning git repository: $RepositoryUrl to $DestinationPath (branch: $Branch)" -Level "Info"
    }
    
    # Create parent directory if needed
    if ($DestinationPath -match '^(.+)/[^/]+$') {
        $parentDir = $Matches[1]
        $mkdirCmd = "mkdir -p '$parentDir'"
        Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -User $User -Silent | Out-Null
    }
    
    # Remove destination if exists (in case of partial clone)
    $rmCmd = "rm -rf '$DestinationPath'"
    Invoke-WSLCommand -DistroName $DistroName -Command $rmCmd -User $User -Silent | Out-Null
    
    # Try clone with specified branch first
    $cloneCmd = "git clone --branch $Branch --single-branch '$RepositoryUrl' '$DestinationPath' 2>&1"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cloneCmd -User $User -PassThru
    
    if ($result.ExitCode -ne 0) {
        # Try without branch specification (use default branch)
        Write-Host "  Trying default branch..." -ForegroundColor DarkGray
        $rmCmd = "rm -rf '$DestinationPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $rmCmd -User $User -Silent | Out-Null
        
        $cloneCmd = "git clone '$RepositoryUrl' '$DestinationPath' 2>&1"
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $cloneCmd -User $User -PassThru
        
        if ($result.ExitCode -ne 0) {
            $errorMsg = "Failed to clone repository: $($result.Output)"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            throw $errorMsg
        }
    }
    
    Write-Host "  [OK] Repository cloned" -ForegroundColor Green
    return $true
}

function Update-GitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$RepositoryPath,
        
        [Parameter()]
        [string]$User
    )
    
    Write-Host "  Updating repository: $RepositoryPath" -ForegroundColor Cyan
    
    $cmd = "cd '$RepositoryPath' && git pull --ff-only"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $User -PassThru
    
    if ($result.ExitCode -ne 0) {
        Write-Host "  [WARNING] Repository update failed (may have local changes)" -ForegroundColor Yellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Git pull failed for $RepositoryPath`: $($result.Output)" -Level "Warning"
        }
        return $false
    }
    
    Write-Host "  [OK] Repository updated" -ForegroundColor Green
    return $true
}

#endregion

#region Python/Pip Operations

function Install-PythonRequirements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$RequirementsPath,
        
        [Parameter()]
        [string]$User,
        
        [Parameter()]
        [switch]$UseVenv,
        
        [Parameter()]
        [string]$VenvPath
    )
    
    Write-Host "  Installing Python requirements..." -ForegroundColor Cyan
    
    # Log the operation
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Installing Python requirements from $RequirementsPath" -Level "Info"
    }
    
    # Check if requirements file exists
    $checkCmd = "test -f '$RequirementsPath' && echo 'yes' || echo 'no'"
    $exists = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $User) -Default "no"
    
    if ($exists -ne 'yes') {
        $warnMsg = "Requirements file not found: $RequirementsPath"
        Write-Host "  [WARNING] $warnMsg" -ForegroundColor Yellow
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message $warnMsg -Level "Warning"
        }
        return $false
    }
    
    if ($UseVenv -and $VenvPath) {
        # Create venv if it doesn't exist
        $venvCheck = "test -d '$VenvPath' && echo 'yes' || echo 'no'"
        $venvExists = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $venvCheck -User $User) -Default "no"
        
        if ($venvExists -ne 'yes') {
            Write-Host "  Creating virtual environment: $VenvPath" -ForegroundColor DarkGray
            $createVenvCmd = "python3 -m venv '$VenvPath'"
            Invoke-WSLCommand -DistroName $DistroName -Command $createVenvCmd -User $User -Silent | Out-Null
        }
        
        # Install in venv
        $pipCmd = "'$VenvPath/bin/pip' install -r '$RequirementsPath' --quiet"
    } else {
        # Install globally for user
        $pipCmd = "pip3 install --user -r '$RequirementsPath' --quiet"
    }
    
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $pipCmd -User $User -PassThru
    
    if ($result.ExitCode -ne 0) {
        $errorMsg = "Failed to install Python requirements: $($result.Output)"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        throw $errorMsg
    }
    
    Write-Host "  [OK] Python requirements installed" -ForegroundColor Green
    return $true
}

function Test-PythonModuleInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$ModuleName,
        
        [Parameter()]
        [string]$User
    )
    
    $cmd = "python3 -c `"import $ModuleName`" 2>/dev/null && echo 'yes' || echo 'no'"
    $result = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $User) -Default "no"
    
    return $result -eq 'yes'
}

#endregion

#region Node.js/npm Operations

function Initialize-NpmUserInstall {
    <#
    .SYNOPSIS
        Configures npm for user-local global installations
    .DESCRIPTION
        Sets up npm prefix to ~/.npm-global and adds it to PATH in .bashrc
        Also configures npm settings to work around WSL2 SSL bug (GitHub #12340)
        by limiting concurrent connections and adding retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Configuring npm for user-local installs on $DistroName" -Level "Info"
    }
    
    # Create .npm-global directory
    $mkdirCmd = 'mkdir -p ~/.npm-global'
    Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -User $Username -Silent | Out-Null
    
    # Set npm prefix
    $prefixCmd = 'npm config set prefix ~/.npm-global'
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $prefixCmd -User $Username -PassThru -Silent
    
    if ($result.ExitCode -ne 0) {
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message "Failed to set npm prefix: $($result.Output)"
        }
        return $false
    }
    
    # Configure npm for WSL2 compatibility (workaround for SSL bug with concurrent connections)
    # Setting maxsockets=1 forces sequential downloads to completely avoid the WSL2 network stack
    # bug that corrupts SSL data when multiple connections are active simultaneously.
    # Also add generous retry settings for resilience.
    $npmConfigCmd = @'
npm config set maxsockets 1
npm config set fetch-retries 5
npm config set fetch-retry-mintimeout 20000
npm config set fetch-retry-maxtimeout 120000
'@
    $configResult = Invoke-WSLCommand -DistroName $DistroName -Command $npmConfigCmd -User $Username -PassThru -Silent
    
    if ($configResult.ExitCode -ne 0) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "npm SSL workaround config failed: $($configResult.Output)" -Level "Warning"
        }
    }
    
    # Add to PATH in .bashrc if not already there
    $pathCmd = 'grep -q "\.npm-global/bin" ~/.bashrc 2>/dev/null || echo ''export PATH="$HOME/.npm-global/bin:$PATH"'' >> ~/.bashrc'
    Invoke-WSLCommand -DistroName $DistroName -Command $pathCmd -User $Username -Silent | Out-Null
    
    # Also add to .profile for login shells
    $profileCmd = 'grep -q "\.npm-global/bin" ~/.profile 2>/dev/null || echo ''export PATH="$HOME/.npm-global/bin:$PATH"'' >> ~/.profile'
    Invoke-WSLCommand -DistroName $DistroName -Command $profileCmd -User $Username -Silent | Out-Null
    
    return $true
}

function Test-NpmConnectivity {
    <#
    .SYNOPSIS
        Tests npm registry connectivity
    .DESCRIPTION
        Verifies that npm can reach the registry. Returns diagnostic info on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$User
    )
    
    $cmd = 'npm ping 2>&1 && echo "SUCCESS" || echo "FAILED"'
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $User -PassThru -Silent
    
    $success = $result.Output -match "SUCCESS"
    
    if (-not $success) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "npm connectivity check failed: $($result.Output)" -Level "Warning"
        }
    }
    
    return @{
        Success = $success
        Output  = $result.Output
    }
}

function Clear-NpmCache {
    <#
    .SYNOPSIS
        Clears npm cache to resolve potential corruption issues
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$User
    )
    
    $cmd = 'npm cache clean --force 2>&1'
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $User -PassThru -Silent
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "npm cache cleared" -Level "Debug"
    }
    
    return $result.ExitCode -eq 0
}

function Install-OpenClawNpm {
    <#
    .SYNOPSIS
        Installs OpenClaw via npm with robust error handling
    .DESCRIPTION
        Uses Windows-side download to bypass WSL2 SSL bug (GitHub #12340).
        Large file downloads in WSL2 fail with SSL cipher errors due to a networking bug.
        Solution: Download npm tarball from Windows, then install from local file in WSL2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [int]$MaxRetries = 2,
        
        [Parameter()]
        [int]$TimeoutSeconds = 300
    )
    
    Write-Host ""
    Write-Host "  Installing OpenClaw..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Installing OpenClaw on $DistroName for user $Username" -Level "Info"
    }
    
    # Check if openclaw is already installed
    $checkCmd = 'PATH=~/.npm-global/bin:$PATH command -v openclaw >/dev/null 2>&1 && echo "installed" || echo "not-installed"'
    $checkResult = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $Username
    $installed = Get-SafeTrimmedString $checkResult -Default "not-installed"
    
    if ($installed -eq 'installed' -and -not $Force) {
        Write-Host "  OpenClaw is already installed." -ForegroundColor Yellow
        $versionCmd = 'PATH=~/.npm-global/bin:$PATH openclaw --version 2>/dev/null || echo "unknown"'
        $versionResult = Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $versionCmd -User $Username
        $version = Get-SafeTrimmedString $versionResult -Default "unknown"
        Write-Host "  Current version: $version" -ForegroundColor DarkGray
        return @{
            Success = $true
            AlreadyInstalled = $true
            Version = $version
            Method = "npm"
        }
    }
    
    # Step 1: Configure npm for user-local installs
    Write-Host "  Configuring npm for user installs..." -ForegroundColor DarkGray
    $npmConfigured = Initialize-NpmUserInstall -DistroName $DistroName -Username $Username
    
    if (-not $npmConfigured) {
        $errorMsg = "Failed to configure npm for user installs"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message $errorMsg
        }
        Write-Host "  [X] $errorMsg" -ForegroundColor Red
        return @{
            Success = $false
            Error = $errorMsg
            Method = "npm"
        }
    }
    Write-Host "  [OK] npm configured for user installs" -ForegroundColor Green
    
    # Step 2: Try npm install with retries
    # The npm config (maxsockets=1) should prevent most SSL errors, but we retry just in case
    $maxAttempts = 3
    $installSuccess = $false
    
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $waitTime = $attempt * 5  # Exponential backoff: 10s, 15s
            Write-Host "  Retry $attempt/$maxAttempts (waiting ${waitTime}s for network to stabilize)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $waitTime
        } else {
            Write-Host "  Installing via npm (this may take 1-2 minutes)..." -ForegroundColor DarkGray
        }
        
        $directResult = Invoke-WSLCommand -DistroName $DistroName -Command 'npm install -g openclaw 2>&1' -User $Username -PassThru -Silent
        
        if ($directResult.ExitCode -eq 0) {
            Write-Host "  [OK] npm install succeeded" -ForegroundColor Green
            $installSuccess = $true
            break
        }
        
        # Check if it's the known WSL2 SSL bug
        $isSSLError = $directResult.Output -match "ERR_SSL_CIPHER_OPERATION_FAILED|decryption failed|bad record mac|cipher"
        
        if (-not $isSSLError) {
            # Some other error - log and fail
            $errorMsg = "npm install failed: $($directResult.Output)"
            if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                Write-ErrorLog -Message $errorMsg
            }
            Write-Host "  [X] $errorMsg" -ForegroundColor Red
            return @{
                Success = $false
                Error = $errorMsg
                LastOutput = $directResult.Output
                Method = "npm"
            }
        }
        
        Write-Host "  [!] SSL error detected (WSL2 bug #12340)..." -ForegroundColor Yellow
    }
    
    if (-not $installSuccess) {
        # All direct attempts failed with SSL errors, try Windows download fallback
        Write-Host ""
        Write-Host "  +-- WSL2 SSL Bug Workaround ---------------------------------" -ForegroundColor Yellow
        Write-Host "  |  Direct npm install failed due to a known WSL2 networking bug." -ForegroundColor Yellow
        Write-Host "  |  Attempting to download via Windows instead..." -ForegroundColor Yellow
        Write-Host "  +------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "npm install failed with SSL errors, attempting Windows download" -Level "Warning"
        }
        
        $installSuccess = Install-OpenClawFromWindowsDownload -DistroName $DistroName -Username $Username
        
        if (-not $installSuccess) {
            Write-Host ""
            Write-Host "  +-- Manual Installation Required ----------------------------" -ForegroundColor Red
            Write-Host "  |  Automatic installation failed due to WSL2 SSL bug." -ForegroundColor Red
            Write-Host "  |" -ForegroundColor Red
            Write-Host "  |  To install manually:" -ForegroundColor Red
            Write-Host "  |    1. Run 'wsl --shutdown' and restart your computer" -ForegroundColor White
            Write-Host "  |    2. Re-run this installer" -ForegroundColor White
            Write-Host "  |" -ForegroundColor Red
            Write-Host "  |  Or install manually in WSL:" -ForegroundColor Red
            Write-Host "  |    wsl -d openclaw" -ForegroundColor White
            Write-Host "  |    npm install -g openclaw" -ForegroundColor White
            Write-Host "  +------------------------------------------------------------" -ForegroundColor Red
            Write-Host ""
            
            return @{
                Success = $false
                Error = "OpenClaw installation failed due to WSL2 SSL bug (GitHub #12340)"
                Method = "npm"
                Hint = "Run 'wsl --shutdown', restart Windows, then retry"
            }
        }
    }
    
    # Note: Gateway configuration is done AFTER 'openclaw setup' runs (in Start-OpenClawSetup)
    # because 'openclaw setup' creates/resets the config file. Configuring here would be overwritten.
    
    # Step 3: Verify installation
    Write-Host "  Verifying installation..." -ForegroundColor DarkGray
    $verifyCmd = '~/.npm-global/bin/openclaw --version 2>/dev/null || echo "not-found"'
    $version = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $verifyCmd -User $Username) -Default "not-found"
    
    if ($version -eq 'not-found' -or [string]::IsNullOrWhiteSpace($version)) {
        # Try with PATH
        $verifyCmd2 = 'PATH=~/.npm-global/bin:$PATH openclaw --version 2>/dev/null || echo "not-found"'
        $version = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $verifyCmd2 -User $Username) -Default "not-found"
    }
    
    if ($version -eq 'not-found' -or [string]::IsNullOrWhiteSpace($version)) {
        $errorMsg = "OpenClaw installation could not be verified"
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            $lsOutput = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command 'ls -la ~/.npm-global/bin/ 2>&1' -User $Username) -Default "unable to list"
            Write-ErrorLog -Message "$errorMsg`nnpm-global/bin contents:`n$lsOutput"
        }
        Write-Host "  [X] $errorMsg" -ForegroundColor Red
        return @{
            Success = $false
            Error = $errorMsg
            Method = "npm"
        }
    }
    
    Write-Host "  [OK] OpenClaw installed successfully" -ForegroundColor Green
    Write-Host "  Version: $version" -ForegroundColor DarkGray
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "OpenClaw installed, version: $version" -Level "Info"
    }
    
    return @{
        Success = $true
        AlreadyInstalled = $false
        Version = $version
        Method = "npm"
    }
}

function Install-OpenClawFromWindowsDownload {
    <#
    .SYNOPSIS
        Downloads OpenClaw via Windows and installs in WSL2 using shared folder
    .DESCRIPTION
        Workaround for WSL2 SSL bug (GitHub #12340). Uses the shared data folder
        that's mounted in WSL to transfer packages downloaded from Windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$SharedFolderWindows,
        
        [Parameter()]
        [string]$SharedFolderLinux = "/mnt/openclaw-data"
    )
    
    # Find the shared folder if not provided
    if (-not $SharedFolderWindows) {
        # Try to find it relative to the module location
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $dataFolder = Join-Path $moduleRoot ".local\data"
        if (Test-Path $dataFolder) {
            $SharedFolderWindows = $dataFolder
        } else {
            # Fall back to temp directory with /mnt/c access
            $SharedFolderWindows = Join-Path $env:TEMP "openclaw-shared"
            $SharedFolderLinux = $SharedFolderWindows -replace '\\', '/'
            if ($SharedFolderLinux -match '^([A-Za-z]):(.*)$') {
                $SharedFolderLinux = "/mnt/$($Matches[1].ToLower())$($Matches[2])"
            }
        }
    }
    
    $downloadDir = Join-Path $SharedFolderWindows "npm-download"
    
    # Clean up any previous download attempt
    if (Test-Path $downloadDir) {
        Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    
    try {
        # Step 1: Check if Windows npm is available
        $npmPath = Get-Command npm -ErrorAction SilentlyContinue
        
        if (-not $npmPath) {
            Write-Host "  [!] Windows Node.js/npm not found" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  +-- Windows npm Required for Fallback -----------------------" -ForegroundColor Yellow
            Write-Host "  |  To use the Windows download fallback, install Node.js on Windows:" -ForegroundColor Yellow
            Write-Host "  |    https://nodejs.org/" -ForegroundColor White
            Write-Host "  |" -ForegroundColor Yellow
            Write-Host "  |  After installing, restart this installer." -ForegroundColor Yellow
            Write-Host "  +------------------------------------------------------------" -ForegroundColor Yellow
            Write-Host ""
            return $false
        }
        
        # Step 2: Download openclaw and dependencies using Windows npm
        Write-Host "  Using Windows npm to download (bypasses WSL2 network bug)..." -ForegroundColor Cyan
        
        Push-Location $downloadDir
        try {
            # Create package.json to install openclaw
            $packageJson = @{
                name = "openclaw-installer"
                version = "1.0.0"
                private = $true
                dependencies = @{
                    openclaw = "latest"
                }
            } | ConvertTo-Json -Depth 10
            
            $packageJson | Set-Content -Path (Join-Path $downloadDir "package.json") -Encoding UTF8
            
            # Run npm install (Windows network, no SSL issues)
            Write-Host "  Downloading package (this may take 1-2 minutes)..." -ForegroundColor DarkGray
            $npmOutput = & npm install 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [X] Windows npm download failed" -ForegroundColor Red
                if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
                    Write-ErrorLog -Message "Windows npm install failed: $npmOutput"
                }
                return $false
            }
            
            Write-Host "  [OK] Package downloaded via Windows" -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
        
        # Step 3: Install from local files in WSL
        Write-Host "  Transferring to WSL and installing..." -ForegroundColor DarkGray
        
        $wslDownloadPath = "$SharedFolderLinux/npm-download"
        
        # Copy to npm-global and create symlinks
        $installScript = @"
set -e
cd '$wslDownloadPath'

# Verify the package exists
if [ ! -d "node_modules/openclaw" ]; then
    echo "ERROR: openclaw not found in node_modules"
    exit 1
fi

# Create npm-global structure
mkdir -p ~/.npm-global/lib/node_modules
mkdir -p ~/.npm-global/bin

# Copy the entire openclaw package with ALL dependencies
# The dependencies are nested in node_modules/openclaw/node_modules or at the top level
cp -r node_modules/openclaw ~/.npm-global/lib/node_modules/

# Copy all top-level dependencies that openclaw needs
for dep in node_modules/*; do
    depname=\$(basename "\$dep")
    if [ "\$depname" != "openclaw" ] && [ -d "\$dep" ]; then
        cp -r "\$dep" ~/.npm-global/lib/node_modules/
    fi
done

# Find and link the binary
if [ -f ~/.npm-global/lib/node_modules/openclaw/bin/openclaw.js ]; then
    ln -sf ../lib/node_modules/openclaw/bin/openclaw.js ~/.npm-global/bin/openclaw
    chmod +x ~/.npm-global/lib/node_modules/openclaw/bin/openclaw.js
elif [ -f ~/.npm-global/lib/node_modules/openclaw/dist/bin/openclaw.js ]; then
    ln -sf ../lib/node_modules/openclaw/dist/bin/openclaw.js ~/.npm-global/bin/openclaw
    chmod +x ~/.npm-global/lib/node_modules/openclaw/dist/bin/openclaw.js
else
    # Search for any bin entry
    BIN_FILE=\$(find ~/.npm-global/lib/node_modules/openclaw -name '*.js' -path '*/bin/*' | head -1)
    if [ -n "\$BIN_FILE" ]; then
        ln -sf "\$BIN_FILE" ~/.npm-global/bin/openclaw
        chmod +x "\$BIN_FILE"
    else
        echo "ERROR: Could not find openclaw binary"
        exit 1
    fi
fi

echo "SUCCESS"
"@
        
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $installScript -User $Username -PassThru -Silent
        
        if ($result.Output -match "SUCCESS") {
            Write-Host "  [OK] OpenClaw installed from shared folder" -ForegroundColor Green
            return $true
        }
        
        # Fallback: try npm install from local path
        Write-Host "  [!] Direct copy failed, trying npm install from local..." -ForegroundColor Yellow
        
        $npmLocalInstall = "cd '$wslDownloadPath' && npm install -g ./node_modules/openclaw 2>&1"
        $localResult = Invoke-WSLCommand -DistroName $DistroName -Command $npmLocalInstall -User $Username -PassThru -Silent
        
        if ($localResult.ExitCode -eq 0) {
            Write-Host "  [OK] OpenClaw installed via local npm" -ForegroundColor Green
            return $true
        }
        
        Write-Host "  [X] Local install failed: $($localResult.Output)" -ForegroundColor Red
        return $false
    }
    catch {
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message "Windows download fallback failed: $_"
        }
        Write-Host "  [X] Download failed: $_" -ForegroundColor Red
        return $false
    }
    finally {
        # Clean up download directory
        if (Test-Path $downloadDir) {
            Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OpenClawNpmInstalled {
    <#
    .SYNOPSIS
        Checks if OpenClaw command is available (installed via npm or otherwise)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$User
    )
    
    # Check with npm-global bin in PATH (where official installer puts it)
    $cmd = 'PATH=~/.npm-global/bin:$PATH command -v openclaw >/dev/null 2>&1 && echo yes || echo no'
    $result = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $User) -Default "no"
    
    return $result -eq 'yes'
}

function Test-OpenClawConfigured {
    <#
    .SYNOPSIS
        Checks if OpenClaw has been configured (setup wizard completed)
    .DESCRIPTION
        Checks for existence of ~/.openclaw/openclaw.json in WSL
    .OUTPUTS
        Boolean indicating whether config exists
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$User = "openclaw"
    )
    
    $cmd = 'test -f ~/.openclaw/openclaw.json && echo yes || echo no'
    $result = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $cmd -User $User) -Default "no"
    
    return $result -eq 'yes'
}

function Set-OpenClawGatewayToken {
    <#
    .SYNOPSIS
        Configures a persistent gateway token in OpenClaw config
    .DESCRIPTION
        Sets a fixed token in ~/.openclaw/openclaw.json so the launcher
        can always use the same token URL. This ensures the browser
        auto-opens with the correct authentication token.
    .PARAMETER Token
        The token to set. Defaults to 'openclaw-local-token' which matches
        the hardcoded value in the launcher script.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$Token = "openclaw-local-token",
        
        [Parameter()]
        [int]$GatewayPort = 18789
    )
    
    Write-Host "  Configuring gateway authentication token..." -ForegroundColor Cyan
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Configuring gateway token for $Username on $DistroName" -Level "Info"
    }
    
    # Ensure .openclaw directory exists
    $mkdirCmd = 'mkdir -p ~/.openclaw'
    Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -User $Username -Silent | Out-Null
    
    # Check if config file exists
    $configExists = Test-OpenClawConfigured -DistroName $DistroName -User $Username
    
    if ($configExists) {
        # Update existing config using jq (already installed as dependency)
        # Set gateway.auth.mode and gateway.auth.token, also set gateway.port
        $updateCmd = @"
jq '.gateway.auth.mode = "token" | .gateway.auth.token = "$Token" | .gateway.port = $GatewayPort' ~/.openclaw/openclaw.json > ~/.openclaw/openclaw.json.tmp && mv ~/.openclaw/openclaw.json.tmp ~/.openclaw/openclaw.json
"@
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $updateCmd -User $Username -PassThru -Silent
        
        if ($result.ExitCode -ne 0) {
            # jq might not be available or config might be malformed, try Python fallback
            Write-Host "  Using Python to update config..." -ForegroundColor DarkGray
            $pythonCmd = @"
python3 -c "
import json
import os
config_path = os.path.expanduser('~/.openclaw/openclaw.json')
with open(config_path, 'r') as f:
    config = json.load(f)
if 'gateway' not in config:
    config['gateway'] = {}
if 'auth' not in config['gateway']:
    config['gateway']['auth'] = {}
config['gateway']['auth']['mode'] = 'token'
config['gateway']['auth']['token'] = '$Token'
config['gateway']['port'] = $GatewayPort
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
print('done')
"
"@
            $pyResult = Invoke-WSLCommand -DistroName $DistroName -Command $pythonCmd -User $Username -PassThru -Silent
            if ($pyResult.ExitCode -ne 0) {
                Write-Host "  [WARNING] Could not update config, token may need manual setup" -ForegroundColor Yellow
                return $false
            }
        }
    } else {
        # Create new minimal config with gateway settings
        $configContent = @"
{
  "gateway": {
    "port": $GatewayPort,
    "auth": {
      "mode": "token",
      "token": "$Token"
    }
  }
}
"@
        # Use base64 to safely transfer content
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($configContent)
        $contentBase64 = [Convert]::ToBase64String($contentBytes)
        $createCmd = "echo '$contentBase64' | base64 -d > ~/.openclaw/openclaw.json"
        
        $result = Invoke-WSLCommand -DistroName $DistroName -Command $createCmd -User $Username -PassThru -Silent
        
        if ($result.ExitCode -ne 0) {
            Write-Host "  [WARNING] Could not create config file" -ForegroundColor Yellow
            return $false
        }
    }
    
    Write-Host "  [OK] Gateway token configured" -ForegroundColor Green
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Gateway token set to: $Token (port: $GatewayPort)" -Level "Debug"
    }
    
    return $true
}

function Start-OpenClawSetup {
    <#
    .SYNOPSIS
        Launches OpenClaw onboarding wizard after installation
    .DESCRIPTION
        Runs 'openclaw onboard' interactively to guide the user through
        first-time setup of their AI assistant. After onboarding completes,
        configures a persistent gateway token for the launcher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$GatewayToken = "openclaw-local-token",
        
        [Parameter()]
        [int]$GatewayPort = 18789
    )
    
    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host "       OPENCLAW ONBOARDING" -ForegroundColor Cyan  
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  OpenClaw has been installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  The onboarding wizard will now guide you through" -ForegroundColor Yellow
    Write-Host "  configuring your AI assistant." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to start onboarding..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Starting OpenClaw onboarding for user $Username on $DistroName" -Level "Info"
    }
    
    try {
        # Launch openclaw onboard interactively
        Write-Host "  Starting onboarding wizard..." -ForegroundColor DarkGray
        Write-Host ""
        
        & wsl.exe -d $DistroName -u $Username -- bash -lc "openclaw onboard"
        $exitCode = $LASTEXITCODE
        
        Write-Host ""
        
        if ($exitCode -eq 0) {
            Write-Host "  [OK] Onboarding completed!" -ForegroundColor Green
            Write-Host ""
            
            # Configure persistent gateway token for launcher auto-authentication
            $null = Set-OpenClawGatewayToken `
                -DistroName $DistroName `
                -Username $Username `
                -Token $GatewayToken `
                -GatewayPort $GatewayPort
            
            # Disable the auto-start systemd service that onboarding enables
            # We run gateway directly via OpenClaw.bat for better control and output
            Write-Host "  Disabling auto-start gateway service..." -ForegroundColor DarkGray
            $disableResult = & wsl.exe -d $DistroName -u $Username -- bash -lc "
                systemctl --user stop openclaw-gateway.service 2>/dev/null
                systemctl --user disable openclaw-gateway.service 2>/dev/null
                echo 'disabled'
            "
            if ($disableResult -match 'disabled') {
                Write-Host "  [OK] Gateway will start via OpenClaw.bat launcher" -ForegroundColor Green
            }
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "OpenClaw onboarding completed successfully" -Level "Info"
            }
        } else {
            Write-Host "  [!] Onboarding exited with code: $exitCode" -ForegroundColor Yellow
            Write-Host "  You can run onboarding later with:" -ForegroundColor DarkGray
            Write-Host "    wsl -d $DistroName -- openclaw onboard" -ForegroundColor White
            Write-Host ""
        }
    }
    catch {
        Write-Host ""
        Write-Host "  [!] Failed to start onboarding: $_" -ForegroundColor Yellow
        Write-Host "  You can run onboarding manually with:" -ForegroundColor DarkGray
        Write-Host "    wsl -d $DistroName -- openclaw onboard" -ForegroundColor White
        Write-Host ""
        
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message "Failed to start OpenClaw onboarding: $_"
        }
    }
}

function Start-OpenClawOnboard {
    <#
    .SYNOPSIS
        Launches the OpenClaw onboarding wizard
    .DESCRIPTION
        Starts openclaw onboard in an interactive WSL session.
        This is the full onboarding experience for first-time setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host "       OPENCLAW ONBOARDING" -ForegroundColor Cyan  
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  The OpenClaw onboarding wizard will guide you through" -ForegroundColor Yellow
    Write-Host "  the complete initial setup process." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Starting OpenClaw onboarding for user $Username on $DistroName" -Level "Info"
    }
    
    try {
        Write-Host "  Starting onboarding wizard..." -ForegroundColor DarkGray
        Write-Host ""
        
        # Use direct command execution to preserve TTY
        & wsl.exe -d $DistroName -u $Username -- bash -lc "openclaw onboard"
        $exitCode = $LASTEXITCODE
        
        Write-Host ""
        
        if ($exitCode -eq 0) {
            Write-Host "  [OK] OpenClaw onboarding completed!" -ForegroundColor Green
            Write-Host ""
            
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "OpenClaw onboarding completed successfully" -Level "Info"
            }
        } else {
            Write-Host "  [!] Onboarding exited with code: $exitCode" -ForegroundColor Yellow
            Write-Host "  You can run onboarding later with:" -ForegroundColor DarkGray
            Write-Host "    wsl -d $DistroName -- openclaw onboard" -ForegroundColor White
            Write-Host ""
        }
    }
    catch {
        Write-Host ""
        Write-Host "  [!] Failed to start onboarding: $_" -ForegroundColor Yellow
        Write-Host "  You can run onboarding manually with:" -ForegroundColor DarkGray
        Write-Host "    wsl -d $DistroName -- openclaw onboard" -ForegroundColor White
        Write-Host ""
        
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog -Message "Failed to start OpenClaw onboarding: $_"
        }
    }
}

#endregion

#region OpenClaw Installation

function Install-OpenClaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$RepositoryUrl = "https://github.com/openclaw/openclaw.git",
        
        [Parameter()]
        [string]$Branch = "main",
        
        [Parameter()]
        [string]$InstallPath,
        
        [Parameter()]
        [switch]$UseVenv,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [ValidateSet("npm", "git", "local")]
        [string]$InstallMethod = "npm"
    )
    
    Write-Host ""
    Write-Host "  Installing OpenClaw..." -ForegroundColor Cyan
    
    # NPM Installation (default and recommended)
    if ($InstallMethod -eq "npm") {
        $npmResult = Install-OpenClawNpm -DistroName $DistroName -Username $Username -Force:$Force
        
        if ($npmResult.Success) {
            return @{
                Success = $true
                CloneSucceeded = $true
                Path = $null
                AlreadyInstalled = $npmResult.AlreadyInstalled
                Method = "npm"
                VenvPath = $null
            }
        } else {
            Write-Host "  [!] npm installation failed, offering alternatives..." -ForegroundColor Yellow
            # Fall through to interactive options
        }
    }
    
    # Determine install path for git/local methods
    if (-not $InstallPath) {
        $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
        $InstallPath = "$userHome/openclaw"
    }
    
    # Check if already exists (for git/local methods)
    if (Test-GitRepositoryExists -DistroName $DistroName -Path $InstallPath -User $Username) {
        if ($Force) {
            Write-Host "  Removing existing installation..." -ForegroundColor DarkGray
            $rmCmd = "rm -rf '$InstallPath'"
            Invoke-WSLCommand -DistroName $DistroName -Command $rmCmd -User $Username -Silent | Out-Null
        } else {
            Write-Host "  OpenClaw already installed at: $InstallPath" -ForegroundColor Yellow
            Write-Host "  Use -Force to reinstall" -ForegroundColor DarkGray
            return @{
                Success = $true
                CloneSucceeded = $true
                Path = $InstallPath
                AlreadyInstalled = $true
            }
        }
    }
    
    # Ask user for installation source
    Write-Host ""
    Write-Host "  Select OpenClaw installation method:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1] Install via npm (recommended)" -ForegroundColor White
    Write-Host "        npm i -g openclaw" -ForegroundColor DarkGray
    Write-Host "    [2] Clone from git repository" -ForegroundColor White
    Write-Host "    [3] Copy from local Windows folder" -ForegroundColor White
    Write-Host "    [4] Skip (install later)" -ForegroundColor DarkGray
    Write-Host ""
    
    $sourceChoice = Read-Host "  Select option [1-4]"
    
    $cloneSucceeded = $false
    $method = "none"
    
    if ($sourceChoice -eq "1") {
        # npm install
        $npmResult = Install-OpenClawNpm -DistroName $DistroName -Username $Username -Force:$Force
        
        if ($npmResult.Success) {
            return @{
                Success = $true
                CloneSucceeded = $true
                Path = $null
                AlreadyInstalled = $npmResult.AlreadyInstalled
                Method = "npm"
                VenvPath = $null
            }
        }
    }
    elseif ($sourceChoice -eq "2") {
        # Git clone
        Write-Host ""
        $inputUrl = Read-Host "  Repository URL [$RepositoryUrl]"
        if (-not [string]::IsNullOrWhiteSpace($inputUrl)) {
            $RepositoryUrl = $inputUrl
        }
        
        Write-Host ""
        Write-Host "  Cloning from: $RepositoryUrl" -ForegroundColor DarkGray
        
        try {
            Clone-GitRepository -DistroName $DistroName `
                -RepositoryUrl $RepositoryUrl `
                -DestinationPath $InstallPath `
                -Branch $Branch `
                -User $Username
            
            $cloneSucceeded = $true
            $method = "git"
        }
        catch {
            Write-Host ""
            Write-Host "  [X] Clone failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
        }
    }
    elseif ($sourceChoice -eq "3") {
        # Local copy
        Write-Host ""
        $localPath = Read-Host "  Enter Windows path to OpenClaw source"
        
        if ([string]::IsNullOrWhiteSpace($localPath)) {
            Write-Host "  [!] No path provided." -ForegroundColor Yellow
        }
        elseif (-not (Test-Path $localPath)) {
            Write-Host "  [X] Path not found: $localPath" -ForegroundColor Red
        }
        else {
            $cloneSucceeded = Copy-OpenClawFromLocal `
                -DistroName $DistroName `
                -Username $Username `
                -SourcePath $localPath `
                -InstallPath $InstallPath
            if ($cloneSucceeded) {
                $method = "local"
            }
        }
    }
    else {
        Write-Host "  Skipping OpenClaw code installation." -ForegroundColor DarkGray
    }
    
    # Install requirements if clone/copy succeeded
    if ($cloneSucceeded) {
        $requirementsPath = "$InstallPath/requirements.txt"
        $venvPath = if ($UseVenv) { "$InstallPath/.venv" } else { $null }
        
        try {
            Install-PythonRequirements -DistroName $DistroName `
                -RequirementsPath $requirementsPath `
                -User $Username `
                -UseVenv:$UseVenv `
                -VenvPath $venvPath
        }
        catch {
            Write-Host "  [!] Could not install requirements: $_" -ForegroundColor Yellow
        }
        
        Write-Host "  [OK] OpenClaw installed at: $InstallPath" -ForegroundColor Green
    }
    else {
        if ($sourceChoice -ne "4") {
            Write-Host "  [!] OpenClaw code not installed." -ForegroundColor Yellow
        }
        
        # Create the directory anyway for future use
        $mkdirCmd = "mkdir -p '$InstallPath'"
        Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -User $Username -Silent | Out-Null
    }
    
    return @{
        Success = $true
        CloneSucceeded = $cloneSucceeded
        Path = $InstallPath
        AlreadyInstalled = $false
        Method = $method
        VenvPath = if ($UseVenv) { "$InstallPath/.venv" } else { $null }
    }
}

function Copy-OpenClawFromLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    
    Write-Host "  Copying from: $SourcePath" -ForegroundColor DarkGray
    
    # Convert Windows path to WSL path
    $wslPath = $SourcePath -replace '\\', '/'
    if ($wslPath -match '^([A-Za-z]):(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        $wslSourcePath = "/mnt/$drive$rest"
    }
    else {
        $wslSourcePath = $wslPath
    }
    
    # Create target directory
    $mkdirCmd = "mkdir -p '$InstallPath'"
    Invoke-WSLCommand -DistroName $DistroName -Command $mkdirCmd -User $Username -Silent | Out-Null
    
    # Copy files
    $copyCmd = "cp -r '$wslSourcePath/.' '$InstallPath/'"
    $result = Invoke-WSLCommand -DistroName $DistroName -Command $copyCmd -User $Username -PassThru
    
    if ($result.ExitCode -ne 0) {
        Write-Host "  [X] Failed to copy files" -ForegroundColor Red
        return $false
    }
    
    # Fix ownership
    $chownCmd = "chown -R ${Username}:${Username} '$InstallPath'"
    Invoke-WSLCommand -DistroName $DistroName -Command $chownCmd -AsRoot -Silent | Out-Null
    
    Write-Host "  [OK] Files copied" -ForegroundColor Green
    return $true
}

function Set-OpenClawDataDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter(Mandatory)]
        [string]$OpenClawPath,
        
        [Parameter(Mandatory)]
        [string]$DataPath
    )
    
    Write-Host "  Configuring OpenClaw data directory: $DataPath" -ForegroundColor Cyan
    
    # Create data directory symlink or configuration
    # This depends on how OpenClaw handles data directory configuration
    
    # Option 1: Create .env file if OpenClaw uses environment variables
    $envFile = "$OpenClawPath/.env"
    $envContent = "OPENCLAW_DATA_DIR=$DataPath"
    
    $cmd = "echo '$envContent' > '$envFile'"
    Invoke-WSLCommand -DistroName $DistroName -Command $cmd -User $Username -Silent | Out-Null
    
    # Option 2: Create symlink to data directory
    $dataLinkPath = "$OpenClawPath/data"
    $linkCmd = "if [ ! -L '$dataLinkPath' ] && [ ! -d '$dataLinkPath' ]; then ln -s '$DataPath' '$dataLinkPath'; fi"
    Invoke-WSLCommand -DistroName $DistroName -Command $linkCmd -User $Username -Silent | Out-Null
    
    Write-Host "  [OK] Data directory configured" -ForegroundColor Green
    return $true
}

function Test-OpenClawInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Username,
        
        [Parameter()]
        [string]$InstallPath
    )
    
    # First check if installed via npm
    if (Test-OpenClawNpmInstalled -DistroName $DistroName -User $Username) {
        return $true
    }
    
    # Then check for git repository installation
    if (-not $InstallPath) {
        $userHome = Get-LinuxUserHome -DistroName $DistroName -Username $Username
        $InstallPath = "$userHome/openclaw"
    }
    
    return Test-GitRepositoryExists -DistroName $DistroName -Path $InstallPath -User $Username
}

function Get-OpenClawMainScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$InstallPath,
        
        [Parameter()]
        [string]$User
    )
    
    # Look for common entry points
    $candidates = @(
        "openclaw.py",
        "main.py",
        "app.py",
        "run.py",
        "__main__.py"
    )
    
    foreach ($candidate in $candidates) {
        $checkCmd = "test -f '$InstallPath/$candidate' && echo 'yes' || echo 'no'"
        $exists = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $checkCmd -User $User) -Default "no"
        
        if ($exists -eq 'yes') {
            return $candidate
        }
    }
    
    # Check for module with __main__.py
    $moduleCheck = "test -f '$InstallPath/openclaw/__main__.py' && echo 'yes' || echo 'no'"
    $moduleExists = Get-SafeTrimmedString (Invoke-WSLCommandWithOutput -DistroName $DistroName -Command $moduleCheck -User $User) -Default "no"
    
    if ($moduleExists -eq 'yes') {
        return "-m openclaw"
    }
    
    return "openclaw.py"  # Default fallback
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Package Management
    'Update-AptPackages',
    'Install-AptPackages',
    'Test-PackageInstalled',
    'Get-RequiredPackages',
    'Install-RequiredPackages',
    'Switch-AptMirror',

    # Git
    'Test-GitRepositoryExists',
    'Clone-GitRepository',
    'Update-GitRepository',

    # Python
    'Install-PythonRequirements',
    'Test-PythonModuleInstalled',

    # Node.js/npm
    'Install-NodeJS',
    'Initialize-NpmUserInstall',
    'Test-NpmConnectivity',
    'Clear-NpmCache',
    'Install-OpenClawNpm',
    'Install-OpenClawFromWindowsDownload',
    'Test-OpenClawNpmInstalled',
    'Test-OpenClawConfigured',
    'Set-OpenClawGatewayToken',
    'Start-OpenClawSetup',
    'Start-OpenClawOnboard',

    # Homebrew
    'Test-HomebrewInstalled',
    'Test-BuildToolsWorking',
    'Install-Homebrew',
    'Get-WSLArchitecture',
    'Set-HomebrewEnvironment',

    # Systemd
    'Enable-SystemdUserServices',

    # OpenClaw
    'Install-OpenClaw',
    'Copy-OpenClawFromLocal',
    'Set-OpenClawDataDirectory',
    'Test-OpenClawInstalled',
    'Get-OpenClawMainScript'
)
