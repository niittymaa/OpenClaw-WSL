#Requires -Version 5.1
<#
.SYNOPSIS
    File-based Logging System for OpenClaw WSL Automation
.DESCRIPTION
    Provides file-based error logging with log rotation, timestamps, and log levels.
    All script operations are logged to files for troubleshooting and auditing.
#>

# Script-level variables
$Script:LogDirectory = $null
$Script:LogFilePath = $null
$Script:ErrorLogFilePath = $null
$Script:MaxLogSizeBytes = 10MB
$Script:MaxLogFiles = 5
$Script:LogLevel = "Info"
$Script:LoggingEnabled = $false

#region Initialization

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes the logging system with specified log directory
    .PARAMETER LogDirectory
        Directory where log files will be stored
    .PARAMETER LogLevel
        Minimum log level to record (Debug, Info, Warning, Error)
    .PARAMETER MaxLogSizeMB
        Maximum size of each log file in MB before rotation
    .PARAMETER MaxLogFiles
        Maximum number of rotated log files to keep
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,
        
        [Parameter()]
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$LogLevel = "Info",
        
        [Parameter()]
        [int]$MaxLogSizeMB = 10,
        
        [Parameter()]
        [int]$MaxLogFiles = 5
    )
    
    try {
        # Create log directory if it doesn't exist
        if (-not (Test-Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        
        $Script:LogDirectory = $LogDirectory
        $Script:LogLevel = $LogLevel
        $Script:MaxLogSizeBytes = $MaxLogSizeMB * 1MB
        $Script:MaxLogFiles = $MaxLogFiles
        
        # Create log file paths with date
        $dateStamp = Get-Date -Format "yyyy-MM-dd"
        $Script:LogFilePath = Join-Path $LogDirectory "openclaw-$dateStamp.log"
        $Script:ErrorLogFilePath = Join-Path $LogDirectory "openclaw-errors-$dateStamp.log"
        
        $Script:LoggingEnabled = $true
        
        # Write initialization message
        Write-ToLogFile -Message "=== Logging initialized ===" -Level "Info" -LogFile $Script:LogFilePath
        Write-ToLogFile -Message "Log directory: $LogDirectory" -Level "Info" -LogFile $Script:LogFilePath
        Write-ToLogFile -Message "Log level: $LogLevel" -Level "Info" -LogFile $Script:LogFilePath
        Write-ToLogFile -Message "PowerShell version: $($PSVersionTable.PSVersion)" -Level "Info" -LogFile $Script:LogFilePath
        Write-ToLogFile -Message "OS: $([System.Environment]::OSVersion.VersionString)" -Level "Info" -LogFile $Script:LogFilePath
        
        return $true
    }
    catch {
        Write-Warning "Failed to initialize logging: $($_.Exception.Message)"
        $Script:LoggingEnabled = $false
        return $false
    }
}

function Get-LogDirectory {
    [CmdletBinding()]
    param()
    return $Script:LogDirectory
}

function Get-LogFilePath {
    [CmdletBinding()]
    param()
    return $Script:LogFilePath
}

function Get-ErrorLogFilePath {
    [CmdletBinding()]
    param()
    return $Script:ErrorLogFilePath
}

function Test-LoggingEnabled {
    [CmdletBinding()]
    param()
    return $Script:LoggingEnabled
}

#endregion

#region Core Logging Functions

function Write-ToLogFile {
    <#
    .SYNOPSIS
        Writes a message to the specified log file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$Level = "Info",
        
        [Parameter()]
        [string]$LogFile
    )
    
    if (-not $Script:LoggingEnabled) {
        return
    }
    
    if (-not $LogFile) {
        $LogFile = $Script:LogFilePath
    }
    
    # Check log level threshold
    $levelPriority = @{
        "Debug"   = 0
        "Info"    = 1
        "Warning" = 2
        "Error"   = 3
    }
    
    if ($levelPriority[$Level] -lt $levelPriority[$Script:LogLevel]) {
        return
    }
    
    try {
        # Check for log rotation
        if (Test-Path $LogFile) {
            $fileInfo = Get-Item $LogFile
            if ($fileInfo.Length -ge $Script:MaxLogSizeBytes) {
                Invoke-LogRotation -LogFile $LogFile
            }
        }
        
        # Format log entry
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $levelPadded = $Level.ToUpper().PadRight(7)
        $logEntry = "[$timestamp] [$levelPadded] $Message"
        
        # Write to file (thread-safe with mutex)
        $mutexName = "OpenClawLogMutex_" + [System.IO.Path]::GetFileName($LogFile)
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        
        try {
            $mutex.WaitOne() | Out-Null
            Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8 -ErrorAction Stop
        }
        finally {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
    }
    catch {
        # Silently fail to avoid interrupting main script
        Write-Verbose "Log write failed: $($_.Exception.Message)"
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Main logging function - writes to both console and log file
    .PARAMETER Message
        The message to log
    .PARAMETER Level
        Log level (Debug, Info, Warning, Error)
    .PARAMETER NoConsole
        If set, only writes to log file, not console
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet("Debug", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        
        [Parameter()]
        [switch]$NoConsole
    )
    
    # Map Success to Info for file logging
    $fileLevel = if ($Level -eq "Success") { "Info" } else { $Level }
    
    # Write to main log file
    Write-ToLogFile -Message $Message -Level $fileLevel -LogFile $Script:LogFilePath
    
    # Also write errors to error log
    if ($Level -eq "Error") {
        Write-ToLogFile -Message $Message -Level $fileLevel -LogFile $Script:ErrorLogFilePath
    }
}

function Write-ErrorLog {
    <#
    .SYNOPSIS
        Logs an error with full exception details
    .PARAMETER Message
        Error description
    .PARAMETER Exception
        The exception object (optional)
    .PARAMETER ErrorRecord
        The PowerShell ErrorRecord object (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [System.Exception]$Exception,
        
        [Parameter()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    $errorDetails = @()
    $errorDetails += "ERROR: $Message"
    
    if ($Exception) {
        $errorDetails += "  Exception Type: $($Exception.GetType().FullName)"
        $errorDetails += "  Exception Message: $($Exception.Message)"
        
        if ($Exception.InnerException) {
            $errorDetails += "  Inner Exception: $($Exception.InnerException.Message)"
        }
    }
    
    if ($ErrorRecord) {
        $errorDetails += "  Script: $($ErrorRecord.InvocationInfo.ScriptName)"
        $errorDetails += "  Line: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        $errorDetails += "  Position: $($ErrorRecord.InvocationInfo.PositionMessage)"
        $errorDetails += "  Stack Trace:"
        $errorDetails += $ErrorRecord.ScriptStackTrace -split "`n" | ForEach-Object { "    $_" }
    }
    
    $fullMessage = $errorDetails -join "`n"
    
    # Write to both log files
    Write-ToLogFile -Message $fullMessage -Level "Error" -LogFile $Script:LogFilePath
    Write-ToLogFile -Message $fullMessage -Level "Error" -LogFile $Script:ErrorLogFilePath
}

function Write-CommandLog {
    <#
    .SYNOPSIS
        Logs command execution with output
    .PARAMETER Command
        The command that was executed
    .PARAMETER Output
        Command output
    .PARAMETER ExitCode
        Exit code of the command
    .PARAMETER Duration
        How long the command took (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$Output,
        
        [Parameter()]
        [int]$ExitCode,
        
        [Parameter()]
        [timespan]$Duration
    )
    
    $logMessage = "Command: $Command"
    
    if ($Duration) {
        $logMessage += " (Duration: $($Duration.TotalSeconds.ToString('F2'))s)"
    }
    
    if ($null -ne $ExitCode) {
        $level = if ($ExitCode -eq 0) { "Info" } else { "Warning" }
        $logMessage += " | Exit Code: $ExitCode"
    }
    else {
        $level = "Info"
    }
    
    Write-ToLogFile -Message $logMessage -Level $level
    
    # Log output if present (truncate if too long)
    if ($Output) {
        $maxOutputLength = 2000
        $outputToLog = if ($Output.Length -gt $maxOutputLength) {
            $Output.Substring(0, $maxOutputLength) + "... [TRUNCATED]"
        }
        else {
            $Output
        }
        
        Write-ToLogFile -Message "  Output: $outputToLog" -Level "Debug"
    }
    
    # Log errors separately
    if ($ExitCode -ne 0 -and $Output) {
        Write-ToLogFile -Message "Command failed: $Command`nOutput: $Output" -Level "Error" -LogFile $Script:ErrorLogFilePath
    }
}

function Write-WSLCommandLog {
    <#
    .SYNOPSIS
        Logs WSL command execution
    .PARAMETER DistroName
        Name of the WSL distribution
    .PARAMETER Command
        The command executed in WSL
    .PARAMETER Output
        Command output
    .PARAMETER ExitCode
        Exit code
    .PARAMETER User
        User who ran the command
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [string]$Output,
        
        [Parameter()]
        [int]$ExitCode,
        
        [Parameter()]
        [string]$User
    )
    
    $userInfo = if ($User) { " (user: $User)" } else { "" }
    $logMessage = "WSL[$DistroName]$userInfo`: $Command"
    
    $level = if ($ExitCode -eq 0) { "Info" } else { "Warning" }
    
    Write-ToLogFile -Message "$logMessage | Exit: $ExitCode" -Level $level
    
    if ($Output -and $ExitCode -ne 0) {
        Write-ToLogFile -Message "WSL Command failed: $Command`nDistro: $DistroName`nOutput: $Output" -Level "Error" -LogFile $Script:ErrorLogFilePath
    }
}

#endregion

#region Log Rotation

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Rotates log files when they exceed max size
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFile
    )
    
    if (-not (Test-Path $LogFile)) {
        return
    }
    
    try {
        $directory = Split-Path $LogFile -Parent
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($LogFile)
        $extension = [System.IO.Path]::GetExtension($LogFile)
        
        # Rotate existing files
        for ($i = $Script:MaxLogFiles - 1; $i -ge 1; $i--) {
            $oldFile = Join-Path $directory "$baseName.$i$extension"
            $newFile = Join-Path $directory "$baseName.$($i + 1)$extension"
            
            if (Test-Path $oldFile) {
                if ($i -eq ($Script:MaxLogFiles - 1)) {
                    Remove-Item $oldFile -Force
                }
                else {
                    Move-Item $oldFile $newFile -Force
                }
            }
        }
        
        # Rename current log file
        $rotatedFile = Join-Path $directory "$baseName.1$extension"
        Move-Item $LogFile $rotatedFile -Force
        
        # Create new log file with rotation notice
        $rotationMessage = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [INFO   ] Log rotated from $rotatedFile"
        Set-Content -Path $LogFile -Value $rotationMessage -Encoding UTF8
    }
    catch {
        Write-Verbose "Log rotation failed: $($_.Exception.Message)"
    }
}

function Clear-OldLogs {
    <#
    .SYNOPSIS
        Removes log files older than specified days
    .PARAMETER DaysToKeep
        Number of days to keep log files
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$DaysToKeep = 30
    )
    
    if (-not $Script:LogDirectory -or -not (Test-Path $Script:LogDirectory)) {
        return
    }
    
    try {
        $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
        
        Get-ChildItem -Path $Script:LogDirectory -Filter "*.log" |
            Where-Object { $_.LastWriteTime -lt $cutoffDate } |
            ForEach-Object {
                Write-ToLogFile -Message "Removing old log file: $($_.Name)" -Level "Info"
                Remove-Item $_.FullName -Force
            }
    }
    catch {
        Write-Verbose "Failed to clear old logs: $($_.Exception.Message)"
    }
}

