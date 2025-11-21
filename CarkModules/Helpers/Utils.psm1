# Utils.psm1 - Utility functions for your scripts

function ConvertTo-DaysFromEpoch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [long]$EpochSeconds
    )
    $date = [DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds).DateTime
    $days = (Get-Date) - $date
    return $days.Days
}

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO" { Write-Host "$timestamp [INFO] $Message" -ForegroundColor Cyan }
        "WARN" { Write-Host "$timestamp [WARN] $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "$timestamp [ERROR] $Message" -ForegroundColor Red }
    }
}

# Export functions
Export-ModuleMember -Function ConvertTo-DaysFromEpoch, Write-Log
