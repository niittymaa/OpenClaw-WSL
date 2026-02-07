#Requires -Version 5.1
<#
.SYNOPSIS
    Menu System Module for OpenClaw
.DESCRIPTION
    Provides reusable menu components for interactive console menus
#>

#region ASCII Art Font Definitions

# Monospace ASCII art font - each character is 6 columns wide × 6 rows tall
# This ensures consistent width regardless of character
$Script:AsciiFont = @{
    'A' = @(
        " █████╗ "
        "██╔══██╗"
        "███████║"
        "██╔══██║"
        "██║  ██║"
        "╚═╝  ╚═╝"
    )
    'B' = @(
        "██████╗ "
        "██╔══██╗"
        "██████╔╝"
        "██╔══██╗"
        "██████╔╝"
        "╚═════╝ "
    )
    'C' = @(
        " ██████╗"
        "██╔════╝"
        "██║     "
        "██║     "
        "╚██████╗"
        " ╚═════╝"
    )
    'D' = @(
        "██████╗ "
        "██╔══██╗"
        "██║  ██║"
        "██║  ██║"
        "██████╔╝"
        "╚═════╝ "
    )
    'E' = @(
        "███████╗"
        "██╔════╝"
        "█████╗  "
        "██╔══╝  "
        "███████╗"
        "╚══════╝"
    )
    'F' = @(
        "███████╗"
        "██╔════╝"
        "█████╗  "
        "██╔══╝  "
        "██║     "
        "╚═╝     "
    )
    'G' = @(
        " ██████╗ "
        "██╔════╝ "
        "██║  ███╗"
        "██║   ██║"
        "╚██████╔╝"
        " ╚═════╝ "
    )
    'H' = @(
        "██╗  ██╗"
        "██║  ██║"
        "███████║"
        "██╔══██║"
        "██║  ██║"
        "╚═╝  ╚═╝"
    )
    'I' = @(
        "██╗"
        "██║"
        "██║"
        "██║"
        "██║"
        "╚═╝"
    )
    'J' = @(
        "     ██╗"
        "     ██║"
        "     ██║"
        "██   ██║"
        "╚█████╔╝"
        " ╚════╝ "
    )
    'K' = @(
        "██╗  ██╗"
        "██║ ██╔╝"
        "█████╔╝ "
        "██╔═██╗ "
        "██║  ██╗"
        "╚═╝  ╚═╝"
    )
    'L' = @(
        "██╗     "
        "██║     "
        "██║     "
        "██║     "
        "███████╗"
        "╚══════╝"
    )
    'M' = @(
        "███╗   ███╗"
        "████╗ ████║"
        "██╔████╔██║"
        "██║╚██╔╝██║"
        "██║ ╚═╝ ██║"
        "╚═╝     ╚═╝"
    )
    'N' = @(
        "███╗   ██╗"
        "████╗  ██║"
        "██╔██╗ ██║"
        "██║╚██╗██║"
        "██║ ╚████║"
        "╚═╝  ╚═══╝"
    )
    'O' = @(
        " ██████╗ "
        "██╔═══██╗"
        "██║   ██║"
        "██║   ██║"
        "╚██████╔╝"
        " ╚═════╝ "
    )
    'P' = @(
        "██████╗ "
        "██╔══██╗"
        "██████╔╝"
        "██╔═══╝ "
        "██║     "
        "╚═╝     "
    )
    'Q' = @(
        " ██████╗ "
        "██╔═══██╗"
        "██║   ██║"
        "██║▄▄ ██║"
        "╚██████╔╝"
        " ╚══▀▀═╝ "
    )
    'R' = @(
        "██████╗ "
        "██╔══██╗"
        "██████╔╝"
        "██╔══██╗"
        "██║  ██║"
        "╚═╝  ╚═╝"
    )
    'S' = @(
        "███████╗"
        "██╔════╝"
        "███████╗"
        "╚════██║"
        "███████║"
        "╚══════╝"
    )
    'T' = @(
        "████████╗"
        "╚══██╔══╝"
        "   ██║   "
        "   ██║   "
        "   ██║   "
        "   ╚═╝   "
    )
    'U' = @(
        "██╗   ██╗"
        "██║   ██║"
        "██║   ██║"
        "██║   ██║"
        "╚██████╔╝"
        " ╚═════╝ "
    )
    'V' = @(
        "██╗   ██╗"
        "██║   ██║"
        "██║   ██║"
        "╚██╗ ██╔╝"
        " ╚████╔╝ "
        "  ╚═══╝  "
    )
    'W' = @(
        "██╗    ██╗"
        "██║    ██║"
        "██║ █╗ ██║"
        "██║███╗██║"
        "╚███╔███╔╝"
        " ╚══╝╚══╝ "
    )
    'X' = @(
        "██╗  ██╗"
        "╚██╗██╔╝"
        " ╚███╔╝ "
        " ██╔██╗ "
        "██╔╝ ██╗"
        "╚═╝  ╚═╝"
    )
    'Y' = @(
        "██╗   ██╗"
        "╚██╗ ██╔╝"
        " ╚████╔╝ "
        "  ╚██╔╝  "
        "   ██║   "
        "   ╚═╝   "
    )
    'Z' = @(
        "███████╗"
        "╚══███╔╝"
        "  ███╔╝ "
        " ███╔╝  "
        "███████╗"
        "╚══════╝"
    )
    '0' = @(
        " ██████╗ "
        "██╔═████╗"
        "██║██╔██║"
        "████╔╝██║"
        "╚██████╔╝"
        " ╚═════╝ "
    )
    '1' = @(
        " ██╗"
        "███║"
        "╚██║"
        " ██║"
        " ██║"
        " ╚═╝"
    )
    '2' = @(
        "██████╗ "
        "╚════██╗"
        " █████╔╝"
        "██╔═══╝ "
        "███████╗"
        "╚══════╝"
    )
    '3' = @(
        "██████╗ "
        "╚════██╗"
        " █████╔╝"
        " ╚═══██╗"
        "██████╔╝"
        "╚═════╝ "
    )
    '4' = @(
        "██╗  ██╗"
        "██║  ██║"
        "███████║"
        "╚════██║"
        "     ██║"
        "     ╚═╝"
    )
    '5' = @(
        "███████╗"
        "██╔════╝"
        "███████╗"
        "╚════██║"
        "███████║"
        "╚══════╝"
    )
    '6' = @(
        " ██████╗"
        "██╔════╝"
        "███████╗"
        "██╔═══██╗"
        "╚██████╔╝"
        " ╚═════╝"
    )
    '7' = @(
        "███████╗"
        "╚════██║"
        "    ██╔╝"
        "   ██╔╝ "
        "   ██║  "
        "   ╚═╝  "
    )
    '8' = @(
        " █████╗ "
        "██╔══██╗"
        "╚█████╔╝"
        "██╔══██╗"
        "╚█████╔╝"
        " ╚════╝ "
    )
    '9' = @(
        " █████╗ "
        "██╔══██╗"
        "╚██████║"
        " ╚═══██║"
        " █████╔╝"
        " ╚════╝ "
    )
    '-' = @(
        "      "
        "      "
        "█████╗"
        "╚════╝"
        "      "
        "      "
    )
    ' ' = @(
        "   "
        "   "
        "   "
        "   "
        "   "
        "   "
    )
}