#endregion

#region Log Viewing

function Get-RecentLogs {
    <#
    .SYNOPSIS
        Gets recent log entries
    .PARAMETER Lines
        Number of lines to retrieve
    .PARAMETER Level
        Filter by log level
    .PARAMETER ErrorsOnly
        Only show error logs
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$Lines = 50,
        
        [Parameter()]
        [ValidateSet("Debug", "Info", "Warning", "Error", "All")]
        [string]$Level = "All",
        
        [Parameter()]
        [switch]$ErrorsOnly
    )
    
    $logFile = if ($ErrorsOnly) { $Script:ErrorLogFilePath } else { $Script:LogFilePath }
    
    if (-not $logFile -or -not (Test-Path $logFile)) {
        Write-Warning "Log file not found: $logFile"
        return @()
    }
    
    $content = Get-Content $logFile -Tail $Lines
    
    if ($Level -ne "All") {
        $content = $content | Where-Object { $_ -match "\[$Level\s*\]" }
    }
    
    return $content
}

function Get-LogSummary {
    <#
    .SYNOPSIS
        Gets a summary of log statistics
    #>
    [CmdletBinding()]
    param()
    
    if (-not $Script:LogFilePath -or -not (Test-Path $Script:LogFilePath)) {
        return $null
    }
    
    $content = Get-Content $Script:LogFilePath
    
    $summary = [PSCustomObject]@{
        TotalEntries = $content.Count
        Errors       = ($content | Where-Object { $_ -match "\[ERROR\s*\]" }).Count
        Warnings     = ($content | Where-Object { $_ -match "\[WARNING\s*\]" }).Count
        LogFile      = $Script:LogFilePath
        ErrorLogFile = $Script:ErrorLogFilePath
        LogSize      = if (Test-Path $Script:LogFilePath) { (Get-Item $Script:LogFilePath).Length } else { 0 }
    }
    
    return $summary
}

