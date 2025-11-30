# ==========================
# Utils.psm1
# ==========================

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "SUCCESS")]
        [string]$Level = "INFO",

        [bool]$ShowOnScreen = $false,

        [string]$LogDirectory = "$PSScriptRoot/../Logs"
    )

    # ---------------------------------------------------------
    # 1. Ensure log directory exists
    # ---------------------------------------------------------
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }

    # ---------------------------------------------------------
    # 2. Determine today’s log file
    #    Format: cyberark_2025-01-18.log
    # ---------------------------------------------------------
    $today = (Get-Date -Format "yyyy-MM-dd")
    $logFile = Join-Path $LogDirectory "cyberark_$today.log"

    # ---------------------------------------------------------
    # 3. Build log line
    # ---------------------------------------------------------
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp][$Level] $Message"

    # ---------------------------------------------------------
    # 4. Write to log file (auto daily rotation)
    # ---------------------------------------------------------
    try {
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "[LOG ERROR] Cannot write to log file: $logFile" -ForegroundColor Red
    }

    # ---------------------------------------------------------
    # 5. Optional screen output
    # ---------------------------------------------------------
    if ($ShowOnScreen) {
        $color = switch ($Level) {
            "INFO" { "White" }
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            "DEBUG" { "DarkGray" }
            "SUCCESS" { "Green" }
        }

        Write-Host $line -ForegroundColor $color
    }
}

function Convert-CACTimestamp {
    param(
        [Parameter(Mandatory)]
        [long]$Value
    )

    try {
        $digits = $Value.ToString().Length

        switch ($digits) {

            # Seconds (10 digits)
            10 {
                return [DateTimeOffset]::FromUnixTimeSeconds($Value).DateTime
            }

            # Microseconds (16 digits)
            16 {
                $seconds = [math]::Floor($Value / 1e6)
                $microseconds = $Value % 1e6
                $dateTime = [DateTimeOffset]::FromUnixTimeSeconds($seconds).DateTime
                return $dateTime.AddTicks($microseconds * 10)
            }

            default {
                Write-Log "Unknown timestamp format: $Value" "WARN"
                return $null
            }
        }
    }
    catch {
        Write-Log "Timestamp conversion failed for value: $Value → $($_.Exception.Message)" "ERROR"
        return $null
    }
}
Export-ModuleMember -Function * -Alias *