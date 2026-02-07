#Requires -Version 5.1
<#
.SYNOPSIS
    Path Relocation Detection and Repair for OpenClaw WSL
.DESCRIPTION
    Detects when the OpenClaw folder has been moved or when a .local folder
    is copied fresh, and repairs/imports WSL registration accordingly.
    
    Handles three scenarios:
    - Fresh import: .local/wsl exists but WSL not registered
    - Path relocation: WSL registered at wrong path
    - Already correct: No action needed
#>

#region Detection Functions

function Test-WSLImportNeeded {
    <#
    .SYNOPSIS
        Checks if WSL distribution needs to be imported (fresh .local copy)
    .DESCRIPTION
        Returns $true if vhdx exists but distribution is not registered
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $vhdxPath = Join-Path $CurrentPath ".local\wsl\ext4.vhdx"
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    
    # No vhdx = nothing to import
    if (-not (Test-Path $vhdxPath)) {
        return $false
    }
    
    # Get distro name from state file or use default
    $distroName = "openclaw"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($state.DistroName) {
                $distroName = $state.DistroName
            }
        }
        catch { } # Ignore corrupt/unreadable state file; fall back to default name
    }
    
    # Check if distribution is registered
    $isRegistered = Test-WSLDistributionRegistered -DistroName $distroName
    
    return -not $isRegistered
}

function Test-PathRelocationNeeded {
    <#
    .SYNOPSIS
        Checks if the OpenClaw folder has been moved and needs path updates
    .OUTPUTS
        Boolean - $true if relocation repair is needed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    
    # No state file = no previous installation = no relocation needed
    if (-not (Test-Path $stateFile)) {
        return $false
    }
    
    try {
        $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        
        # Check if stored path differs from current path
        if ($state.WindowsInstallPath -and $state.WindowsInstallPath -ne $CurrentPath) {
            # Verify we actually have WSL data to relocate
            $vhdxPath = Join-Path $CurrentPath ".local\wsl\ext4.vhdx"
            if (Test-Path $vhdxPath) {
                return $true
            }
        }
    }
    catch {
        # If we can't read the state file, no relocation needed
        return $false
    }
    
    return $false
}

function Get-PathRelocationInfo {
    <#
    .SYNOPSIS
        Gets detailed information about the path relocation
    .OUTPUTS
        PSCustomObject with OldPath, NewPath, DistroName, and affected paths
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    
    $oldPath = $state.WindowsInstallPath
    $newPath = $CurrentPath
    
    # Calculate what paths need updating
    $info = [PSCustomObject]@{
        OldPath           = $oldPath
        NewPath           = $newPath
        DistroName        = $state.DistroName
        LinuxUsername     = $state.LinuxUsername
        OldVhdxPath       = Join-Path $oldPath ".local\wsl\ext4.vhdx"
        NewVhdxPath       = Join-Path $newPath ".local\wsl\ext4.vhdx"
        OldLocalPath      = $state.LocalPath
        NewLocalPath      = Join-Path $newPath ".local"
        OldWSLPath        = $state.WSLPath
        NewWSLPath        = Join-Path $newPath ".local\wsl"
        OldDataPath       = $state.DataFolderPath
        NewDataPath       = Join-Path $newPath ".local\data"
        OldScriptsPath    = if ($state.LaunchScriptPath) { Split-Path $state.LaunchScriptPath -Parent } else { $null }
        NewScriptsPath    = Join-Path $newPath ".local\scripts"
        State             = $state
        VhdxExists        = Test-Path (Join-Path $newPath ".local\wsl\ext4.vhdx")
        WSLRegistered     = $false
        RegistryPathMatch = $false
    }
    
    # Check WSL registration status
    if ($info.DistroName) {
        $info.WSLRegistered = Test-WSLDistributionRegistered -DistroName $info.DistroName
        
        if ($info.WSLRegistered) {
            # Check if registry path matches new location
            $registryPath = Get-WSLDistributionRegistryPath -DistroName $info.DistroName
            $info.RegistryPathMatch = ($registryPath -eq $info.NewWSLPath)
        }
    }
    
    return $info
}