function Get-AsciiArtTitle {
    <#
    .SYNOPSIS
        Generates ASCII art for a given title string
    .PARAMETER Title
        The title text to render (A-Z, 0-9, hyphen, space)
    .OUTPUTS
        Array of strings representing each line of the ASCII art
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    
    $lines = @("", "", "", "", "", "")
    $upperTitle = $Title.ToUpper()
    
    foreach ($char in $upperTitle.ToCharArray()) {
        $charKey = [string]$char
        if ($Script:AsciiFont.ContainsKey($charKey)) {
            $charArt = $Script:AsciiFont[$charKey]
            for ($i = 0; $i -lt 6; $i++) {
                $lines[$i] += $charArt[$i]
            }
        }
    }
    
    return $lines
}

function Get-AsciiArtWidth {
    <#
    .SYNOPSIS
        Calculates the total width of ASCII art for a given title
    .PARAMETER Title
        The title text to measure
    .OUTPUTS
        Integer width in characters
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    
    $width = 0
    $upperTitle = $Title.ToUpper()
    
    foreach ($char in $upperTitle.ToCharArray()) {
        $charKey = [string]$char
        if ($Script:AsciiFont.ContainsKey($charKey)) {
            # Use the first line's length as the character width
            $width += $Script:AsciiFont[$charKey][0].Length
        }
    }
    
    return $width
}

