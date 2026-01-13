$RootPath = $PSScriptRoot
$LogPath = Join-Path $RootPath "Logs\Main-$(Get-Date -Format yyyyMMdd).log"

function Write-Log {
    param ($Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Main] $Message" |
    Tee-Object -FilePath $LogPath -Append
}

Write-Log "Main execution started"

& "$RootPath\SystemHealth.ps1"

Write-Log "Main execution completed"
