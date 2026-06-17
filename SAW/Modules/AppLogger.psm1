#========================================================================
# AppLogger.psm1 - Application Logging Module
# SECURITY: Never logs passwords, credentials, or secure strings
# Thread-safe via Mutex for background runspace access
#========================================================================

$script:LogFile  = $null
$script:LogMutex = [System.Threading.Mutex]::new($false, 'SAW_LogMutex')
$script:MinLevel = 'INFO'

$script:LevelOrder = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }

function Initialize-AppLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string]$MinLevel = 'INFO'
    )

    $script:MinLevel = $MinLevel
    $date            = Get-Date -Format 'yyyyMMdd'
    $script:LogFile  = Join-Path $LogDirectory "SAW_$date.log"

    # Rotate logs older than 30 days
    Get-ChildItem -Path $LogDirectory -Filter 'SAW_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    _WriteEntry 'INFO' 'AppLogger' '========================================================'
    _WriteEntry 'INFO' 'AppLogger' 'Server Access Workbench (SAW) - Session Started'
    _WriteEntry 'INFO' 'AppLogger' "Log file: $script:LogFile"
    _WriteEntry 'INFO' 'AppLogger' "PowerShell version: $($PSVersionTable.PSVersion)"
    _WriteEntry 'INFO' 'AppLogger' '========================================================'
}

function Write-NexusLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string]$Level = 'INFO',

        [System.Exception]$Exception = $null,

        [string]$Component = 'SAW'
    )

    if (-not $script:LogFile) { return }
    if ($script:LevelOrder[$Level] -lt $script:LevelOrder[$script:MinLevel]) { return }

    _WriteEntry $Level $Component $Message $Exception
}

function _WriteEntry {
    param([string]$Level, [string]$Component, [string]$Message, [System.Exception]$Exception = $null)

    # Security filter - strip any credential-looking tokens
    $safe = $Message -replace '(?i)(password|passwd|pwd|secret|token)\s*[=:]\s*\S+', '$1=***'

    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = "[$ts] [$($Level.PadRight(5))] [$Component] $safe"

    if ($Exception) {
        $entry += "`n              Exception : $($Exception.Message)"
        if ($Exception.StackTrace) {
            $firstLine = ($Exception.StackTrace -split "`n" | Select-Object -First 1).Trim()
            $entry += "`n              At        : $firstLine"
        }
    }

    $acquired = $false
    try {
        $acquired = $script:LogMutex.WaitOne(500)
        if ($acquired) {
            Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
        }
    }
    catch { } # Never let logging crash the app
    finally {
        if ($acquired) { $script:LogMutex.ReleaseMutex() }
    }
}

Export-ModuleMember -Function Initialize-AppLogger, Write-NexusLog
