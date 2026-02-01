param ()

# ------------------------
# Script Identity
# ------------------------
$ScriptName = "SystemHealth"
$RootPath = $PSScriptRoot
$ConfigPath = Join-Path $RootPath "config.json"
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"

# ------------------------
# Load Utils
# ------------------------
. (Join-Path $RootPath "Utils.ps1")

# ------------------------
# CyberArk System Health API Endpoints
# ------------------------
$SystemSummaryApi = "/PasswordVault/api/SystemHealth/Summary"
$SystemDetailsApi = "/PasswordVault/api/SystemHealth/Details"

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Load Common Config
# ------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Log -Message "Common.json not found at $ConfigPath" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$BaseUrl = $config.BaseUrl

if (-not $config.Features.SystemHealth.Enabled) {
    Write-Log -Message "SystemHealth feature disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ------------------------
# Get Credential from CCP
# ------------------------
$Credential = Get-CCPCredential -CCPConfig $config.CCP -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Call System Health APIs
# ------------------------
try {
    Write-Log -Message "Calling System Summary API" -ScriptName $ScriptName -LogPath $LogPath
    $Summary = Invoke-CyberArkApi `
        -Uri "$BaseUrl$SystemSummaryApi" `
        -Credential $Credential

    Write-Log -Message "Calling System Details API" -ScriptName $ScriptName -LogPath $LogPath
    $Details = Invoke-CyberArkApi `
        -Uri "$BaseUrl$SystemDetailsApi" `
        -Credential $Credential
}
catch {
    Write-Log -Message "System Health API call failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

# ------------------------
# Prepare Email Content using Template
# ------------------------

# Determine status class for styling
$statusClass = switch -Regex ($Summary.OverallStatus) {
    "Healthy|OK|Good" { "status-healthy" }
    "Warning" { "status-warning" }
    default { "status-critical" }
}

# Build component table HTML
$componentRows = ""
if ($Details.Components) {
    foreach ($comp in $Details.Components) {
        $componentRows += "<tr><td>$($comp.ComponentName)</td><td>$($comp.Status)</td><td>$($comp.Details)</td></tr>"
    }
}
$componentTable = "<table><tr><th>Component</th><th>Status</th><th>Details</th></tr>$componentRows</table>"

# Prepare template data
$templateData = @{
    GeneratedDate  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    OverallStatus  = $Summary.OverallStatus
    StatusClass    = $statusClass
    ComponentTable = $componentTable
}

$EmailBody = Get-TemplateContent -TemplateName "SystemHealth" -Data $templateData

# ------------------------
# Send Email
# ------------------------
Send-SchedulerEmail `
    -Subject "CyberArk System Health Report - $($Summary.OverallStatus)" `
    -Body $EmailBody `
    -EmailConfig $config.Email `
    -IsHtml `
    -ScriptName $ScriptName `
    -LogPath $LogPath

Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
