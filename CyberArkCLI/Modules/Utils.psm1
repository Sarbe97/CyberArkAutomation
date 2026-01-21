# ============================================================================
# MODULE: Utils.psm1
# DESCRIPTION: Logging and utility functions for CyberArk CLI
# ============================================================================

# Script-scope log file path
$Script:LogFile = $null

function Initialize-CACLogging {
    [CmdletBinding()]
    param(
        [string]$LogDir = "$PSScriptRoot/../Logs",
        [string]$Prefix = "CAC"
    )

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $Script:LogFile = Join-Path $LogDir "${Prefix}_${timestamp}.log"
    
    Write-Log "Logging initialized: $Script:LogFile" "INFO"
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false)]
        [string]$CustomLogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Determine log file
    $targetLog = if ($CustomLogFile) { $CustomLogFile } else { $Script:LogFile }

    # Write to log file if available
    if ($targetLog) {
        try {
            Add-Content -Path $targetLog -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # Console output with colors
    $color = switch ($Level) {
        "DEBUG" { "Gray" }
        "INFO" { "White" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        default { "White" }
    }

    # Only show non-debug messages on console (unless verbose)
    if ($Level -ne "DEBUG" -or $VerbosePreference -eq "Continue") {
        Write-Host $logEntry -ForegroundColor $color
    }
}

function Convert-CACTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $UnixTimestamp
    )

    process {
        if ($null -eq $UnixTimestamp -or $UnixTimestamp -eq 0) {
            return "N/A"
        }

        try {
            # Handle both seconds and milliseconds
            if ($UnixTimestamp -gt 9999999999) {
                $UnixTimestamp = $UnixTimestamp / 1000
            }
            return [DateTimeOffset]::FromUnixTimeSeconds($UnixTimestamp).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            return "Invalid"
        }
    }
}

function Get-CACOutputDir {
    param(
        [string]$SubFolder = ""
    )

    $baseDir = "$PSScriptRoot/../Output"
    $targetDir = if ($SubFolder) { Join-Path $baseDir $SubFolder } else { $baseDir }

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    return (Resolve-Path $targetDir).Path
}

Export-ModuleMember -Function Initialize-CACLogging, Write-Log, Convert-CACTimestamp, Get-CACOutputDir
