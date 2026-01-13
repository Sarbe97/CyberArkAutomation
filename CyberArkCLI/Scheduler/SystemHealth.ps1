param ()

# ------------------------
# Script Identity
# ------------------------
$ScriptName = "SystemHealth"
$RootPath = $PSScriptRoot
$ConfigPath = Join-Path $RootPath "Config\Common.json"
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"

# ------------------------
# CyberArk System Health URLs
# (Intentionally kept here)
# ------------------------
$BaseUrl = "https://vault.company.com"
$SystemSummaryApi = "/PasswordVault/api/SystemHealth/Summary"
$SystemDetailsApi = "/PasswordVault/api/SystemHealth/Details"

# ------------------------
# Logging
# ------------------------
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$time [$ScriptName] [$Level] $Message" |
    Tee-Object -FilePath $LogPath -Append
}

Write-Log "Execution started"

# ------------------------
# Load Common Config
# ------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Common.json not found at $ConfigPath" "ERROR"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $config.Features.SystemHealth.Enabled) {
    Write-Log "SystemHealth feature disabled in config. Skipping."
    exit 0
}

# ------------------------
# Get Credential from CCP
# ------------------------
function Get-CCPCredential {
    param ($CCPConfig)

    try {
        $uri = "$($CCPConfig.Url)?AppID=$($CCPConfig.AppId)&Safe=$($CCPConfig.Safe)"
        Write-Log "Retrieving credential from CCP"

        $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop

        return New-Object PSCredential (
            $resp.UserName,
            (ConvertTo-SecureString $resp.Content -AsPlainText -Force)
        )
    }
    catch {
        Write-Log "CCP credential retrieval failed: $_" "ERROR"
        throw
    }
}

$Credential = Get-CCPCredential -CCPConfig $config.CCP

# ------------------------
# REST API Call Wrapper
# ------------------------
function Invoke-CyberArkApi {
    param (
        [string]$Uri,
        [pscredential]$Credential
    )

    Invoke-RestMethod -Uri $Uri `
        -Method Get `
        -Credential $Credential `
        -ErrorAction Stop
}

# ------------------------
# Call System Health APIs
# ------------------------
try {
    Write-Log "Calling System Summary API"
    $Summary = Invoke-CyberArkApi `
        -Uri "$BaseUrl$SystemSummaryApi" `
        -Credential $Credential

    Write-Log "Calling System Details API"
    $Details = Invoke-CyberArkApi `
        -Uri "$BaseUrl$SystemDetailsApi" `
        -Credential $Credential
}
catch {
    Write-Log "System Health API call failed: $_" "ERROR"
    exit 1
}

# ------------------------
# Prepare Email Content
# ------------------------
$EmailBody = @"
CyberArk System Health Report
Generated: $(Get-Date)

Overall Status:
$($Summary.OverallStatus)

Component Details:
$($Details.Components | Out-String)
"@

# ------------------------
# Send Email
# ------------------------
try {
    Send-MailMessage `
        -SmtpServer $config.Email.SmtpServer `
        -From $config.Email.From `
        -To $config.Email.To `
        -Subject "CyberArk System Health Report" `
        -Body $EmailBody

    Write-Log "System Health email sent successfully"
}
catch {
    Write-Log "Email sending failed: $_" "ERROR"
}

Write-Log "Execution completed"