function Show-LogViewer {
    <#
    .SYNOPSIS
        Interactive log viewer for console
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$ErrorsOnly
    )
    
    $logFile = if ($ErrorsOnly) { $Script:ErrorLogFilePath } else { $Script:LogFilePath }
    
    if (-not $logFile -or -not (Test-Path $logFile)) {
        Write-Host "No log file found." -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "=== Log Viewer ===" -ForegroundColor Cyan
    Write-Host "Log file: $logFile" -ForegroundColor DarkGray
    Write-Host ""
    
    $content = Get-Content $logFile
    
    foreach ($line in $content) {
        $color = "White"
        if ($line -match "\[ERROR\s*\]") { $color = "Red" }
        elseif ($line -match "\[WARNING\s*\]") { $color = "Yellow" }
        elseif ($line -match "\[DEBUG\s*\]") { $color = "Gray" }
        elseif ($line -match "\[INFO\s*\]") { $color = "White" }
        
        Write-Host $line -ForegroundColor $color
    }
}

#endregion

#region Export Log

function Export-LogReport {
    <#
    .SYNOPSIS
        Exports a formatted log report
    .PARAMETER OutputPath
        Path for the report file
    .PARAMETER IncludeSystemInfo
        Include system information in report
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter()]
        [switch]$IncludeSystemInfo
    )
    
    $report = @()
    $report += "=" * 60
    $report += "OpenClaw Installation Log Report"
    $report += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "=" * 60
    $report += ""
    
    if ($IncludeSystemInfo) {
        $report += "SYSTEM INFORMATION"
        $report += "-" * 40
        $report += "OS: $([System.Environment]::OSVersion.VersionString)"
        $report += "PowerShell: $($PSVersionTable.PSVersion)"
        $report += "User: $env:USERNAME"
        $report += "Computer: $env:COMPUTERNAME"
        $report += ""
    }
    
    $summary = Get-LogSummary
    if ($summary) {
        $report += "LOG SUMMARY"
        $report += "-" * 40
        $report += "Total Entries: $($summary.TotalEntries)"
        $report += "Errors: $($summary.Errors)"
        $report += "Warnings: $($summary.Warnings)"
        $report += "Log Size: $([math]::Round($summary.LogSize / 1KB, 2)) KB"
        $report += ""
    }
    
    if ($Script:ErrorLogFilePath -and (Test-Path $Script:ErrorLogFilePath)) {
        $report += "ERROR LOG"
        $report += "-" * 40
        $report += Get-Content $Script:ErrorLogFilePath
        $report += ""
    }
    
    $report += "FULL LOG"
    $report += "-" * 40
    if ($Script:LogFilePath -and (Test-Path $Script:LogFilePath)) {
        $report += Get-Content $Script:LogFilePath
    }
    
    $report | Set-Content $OutputPath -Encoding UTF8
    
    Write-Host "Log report exported to: $OutputPath" -ForegroundColor Green
    return $OutputPath
}

#endregion

# Export module members
Export-ModuleMember -Function @(
    # Initialization
    'Initialize-Logging',
    'Get-LogDirectory',
    'Get-LogFilePath',
    'Get-ErrorLogFilePath',
    'Test-LoggingEnabled',
    
    # Core Logging
    'Write-Log',
    'Write-ToLogFile',
    'Write-ErrorLog',
    'Write-CommandLog',
    'Write-WSLCommandLog',
    
    # Log Management
    'Invoke-LogRotation',
    'Clear-OldLogs',
    
    # Log Viewing
    'Get-RecentLogs',
    'Get-LogSummary',
    'Show-LogViewer',
    
    # Export
    'Export-LogReport'
)
