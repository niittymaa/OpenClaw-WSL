#Requires -Version 5.1
<#
.SYNOPSIS
    Windows path normalization utilities for OpenClaw WSL Automation
.DESCRIPTION
    Handles conversion and validation of various Windows path formats
#>

#region Path Normalization

function ConvertTo-NormalizedWindowsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )
    
    $originalPath = $Path
    $Path = $Path.Trim()
    
    # Handle empty input
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty."
    }
    
    # Handle Unix-style paths like /d/temp or /c/users
    if ($Path -match '^/([a-zA-Z])/(.*)$') {
        $driveLetter = $Matches[1].ToUpper()
        $remainder = $Matches[2]
        $Path = "${driveLetter}:\$remainder"
    }
    
    # Handle paths like D:temp (no backslash after colon)
    if ($Path -match '^([a-zA-Z]):([^\\\/].*)$') {
        $driveLetter = $Matches[1].ToUpper()
        $remainder = $Matches[2]
        $Path = "${driveLetter}:\$remainder"
    }
    
    # Convert all forward slashes to backslashes
    $Path = $Path -replace '/', '\'
    
    # Remove duplicate backslashes (except for UNC paths)
    if ($Path -notmatch '^\\\\') {
        $Path = $Path -replace '\\\\+', '\'
    }
    
    # Remove trailing backslash (unless root drive)
    if ($Path -match '^[a-zA-Z]:\\$') {
        # Keep trailing backslash for root drive (C:\)
    } elseif ($Path.EndsWith('\')) {
        $Path = $Path.TrimEnd('\')
    }
    
    # Ensure drive letter is uppercase
    if ($Path -match '^([a-zA-Z]):(.*)$') {
        $driveLetter = $Matches[1].ToUpper()
        $remainder = $Matches[2]
        $Path = "${driveLetter}:$remainder"
    }
    
    # Validate final path format
    if ($Path -notmatch '^[A-Z]:\\') {
        throw "Invalid path format: '$originalPath'. Expected Windows path like 'D:\folder' or 'D:folder'."
    }
    
    return $Path
}

function Test-WindowsPathValid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,
        
        [Parameter()]
        [switch]$MustExist
    )
    
    try {
        $normalizedPath = ConvertTo-NormalizedWindowsPath $Path
    }
    catch {
        return @{
            Valid = $false
            Error = $_.Exception.Message
            NormalizedPath = $null
        }
    }
    
    # Extract drive letter
    $driveLetter = $normalizedPath.Substring(0, 1)
    $driveRoot = "${driveLetter}:\"
    
    # Check if drive exists
    if (-not (Test-Path $driveRoot)) {
        return @{
            Valid = $false
            Error = "Drive '$driveLetter`:' does not exist."
            NormalizedPath = $normalizedPath
        }
    }
    
    # Check for illegal characters in path (excluding drive and colon)
    $pathPart = $normalizedPath.Substring(3)
    $illegalChars = [System.IO.Path]::GetInvalidPathChars()
    $illegalCharsPattern = '[' + [Regex]::Escape(-join $illegalChars) + '<>"|?*]'
    
    if ($pathPart -match $illegalCharsPattern) {
        return @{
            Valid = $false
            Error = "Path contains illegal characters."
            NormalizedPath = $normalizedPath
        }
    }
    
    # Check existence if required
    if ($MustExist -and -not (Test-Path $normalizedPath)) {
        return @{
            Valid = $false
            Error = "Path does not exist: '$normalizedPath'"
            NormalizedPath = $normalizedPath
        }
    }
    
    return @{
        Valid = $true
        Error = $null
        NormalizedPath = $normalizedPath
    }
}

