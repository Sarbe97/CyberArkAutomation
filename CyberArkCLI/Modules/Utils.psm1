# ==========================
# Utils.psm1
# ==========================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG","SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "DEBUG"   { "DarkGray" }
        "SUCCESS" { "Green" }
    }

    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
}

Export-ModuleMember -Function Write-Log