function Test-BannerTitleValid {
    <#
    .SYNOPSIS
        Validates if a title can be rendered within the banner
    .PARAMETER Title
        The title text to validate
    .PARAMETER MaxLength
        Maximum character count allowed
    .OUTPUTS
        Hashtable with Valid (bool), Message (string), Width (int)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title,
        
        [Parameter()]
        [int]$MaxLength = 8
    )
    
    $result = @{
        Valid   = $true
        Message = ""
        Width   = 0
    }
    
    if ([string]::IsNullOrEmpty($Title)) {
        $result.Valid = $false
        $result.Message = "Title cannot be empty"
        return $result
    }
    
    if ($Title.Length -gt $MaxLength) {
        $result.Valid = $false
        $result.Message = "Title exceeds maximum length of $MaxLength characters"
        return $result
    }
    
    # Check for invalid characters
    $upperTitle = $Title.ToUpper()
    foreach ($char in $upperTitle.ToCharArray()) {
        $charKey = [string]$char
        if (-not $Script:AsciiFont.ContainsKey($charKey)) {
            $result.Valid = $false
            $result.Message = "Character '$char' is not supported. Use A-Z, 0-9, hyphen, or space."
            return $result
        }
    }
    
    # Check rendered width fits in banner (inner width = 57, need padding)
    $artWidth = Get-AsciiArtWidth -Title $Title
    $result.Width = $artWidth
    
    # Banner inner content area is 57 chars, need 4 chars padding on each side minimum
    $maxArtWidth = 53
    if ($artWidth -gt $maxArtWidth) {
        $result.Valid = $false
        $result.Message = "Rendered title is too wide ($artWidth chars). Try a shorter title."
        return $result
    }
    
    return $result
}

#endregion

#region Menu Display Functions

function Show-Banner {
    <#
    .SYNOPSIS
        Displays the application banner with customizable ASCII art title
    .PARAMETER CustomTitle
        Optional override for the banner title. If not provided, uses settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CustomTitle
    )
    
    # Reset console state before clearing to prevent corruption
    try {
        [Console]::ResetColor()
        [Console]::CursorVisible = $true
        [Console]::Out.Flush()
    } catch {
        # Ignore errors on older PowerShell versions
    }
    
    Clear-Host
    
    try {
        [Console]::SetCursorPosition(0, 0)
    } catch {
        # Ignore if not supported
    }
    
    # Get banner title from settings or use default
    $bannerTitle = if ($CustomTitle) { 
        $CustomTitle 
    } else {
        try {
            $setting = Get-UserSetting -Name "ui.bannerTitle" -ErrorAction SilentlyContinue
            if ($setting) { $setting } else { "OC-WSL" }
        } catch {
            "OC-WSL"
        }
    }
    
    # Generate ASCII art for the title
    $artLines = Get-AsciiArtTitle -Title $bannerTitle
    $artWidth = Get-AsciiArtWidth -Title $bannerTitle
    
    # Banner inner width is 57 characters
    $innerWidth = 57
    
    # Calculate padding to center the ASCII art
    $totalPadding = $innerWidth - $artWidth
    $leftPadding = [Math]::Floor($totalPadding / 2)
    $rightPadding = $totalPadding - $leftPadding
    
    Write-Host ""
    Write-Host "  +$('=' * $innerWidth)+" -ForegroundColor Cyan
    Write-Host "  |$(' ' * $innerWidth)|" -ForegroundColor Cyan
    
    # Output each line of the ASCII art, centered
    foreach ($line in $artLines) {
        $lineWidth = $line.Length
        $lineLeftPad = $leftPadding
        $lineRightPad = $innerWidth - $lineWidth - $lineLeftPad
        
        # Ensure non-negative padding
        if ($lineRightPad -lt 0) { 
            $lineLeftPad = [Math]::Max(0, $lineLeftPad + $lineRightPad)
            $lineRightPad = 0 
        }
        
        Write-Host "  |$(' ' * $lineLeftPad)$line$(' ' * $lineRightPad)|" -ForegroundColor Cyan
    }
    
    Write-Host "  |$(' ' * $innerWidth)|" -ForegroundColor Cyan
    Write-Host "  +$('=' * $innerWidth)+" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter(Mandatory)]
        [array]$Options,
        
        [Parameter()]
        [string]$Footer,
        
        [Parameter()]
        [switch]$ShowBanner
    )
    
    if ($ShowBanner) {
        Show-Banner
    }
    
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $('-' * ($Title.Length + 4))" -ForegroundColor DarkGray
    Write-Host ""
    
    $index = 1
    foreach ($option in $Options) {
        $color = if ($option.Disabled) { "DarkGray" } else { "Yellow" }
        $disabledText = if ($option.Disabled) { " (unavailable)" } else { "" }
        Write-Host "    [$index] $($option.Text)$disabledText" -ForegroundColor $color
        
        if ($option.Description) {
            Write-Host "        $($option.Description)" -ForegroundColor DarkGray
        }
        $index++
    }
    
    Write-Host ""
    
    if ($Footer) {
        Write-Host "  $Footer" -ForegroundColor DarkGray
        Write-Host ""
    }
}