function Test-WSLDistributionRegistered {
    <#
    .SYNOPSIS
        Checks if a WSL distribution is registered (exists in registry)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    try {
        $output = wsl.exe -l -q 2>&1
        $outputStr = ($output | Out-String) -replace "`0", ""
        $distros = $outputStr -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        return $distros -contains $DistroName
    }
    catch {
        return $false
    }
}

function Get-WSLDistributionRegistryPath {
    <#
    .SYNOPSIS
        Gets the BasePath for a WSL distribution from the registry
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    try {
        $lxssPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
        
        if (-not (Test-Path $lxssPath)) {
            return $null
        }
        
        $distroKey = Get-ChildItem $lxssPath | Where-Object {
            $props = Get-ItemProperty $_.PSPath
            $props.DistributionName -eq $DistroName
        } | Select-Object -First 1
        
        if ($distroKey) {
            $props = Get-ItemProperty $distroKey.PSPath
            return $props.BasePath
        }
    }
    catch {
        return $null
    }
    
    return $null
}

#endregion

#region Repair Functions

function Repair-RelocatedPaths {
    <#
    .SYNOPSIS
        Main function to repair all paths after folder relocation
    .DESCRIPTION
        Re-registers WSL at new path if needed, updates state.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath,
        
        [Parameter()]
        [switch]$Force
    )
    
    $info = Get-PathRelocationInfo -CurrentPath $CurrentPath
    
    if (-not $info.VhdxExists) {
        throw "Cannot repair: WSL disk not found at $($info.NewVhdxPath)"
    }
    
    Write-Host ""
    Write-Host "  Repairing relocated installation..." -ForegroundColor Cyan
    Write-Host ""
    
    # Check if registry already points to correct location
    if ($info.WSLRegistered -and $info.RegistryPathMatch) {
        # WSL is already registered at the correct location
        # Only need to update state.json
        Write-Host "  [1/2] WSL already registered at correct location" -ForegroundColor Green
        Write-Host "  [2/2] Updating configuration files..." -ForegroundColor White
        Update-StateFilePaths -CurrentPath $CurrentPath -Info $info
        Write-Host "        Done" -ForegroundColor Green
    }
    else {
        # Need to re-register WSL at new location
        # Step 1: Unregister if registered elsewhere (but DON'T use --unregister which deletes vhdx)
        if ($info.WSLRegistered -and -not $info.RegistryPathMatch) {
            Write-Host "  [1/3] Updating WSL registration..." -ForegroundColor White
            
            # Shutdown ALL WSL to ensure clean state and release vhdx lock
            $null = wsl.exe --shutdown 2>&1
            Start-Sleep -Seconds 2
            
            # Use registry manipulation instead of --unregister to preserve vhdx
            $removed = Remove-WSLDistributionRegistration -DistroName $info.DistroName
            if ($removed) {
                Write-Host "        Done" -ForegroundColor Green
            }
            else {
                Write-Host "        Warning: Could not remove old registration" -ForegroundColor Yellow
            }
            
            # Extra wait to ensure vhdx is fully released
            Start-Sleep -Seconds 1
        }
        elseif (-not $info.WSLRegistered) {
            Write-Host "  [1/3] WSL distribution not registered (needs import)" -ForegroundColor White
            # Still shutdown to ensure no locks
            $null = wsl.exe --shutdown 2>&1
            Start-Sleep -Seconds 1
        }
        else {
            Write-Host "  [1/3] Preparing WSL registration..." -ForegroundColor White
        }
        
        # Step 2: Register at new location
        Write-Host "  [2/3] Registering WSL at new location..." -ForegroundColor White
        
        $importResult = Start-Process -FilePath "wsl.exe" `
            -ArgumentList @("--import-in-place", $info.DistroName, $info.NewVhdxPath) `
            -Wait -PassThru -NoNewWindow
        
        if ($importResult.ExitCode -ne 0) {
            throw "Failed to register WSL distribution at new location (exit code: $($importResult.ExitCode))"
        }
        Write-Host "        Done" -ForegroundColor Green
        
        # Step 3: Update state.json
        Write-Host "  [3/3] Updating configuration files..." -ForegroundColor White
        Update-StateFilePaths -CurrentPath $CurrentPath -Info $info
        Write-Host "        Done" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "  [OK] Path relocation repair complete!" -ForegroundColor Green
    Write-Host ""
    
    return @{
        Success  = $true
        OldPath  = $info.OldPath
        NewPath  = $info.NewPath
    }
}

