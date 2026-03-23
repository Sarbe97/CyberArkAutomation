$ScriptName = "Main"
$RootPath = $PSScriptRoot
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"

# Load Utils
. (Join-Path $RootPath "Utils.ps1")

Write-Log -Message "Main execution started" -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Launching SystemHealth.ps1..." -ScriptName $ScriptName -LogPath $LogPath
& "$RootPath\SystemHealth.ps1"

Write-Log -Message "Launching LDAPUserAnalysis.ps1..." -ScriptName $ScriptName -LogPath $LogPath
& "$RootPath\LDAPUserAnalysis.ps1"

Write-Log -Message "Launching DashboardReport.ps1..." -ScriptName $ScriptName -LogPath $LogPath
& "$RootPath\DashboardReport.ps1"

Write-Log -Message "Main execution completed" -ScriptName $ScriptName -LogPath $LogPath
