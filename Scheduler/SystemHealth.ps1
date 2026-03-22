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

Write-Log -Message "[DEBUG] Config loaded successfully" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] SystemHealth Enabled: $($config.Features.SystemHealth.Enabled)" -ScriptName $ScriptName -LogPath $LogPath

if (-not $config.Features.SystemHealth.Enabled) {
    Write-Log -Message "SystemHealth feature disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ------------------------
# Get Credential from CCP and Login
# ------------------------
Write-Log -Message "[DEBUG] ============ AUTHENTICATION ============" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] Retrieving CCP credentials..." -ScriptName $ScriptName -LogPath $LogPath
$Credential = Get-CCPCredential -CCPConfig $config.CCP -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] CCP credentials retrieved for user: $($Credential.Username)" -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "[DEBUG] Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] CyberArk API connection established" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Call System Health APIs
# ------------------------
Write-Log -Message "[DEBUG] ============ SYSTEM HEALTH API CALLS ============" -ScriptName $ScriptName -LogPath $LogPath
try {
    Write-Log -Message "[DEBUG] Calling System Summary API: $BaseUrl$SystemSummaryApi" -ScriptName $ScriptName -LogPath $LogPath
    $Summary = Invoke-CyberArkApi -Uri "$BaseUrl$SystemSummaryApi"
    Write-Log -Message "[DEBUG] Summary API Response - OverallStatus: $($Summary.OverallStatus)" -ScriptName $ScriptName -LogPath $LogPath

    Write-Log -Message "[DEBUG] Calling System Details API: $BaseUrl$SystemDetailsApi" -ScriptName $ScriptName -LogPath $LogPath
    $Details = Invoke-CyberArkApi -Uri "$BaseUrl$SystemDetailsApi"
    Write-Log -Message "[DEBUG] Details API Response - Components count: $($Details.Components.Count)" -ScriptName $ScriptName -LogPath $LogPath
    
    # Log each component
    if ($Details.Components) {
        foreach ($comp in $Details.Components) {
            Write-Log -Message "[DEBUG]   Component: $($comp.ComponentName) | Status: $($comp.Status)" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
}
catch {
    Write-Log -Message "System Health API call failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

# ------------------------
# Prepare Email Content using Template
# ------------------------
Write-Log -Message "[DEBUG] ============ PREPARE EMAIL CONTENT ============" -ScriptName $ScriptName -LogPath $LogPath

# Determine status class for styling
$statusClass = switch -Regex ($Summary.OverallStatus) {
    "Healthy|OK|Good" { "status-healthy" }
    "Warning" { "status-warning" }
    default { "status-critical" }
}
Write-Log -Message "[DEBUG] Status class determined: $statusClass" -ScriptName $ScriptName -LogPath $LogPath

# Build component table HTML
$componentRows = ""
if ($Details.Components) {
    Write-Log -Message "[DEBUG] Building component table with $($Details.Components.Count) components" -ScriptName $ScriptName -LogPath $LogPath
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
Write-Log -Message "[DEBUG] Template data prepared" -ScriptName $ScriptName -LogPath $LogPath

$EmailBody = Get-TemplateContent -TemplateName "SystemHealth" -Data $templateData
Write-Log -Message "[DEBUG] Email body generated from template" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Send Email
# ------------------------
Write-Log -Message "[DEBUG] ============ SEND EMAIL ============" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] Email To: $($config.Email.To -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] Email Subject: CyberArk System Health Report - $($Summary.OverallStatus)" -ScriptName $ScriptName -LogPath $LogPath

Send-SchedulerEmail `
    -Subject "CyberArk System Health Report - $($Summary.OverallStatus)" `
    -Body $EmailBody `
    -EmailConfig $config.Email `
    -IsHtml `
    -ScriptName $ScriptName `
    -LogPath $LogPath

# ------------------------
# Cleanup
# ------------------------
Write-Log -Message "[DEBUG] ============ CLEANUP ============" -ScriptName $ScriptName -LogPath $LogPath
Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "[DEBUG] ============ EXECUTION COMPLETE ============" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