function Import-WSLFromLocal {
    <#
    .SYNOPSIS
        Imports WSL distribution from .local/wsl folder (fresh copy scenario)
    .DESCRIPTION
        When a .local folder is copied to a new system, this function
        registers the vhdx with WSL using --import-in-place
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $vhdxPath = Join-Path $CurrentPath ".local\wsl\ext4.vhdx"
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    
    if (-not (Test-Path $vhdxPath)) {
        throw "Cannot import: WSL disk not found at $vhdxPath"
    }
    
    # Get distro name from state file or use default
    $distroName = "openclaw"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($state.DistroName) {
                $distroName = $state.DistroName
            }
        }
        catch {
            # Ignore corrupt/unreadable state file; fall back to default name
        }
    }
    
    Write-Host ""
    Write-Host "  Importing WSL distribution..." -ForegroundColor Cyan
    Write-Host ""
    
    # Shutdown WSL to ensure clean state
    Write-Host "  [1/3] Preparing WSL environment..." -ForegroundColor White
    $null = wsl.exe --shutdown 2>&1
    Start-Sleep -Seconds 2
    Write-Host "        Done" -ForegroundColor Green
    
    # Import the distribution
    Write-Host "  [2/3] Registering distribution '$distroName'..." -ForegroundColor White
    $importResult = Start-Process -FilePath "wsl.exe" `
        -ArgumentList @("--import-in-place", $distroName, $vhdxPath) `
        -Wait -PassThru -NoNewWindow
    
    if ($importResult.ExitCode -ne 0) {
        throw "Failed to import WSL distribution (exit code: $($importResult.ExitCode))"
    }
    Write-Host "        Done" -ForegroundColor Green
    
    # Update state.json with current paths
    Write-Host "  [3/3] Updating configuration..." -ForegroundColor White
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            $state.WindowsInstallPath = $CurrentPath
            $state.LocalPath = Join-Path $CurrentPath ".local"
            $state.WSLPath = Join-Path $CurrentPath ".local\wsl"
            $state.DataFolderPath = Join-Path $CurrentPath ".local\data"
            if ($state.LaunchScriptPath) {
                $scriptName = Split-Path $state.LaunchScriptPath -Leaf
                $scriptsPath = Join-Path $CurrentPath ".local\scripts"
                $state.LaunchScriptPath = Join-Path $scriptsPath $scriptName
            }
            $state.LastModified = (Get-Date).ToString("o")
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
        }
        catch {
            Write-Warning "Could not update state.json: $($_.Exception.Message)"
        }
    }
    Write-Host "        Done" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "  [OK] WSL distribution imported successfully!" -ForegroundColor Green
    Write-Host ""
    
    return @{
        Success    = $true
        DistroName = $distroName
        VhdxPath   = $vhdxPath
    }
}

function Remove-WSLDistributionRegistration {
    <#
    .SYNOPSIS
        Removes WSL distribution registration from registry WITHOUT deleting the vhdx
    .DESCRIPTION
        Unlike wsl --unregister which deletes the vhdx file, this only removes the registry entry
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )
    
    try {
        $lxssPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
        
        if (-not (Test-Path $lxssPath)) {
            return $false
        }
        
        $distroKey = Get-ChildItem $lxssPath | Where-Object {
            $props = Get-ItemProperty $_.PSPath
            $props.DistributionName -eq $DistroName
        } | Select-Object -First 1
        
        if ($distroKey) {
            Remove-Item $distroKey.PSPath -Recurse -Force
            return $true
        }
        
        return $false
    }
    catch {
        Write-Warning "Failed to remove registry entry: $($_.Exception.Message)"
        return $false
    }
}

