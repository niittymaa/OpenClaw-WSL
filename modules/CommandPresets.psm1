#Requires -Version 5.1
<#
.SYNOPSIS
    Command Presets Module for OpenClaw-WSL
.DESCRIPTION
    Provides functionality to load and execute command presets from configuration.
    Commands can be run in three modes:
    - sameWindow: Execute in current PowerShell session (interactive WSL)
    - newWindow: Open new CMD/WSL window and run command
    - editFirst: Pre-fill command in new window for user editing
#>

#region Configuration Loading

function Get-CommandPresets {
    <#
    .SYNOPSIS
        Loads command presets from configuration file
    .PARAMETER RepoRoot
        Root path of the repository
    .OUTPUTS
        PSCustomObject containing presets configuration
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )
    
    $presetsPath = Join-Path $RepoRoot "config\command-presets.json"
    
    if (-not (Test-Path $presetsPath)) {
        Write-Warning "Command presets file not found: $presetsPath"
        return $null
    }
    
    try {
        $config = Get-Content $presetsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $config
    }
    catch {
        Write-Warning "Failed to parse command presets: $_"
        return $null
    }
}

function Get-PresetsByCategory {
    <#
    .SYNOPSIS
        Groups presets by category, sorted by category order
    .PARAMETER Config
        The presets configuration object
    .OUTPUTS
        Ordered hashtable with category names as keys and preset arrays as values
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )
    
    # Build category order lookup
    $categoryOrder = @{}
    foreach ($cat in $Config.categories) {
        $categoryOrder[$cat.id] = $cat.order
    }
    
    # Group presets by category
    $grouped = @{}
    foreach ($preset in $Config.presets) {
        $category = if ($preset.category) { $preset.category } else { "Other" }
        if (-not $grouped.ContainsKey($category)) {
            $grouped[$category] = @()
        }
        $grouped[$category] += $preset
    }
    
    # Sort categories by order
    $sortedCategories = $grouped.Keys | Sort-Object { 
        if ($categoryOrder.ContainsKey($_)) { $categoryOrder[$_] } else { 999 }
    }
    
    # Build ordered result
    $result = [ordered]@{}
    foreach ($cat in $sortedCategories) {
        $result[$cat] = $grouped[$cat]
    }
    
    return $result
}

#endregion

#region Command Execution