function Get-MenuSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$MaxOption,
        
        [Parameter()]
        [string]$Prompt = "Select option",
        
        [Parameter()]
        [array]$DisabledOptions = @()
    )
    
    while ($true) {
        Write-Host "  $Prompt [1-$MaxOption]: " -ForegroundColor White -NoNewline
        $userInput = Read-Host
        
        if ($userInput -match '^\d+$') {
            $selection = [int]$userInput
            if ($selection -ge 1 -and $selection -le $MaxOption) {
                if ($selection -in $DisabledOptions) {
                    Write-Host "  [!] This option is currently unavailable" -ForegroundColor Yellow
                    continue
                }
                return $selection
            }
        }
        
        Write-Host "  [!] Please enter a number between 1 and $MaxOption" -ForegroundColor Red
    }
}

function Show-SelectMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter(Mandatory)]
        [array]$Options,
        
        [Parameter()]
        [string]$Footer,
        
        [Parameter()]
        [switch]$ShowBanner
    )
    
    Show-Menu -Title $Title -Options $Options -Footer $Footer -ShowBanner:$ShowBanner
    
    $disabledIndices = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        if ($Options[$i].Disabled) {
            $disabledIndices += ($i + 1)
        }
    }
    
    $selection = Get-MenuSelection -MaxOption $Options.Count -DisabledOptions $disabledIndices
    return $Options[$selection - 1]
}

#endregion

#region Status Display Functions

function Show-Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )
    
    $icon = switch ($Type) {
        "Info"    { "->" }
        "Success" { "OK" }
        "Warning" { "!" }
        "Error"   { "X" }
    }
    
    $color = switch ($Type) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host "  [$icon] $Message" -ForegroundColor $color
}

function Show-Progress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Activity,
        
        [Parameter()]
        [string]$Status
    )
    
    Write-Host "  -> $Activity" -ForegroundColor Cyan -NoNewline
    if ($Status) {
        Write-Host " - $Status" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Confirm-Action {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [bool]$Default = $true
    )
    
    $defaultText = if ($Default) { "Y/n" } else { "y/N" }
    Write-Host ""
    Write-Host "  $Message [$defaultText]: " -ForegroundColor Yellow -NoNewline
    $response = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default
    }
    
    return $response.ToLower() -in @('y', 'yes')
}

function Wait-ForKeyPress {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Message = "Press any key to continue..."
    )
    
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

#endregion

#region Section Display

function Show-Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    
    Write-Host ""
    Write-Host "  ===================================================================" -ForegroundColor DarkCyan
    Write-Host "    $Title" -ForegroundColor White
    Write-Host "  ===================================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Show-InfoBox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Lines,
        
        [Parameter()]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Type = "Info"
    )
    
    $color = switch ($Type) {
        "Info"    { "Cyan" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host ""
    Write-Host "  +-- $Title $('-' * (50 - $Title.Length))" -ForegroundColor $color
    foreach ($line in $Lines) {
        Write-Host "  |  $line" -ForegroundColor $color
    }
    Write-Host "  +$('-' * 55)" -ForegroundColor $color
    Write-Host ""
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'Show-Banner',
    'Show-Menu',
    'Get-MenuSelection',
    'Show-SelectMenu',
    'Show-Status',
    'Show-Progress',
    'Confirm-Action',
    'Wait-ForKeyPress',
    'Show-Section',
    'Show-InfoBox',
    # Banner customization
    'Get-AsciiArtTitle',
    'Get-AsciiArtWidth',
    'Test-BannerTitleValid'
)