function Update-StateFilePaths {
    <#
    .SYNOPSIS
        Updates all paths in state.json to reflect new location
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$Info
    )
    
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    
    # Update all Windows paths
    $state.WindowsInstallPath = $Info.NewPath
    $state.LocalPath = $Info.NewLocalPath
    $state.WSLPath = $Info.NewWSLPath
    $state.DataFolderPath = $Info.NewDataPath
    
    # Update launch script path if present
    if ($state.LaunchScriptPath) {
        $scriptName = Split-Path $state.LaunchScriptPath -Leaf
        $state.LaunchScriptPath = Join-Path $Info.NewScriptsPath $scriptName
    }
    
    # Update OpenClaw Windows path if present
    if ($state.OpenClawWindowsPath) {
        # Calculate relative position from old install path
        $relativePath = $state.OpenClawWindowsPath.Replace($Info.OldPath, "").TrimStart("\", "/")
        $state.OpenClawWindowsPath = Join-Path $Info.NewPath $relativePath
    }
    
    # Update last modified timestamp
    $state.LastModified = (Get-Date).ToString("o")
    
    # Save updated state
    $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
}

#endregion

#region UI Functions

function Show-PathRelocationPrompt {
    <#
    .SYNOPSIS
        Shows an interactive prompt for path relocation repair
    .OUTPUTS
        Boolean - $true if user chose to repair, $false to cancel
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $info = Get-PathRelocationInfo -CurrentPath $CurrentPath
    
    # Clear screen and show warning
    Clear-Host
    Write-Host ""
    Write-Host "  +=====================================================================+" -ForegroundColor Yellow
    Write-Host "  |              !  Installation Location Changed                       |" -ForegroundColor Yellow
    Write-Host "  +=====================================================================+" -ForegroundColor Yellow
    Write-Host "  |                                                                     |" -ForegroundColor Yellow
    Write-Host "  |  The OpenClaw folder has been moved to a new location.              |" -ForegroundColor Yellow
    Write-Host "  |  WSL needs to be updated to use the new path.                       |" -ForegroundColor Yellow
    Write-Host "  |                                                                     |" -ForegroundColor Yellow
    Write-Host "  |  Your data and settings will be preserved.                          |" -ForegroundColor Yellow
    Write-Host "  |                                                                     |" -ForegroundColor Yellow
    Write-Host "  +=====================================================================+" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Previous location:" -ForegroundColor White
    Write-Host "    $($info.OldPath)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Current location:" -ForegroundColor White
    Write-Host "    $($info.NewPath)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Distribution: " -ForegroundColor White -NoNewline
    Write-Host $info.DistroName -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ---------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [U] Update paths (recommended)" -ForegroundColor Green
    Write-Host "  [C] Cancel and exit" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Choice: " -ForegroundColor White -NoNewline
    
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $char = $key.Character.ToString().ToUpper()
        
        if ($char -eq "U") {
            Write-Host "Update" -ForegroundColor Green
            return $true
        }
        elseif ($char -eq "C" -or $key.VirtualKeyCode -eq 27) {
            # C or Escape
            Write-Host "Cancel" -ForegroundColor Yellow
            return $false
        }
    }
}