function Read-ValidatedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        
        [Parameter()]
        [string]$Default,
        
        [Parameter()]
        [switch]$MustExist,
        
        [Parameter()]
        [switch]$CreateIfMissing
    )
    
    while ($true) {
        $displayPrompt = $Prompt
        if ($Default) {
            $displayPrompt = "$Prompt [default: $Default]"
        }
        
        Write-Host ""
        Write-Host "  $displayPrompt" -ForegroundColor Yellow
        Write-Host "  Accepted formats: D:\path, D:path, D:/path, /d/path" -ForegroundColor DarkGray
        Write-Host "  > " -NoNewline -ForegroundColor Gray
        
        $userInput = Read-Host
        $userInput = $userInput.Trim()
        
        if ([string]::IsNullOrWhiteSpace($userInput) -and $Default) {
            $userInput = $Default
            Write-Host "  Using default: $Default" -ForegroundColor DarkGray
        }
        
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            Write-Host "  [ERROR] Path is required." -ForegroundColor Red
            continue
        }
        
        # Validate and normalize
        $validation = Test-WindowsPathValid $userInput
        
        if (-not $validation.Valid) {
            Write-Host "  [ERROR] $($validation.Error)" -ForegroundColor Red
            continue
        }
        
        $normalizedPath = $validation.NormalizedPath
        
        # Check existence
        $pathExists = Test-Path $normalizedPath
        
        if ($MustExist -and -not $pathExists) {
            Write-Host "  [ERROR] Path does not exist: $normalizedPath" -ForegroundColor Red
            continue
        }
        
        if (-not $pathExists -and $CreateIfMissing) {
            Write-Host ""
            Write-Host "  Directory does not exist: $normalizedPath" -ForegroundColor Yellow
            Write-Host "  Create it? [Y/n]: " -NoNewline -ForegroundColor Gray
            $createInput = Read-Host
            
            if ([string]::IsNullOrWhiteSpace($createInput) -or $createInput.ToLower() -eq 'y' -or $createInput.ToLower() -eq 'yes') {
                try {
                    New-Item -ItemType Directory -Path $normalizedPath -Force | Out-Null
                    Write-Host "  [OK] Created directory: $normalizedPath" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [ERROR] Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
                    continue
                }
            } else {
                Write-Host "  Directory not created. Please enter a different path." -ForegroundColor DarkGray
                continue
            }
        }
        
        return $normalizedPath
    }
}

#endregion

#region Directory Operations

function New-DirectoryStructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        
        [Parameter(Mandatory)]
        [string[]]$Subdirectories
    )
    
    $created = @()
    
    foreach ($subdir in $Subdirectories) {
        $fullPath = Join-Path $BasePath $subdir
        
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            $created += $fullPath
        }
    }
    
    return $created
}

function Get-DirectorySize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        return 0
    }
    
    $size = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | 
             Measure-Object -Property Length -Sum).Sum
    
    if ($null -eq $size) { return 0 }
    return [long]$size
}

#endregion

#region Path Conversion (Windows <-> WSL)

function ConvertTo-WSLPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WindowsPath
    )
    
    # Normalize first
    $normalizedPath = ConvertTo-NormalizedWindowsPath $WindowsPath
    
    # Extract drive letter and path
    if ($normalizedPath -match '^([A-Z]):\\(.*)$') {
        $driveLetter = $Matches[1].ToLower()
        $pathPart = $Matches[2] -replace '\\', '/'
        return "/mnt/$driveLetter/$pathPart"
    }
    
    throw "Cannot convert path to WSL format: $WindowsPath"
}

function ConvertTo-WindowsPathFromWSL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WSLPath
    )
    
    if ($WSLPath -match '^/mnt/([a-z])/(.*)$') {
        $driveLetter = $Matches[1].ToUpper()
        $pathPart = $Matches[2] -replace '/', '\'
        return "${driveLetter}:\$pathPart"
    }
    
    throw "Cannot convert WSL path to Windows format: $WSLPath"
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    'ConvertTo-NormalizedWindowsPath',
    'Test-WindowsPathValid',
    'Read-ValidatedPath',
    'New-DirectoryStructure',
    'Get-DirectorySize',
    'ConvertTo-WSLPath',
    'ConvertTo-WindowsPathFromWSL'
)