function Invoke-PresetCommand {
    <#
    .SYNOPSIS
        Executes a command preset in the specified mode
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Command
        The command to execute
    .PARAMETER Mode
        Execution mode: sameWindow or newWindow
    .PARAMETER Username
        Linux username to run as (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter(Mandatory)]
        [ValidateSet("sameWindow", "newWindow")]
        [string]$Mode,
        
        [Parameter()]
        [string]$Username
    )
    
    # Build the bash command with proper PATH setup for npm global packages
    $bashSetup = 'export PATH=~/.npm-global/bin:$PATH OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local'
    
    switch ($Mode) {
        "sameWindow" {
            # Run interactively in current terminal
            Write-Host ""
            Write-Host "  Running: " -ForegroundColor Cyan -NoNewline
            Write-Host $Command -ForegroundColor Yellow
            Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
            Write-Host ""
            
            $fullCmd = "$bashSetup; $Command"
            
            if ($Username) {
                & wsl.exe -d $DistroName -u $Username -- bash -lc $fullCmd
            }
            else {
                & wsl.exe -d $DistroName -- bash -lc $fullCmd
            }
            
            Write-Host ""
            Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
            Write-Host "  Command completed." -ForegroundColor DarkGray
        }
        
        "newWindow" {
            # Open new window and run command
            Write-Host ""
            Write-Host "  Opening new window to run: " -ForegroundColor Cyan -NoNewline
            Write-Host $Command -ForegroundColor Yellow
            Write-Host ""
            
            $fullCmd = "$bashSetup; $Command; echo; echo 'Press Enter to close...'; read"
            $escapedCmd = $fullCmd -replace '"', '\"'
            
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "wsl.exe -d $DistroName -- bash -lc `"$escapedCmd`""
            
            Write-Host "  Command started in new window." -ForegroundColor Green
        }
    }
}

function Show-CommandActionMenu {
    <#
    .SYNOPSIS
        Shows the action menu for a selected command preset
    .PARAMETER PresetName
        Display name of the preset
    .PARAMETER Command
        The command string (may be edited by user)
    .PARAMETER DefaultMode
        Default execution mode
    .PARAMETER Editable
        Whether the command can be edited (shows edit option)
    .OUTPUTS
        Hashtable with Action (run/cancel) and Command (possibly edited) and Mode
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PresetName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$DefaultMode = "sameWindow",
        
        [Parameter()]
        [bool]$Editable = $false
    )
    
    $currentCommand = $Command
    
    while ($true) {
        Write-Host ""
        Write-Host "  Selected: " -ForegroundColor Cyan -NoNewline
        Write-Host $PresetName -ForegroundColor White
        Write-Host ""
        Write-Host "  Command:" -ForegroundColor DarkGray
        Write-Host "  > $currentCommand" -ForegroundColor Yellow
        Write-Host ""
        
        $defaultMark1 = if ($DefaultMode -eq "sameWindow") { " (default)" } else { "" }
        $defaultMark2 = if ($DefaultMode -eq "newWindow") { " (default)" } else { "" }
        
        Write-Host "    [1] Run in current terminal$defaultMark1" -ForegroundColor White
        Write-Host "    [2] Run in new WSL window$defaultMark2" -ForegroundColor White
        
        if ($Editable) {
            Write-Host "    [3] Edit command" -ForegroundColor White
            $maxOption = 3
        }
        else {
            $maxOption = 2
        }
        
        Write-Host ""
        Write-Host "    [0] Cancel" -ForegroundColor DarkGray
        Write-Host ""
        
        # Map mode to display number for default hint
        $defaultNum = if ($DefaultMode -eq "sameWindow") { "1" } else { "2" }
        Write-Host "  Enter choice (1-$maxOption) [default: $defaultNum]: " -ForegroundColor Gray -NoNewline
        $inputStr = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($inputStr)) {
            # Use default mode
            return @{
                Action  = "run"
                Command = $currentCommand
                Mode    = $DefaultMode
            }
        }
        
        switch ($inputStr) {
            "0" {
                return @{ Action = "cancel" }
            }
            "1" {
                return @{
                    Action  = "run"
                    Command = $currentCommand
                    Mode    = "sameWindow"
                }
            }
            "2" {
                return @{
                    Action  = "run"
                    Command = $currentCommand
                    Mode    = "newWindow"
                }
            }
            "3" {
                if (-not $Editable) {
                    Write-Host "  [!] Invalid selection" -ForegroundColor Red
                    Start-Sleep -Milliseconds 500
                    continue
                }
                
                # Edit command inline with pre-filled text using SendKeys
                Write-Host ""
                Write-Host "  Edit command (modify and press Enter):" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  > " -ForegroundColor Cyan -NoNewline
                
                # Pre-fill the input with current command using SendKeys
                try {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                    # Escape special SendKeys characters: +^%~(){}[]
                    $escapedCmd = $currentCommand -replace '([+^%~(){}\[\]])', '{$1}'
                    [System.Windows.Forms.SendKeys]::SendWait($escapedCmd)
                }
                catch {
                    # If SendKeys fails, just show the command for manual copy
                    Write-Host $currentCommand -NoNewline
                }
                
                $editedCommand = Read-Host
                
                if (-not [string]::IsNullOrWhiteSpace($editedCommand)) {
                    $currentCommand = $editedCommand.Trim()
                    Write-Host "  Command updated." -ForegroundColor Green
                }
                else {
                    Write-Host "  No changes made (keeping original)." -ForegroundColor DarkGray
                }
                Start-Sleep -Milliseconds 500
                # Loop back to show menu again with updated command
            }
            default {
                Write-Host "  [!] Invalid selection" -ForegroundColor Red
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

#endregion

#region Menu Building

function Build-CommandPresetMenuOptions {
    <#
    .SYNOPSIS
        Builds menu options array from presets configuration
    .PARAMETER Config
        The presets configuration object
    .PARAMETER IncludeCategories
        Whether to show category headers
    .OUTPUTS
        Array of menu option hashtables compatible with Show-SelectMenu
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,
        
        [Parameter()]
        [switch]$IncludeCategories
    )
    
    $menuOptions = @()
    $groupedPresets = Get-PresetsByCategory -Config $Config
    
    $isFirst = $true
    foreach ($category in $groupedPresets.Keys) {
        # Add category separator (except for first)
        if ($IncludeCategories -and -not $isFirst) {
            # Categories are indicated by the preset grouping in the display
        }
        $isFirst = $false
        
        foreach ($preset in $groupedPresets[$category]) {
            $menuOptions += @{
                Text        = $preset.name
                Description = "$($preset.command)"
                Action      = $preset.id
                Category    = $category
                Command     = $preset.command
                DefaultMode = if ($preset.defaultMode) { $preset.defaultMode } else { "sameWindow" }
                Editable    = if ($preset.PSObject.Properties['editable']) { $preset.editable } else { $false }
            }
        }
    }
    
    # Add back option
    $menuOptions += @{
        Text        = "<- Back"
        Description = ""
        Action      = "Back"
    }
    
    return $menuOptions
}

function Show-CommandPresetMenu {
    <#
    .SYNOPSIS
        Displays the command presets menu and handles selection
    .PARAMETER RepoRoot
        Root path of the repository
    .PARAMETER DistroName
        WSL distribution name
    .PARAMETER Username
        Linux username (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter()]
        [string]$Username
    )
    
    $config = Get-CommandPresets -RepoRoot $RepoRoot
    
    if (-not $config) {
        Write-Host ""
        Write-Host "  [!] Could not load command presets configuration." -ForegroundColor Red
        Write-Host "      Check config/command-presets.json exists and is valid JSON." -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    
    while ($true) {
        # Build menu options
        $menuOptions = Build-CommandPresetMenuOptions -Config $config
        
        # Custom display for presets menu with command shown in gray
        Show-Banner
        Write-Host "  Command Presets" -ForegroundColor White
        Write-Host "  $('-' * 21)" -ForegroundColor DarkGray
        Write-Host ""
        
        $currentCategory = ""
        $index = 1
        $optionMap = @{}
        
        foreach ($option in $menuOptions) {
            if ($option.Action -eq "Back") {
                Write-Host ""
                Write-Host "    [$index] $($option.Text)" -ForegroundColor Yellow
                $optionMap[$index] = $option
                $index++
                continue
            }
            
            # Show category header if changed
            if ($option.Category -and $option.Category -ne $currentCategory) {
                if ($currentCategory -ne "") {
                    Write-Host ""
                }
                Write-Host "    -- $($option.Category) --" -ForegroundColor DarkCyan
                $currentCategory = $option.Category
            }
            
            # Show preset name
            Write-Host "    [$index] $($option.Text)" -ForegroundColor Yellow
            # Show command in gray below
            Write-Host "        $($option.Command)" -ForegroundColor DarkGray
            
            $optionMap[$index] = $option
            $index++
        }
        
        Write-Host ""
        Write-Host "  Select a command to run" -ForegroundColor DarkGray
        Write-Host ""
        
        # Get selection
        Write-Host "  Select option [1-$($index - 1)]: " -ForegroundColor White -NoNewline
        $inputStr = Read-Host
        
        if (-not ($inputStr -match '^\d+$')) {
            Write-Host "  [!] Please enter a number" -ForegroundColor Red
            Start-Sleep -Milliseconds 800
            continue
        }
        
        $selection = [int]$inputStr
        if ($selection -lt 1 -or $selection -ge $index) {
            Write-Host "  [!] Please enter a number between 1 and $($index - 1)" -ForegroundColor Red
            Start-Sleep -Milliseconds 800
            continue
        }
        
        $selectedOption = $optionMap[$selection]
        
        if ($selectedOption.Action -eq "Back") {
            return
        }
        
        # Show action menu (edit command, choose run mode)
        $result = Show-CommandActionMenu `
            -PresetName $selectedOption.Text `
            -Command $selectedOption.Command `
            -DefaultMode $selectedOption.DefaultMode `
            -Editable $selectedOption.Editable
        
        if ($result.Action -eq "cancel") {
            # User cancelled, go back to preset list
            continue
        }
        
        # Execute the command
        Invoke-PresetCommand `
            -DistroName $DistroName `
            -Command $result.Command `
            -Mode $result.Mode `
            -Username $Username
        
        if ($result.Mode -eq "sameWindow") {
            Write-Host ""
            Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        else {
            Start-Sleep -Seconds 1
        }
    }
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'Get-CommandPresets',
    'Get-PresetsByCategory',
    'Invoke-PresetCommand',
    'Show-CommandActionMenu',
    'Build-CommandPresetMenuOptions',
    'Show-CommandPresetMenu'
)