function Show-WSLImportPrompt {
    <#
    .SYNOPSIS
        Shows an interactive prompt for fresh WSL import
    .OUTPUTS
        Boolean - $true if user chose to import, $false to cancel
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath
    )
    
    $vhdxPath = Join-Path $CurrentPath ".local\wsl\ext4.vhdx"
    $stateFile = Join-Path $CurrentPath ".local\state.json"
    
    # Get distro name from state
    $distroName = "openclaw"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.DistroName) { $distroName = $state.DistroName }
        }
        catch {
            # Ignore corrupt/unreadable state file; fall back to default name
        }
    }
    
    # Get vhdx size
    $vhdxSize = if (Test-Path $vhdxPath) {
        $size = (Get-Item $vhdxPath).Length / 1GB
        "{0:N2} GB" -f $size
    } else { "Unknown" }
    
    Clear-Host
    Write-Host ""
    Write-Host "  +=====================================================================+" -ForegroundColor Cyan
    Write-Host "  |                   WSL Import Required                               |" -ForegroundColor Cyan
    Write-Host "  +=====================================================================+" -ForegroundColor Cyan
    Write-Host "  |                                                                     |" -ForegroundColor Cyan
    Write-Host "  |  A WSL disk image was found but is not registered.                  |" -ForegroundColor Cyan
    Write-Host "  |  This happens when you copy the .local folder to a new system.      |" -ForegroundColor Cyan
    Write-Host "  |                                                                     |" -ForegroundColor Cyan
    Write-Host "  |  Import will register the existing disk with WSL.                   |" -ForegroundColor Cyan
    Write-Host "  |                                                                     |" -ForegroundColor Cyan
    Write-Host "  +=====================================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Distribution: " -ForegroundColor White -NoNewline
    Write-Host $distroName -ForegroundColor Cyan
    Write-Host "  Disk size:    " -ForegroundColor White -NoNewline
    Write-Host $vhdxSize -ForegroundColor Cyan
    Write-Host "  Location:     " -ForegroundColor White -NoNewline
    Write-Host $CurrentPath -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ---------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [I] Import WSL distribution (recommended)" -ForegroundColor Green
    Write-Host "  [C] Cancel and exit" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Choice: " -ForegroundColor White -NoNewline
    
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $char = $key.Character.ToString().ToUpper()
        
        if ($char -eq "I") {
            Write-Host "Import" -ForegroundColor Green
            return $true
        }
        elseif ($char -eq "C" -or $key.VirtualKeyCode -eq 27) {
            Write-Host "Cancel" -ForegroundColor Yellow
            return $false
        }
    }
}

function Invoke-PathRelocationCheck {
    <#
    .SYNOPSIS
        Main entry point for path relocation check - call from Start.ps1/bat
    .DESCRIPTION
        Checks if relocation is needed, prompts user, and repairs if confirmed
    .OUTPUTS
        Boolean - $true if we should continue, $false if user cancelled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CurrentPath,
        
        [Parameter()]
        [switch]$Silent
    )
    
    # Scenario 1: Check if fresh import is needed (vhdx exists but not registered)
    if (Test-WSLImportNeeded -CurrentPath $CurrentPath) {
        $shouldImport = Show-WSLImportPrompt -CurrentPath $CurrentPath
        
        if (-not $shouldImport) {
            Write-Host ""
            Write-Host "  Import cancelled. OpenClaw cannot run without WSL." -ForegroundColor Yellow
            Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return $false
        }
        
        try {
            $result = Import-WSLFromLocal -CurrentPath $CurrentPath
            Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return $true
        }
        catch {
            Write-Host ""
            Write-Host "  [ERROR] Failed to import WSL: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return $false
        }
    }
    
    # Scenario 2: Check if path relocation is needed
    if (-not (Test-PathRelocationNeeded -CurrentPath $CurrentPath)) {
        return $true
    }
    
    # Show prompt and get user choice
    $shouldRepair = Show-PathRelocationPrompt -CurrentPath $CurrentPath
    
    if (-not $shouldRepair) {
        Write-Host ""
        Write-Host "  Path update cancelled. OpenClaw may not work correctly." -ForegroundColor Yellow
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $false
    }
    
    # Perform repair
    try {
        $result = Repair-RelocatedPaths -CurrentPath $CurrentPath
        
        Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        
        return $true
    }
    catch {
        Write-Host ""
        Write-Host "  [ERROR] Failed to repair paths: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $false
    }
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'Test-WSLImportNeeded',
    'Test-PathRelocationNeeded',
    'Get-PathRelocationInfo',
    'Test-WSLDistributionRegistered',
    'Get-WSLDistributionRegistryPath',
    'Import-WSLFromLocal',
    'Repair-RelocatedPaths',
    'Remove-WSLDistributionRegistration',
    'Update-StateFilePaths',
    'Show-WSLImportPrompt',
    'Show-PathRelocationPrompt',
    'Invoke-PathRelocationCheck'
)
