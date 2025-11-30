# ==========================
# Utils.psm1
# ==========================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    $color = switch ($Level) {
        "INFO" { "White" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "DarkGray" }
        "SUCCESS" { "Green" }
    }

    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
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