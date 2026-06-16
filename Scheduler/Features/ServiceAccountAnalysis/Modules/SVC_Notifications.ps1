# =============================================================================
# SVC_Notifications.ps1
# Handles generating and sending summary emails for ServiceAccountAnalysis.
# =============================================================================

# ---------------------------------------------------------------------------
# Resolve-SAATemplate
# Replaces {{TokenName}} placeholders in an HTML template with token values.
# ---------------------------------------------------------------------------
function Resolve-SAATemplate {
    param(
        [Parameter(Mandatory=$true)] [string]    $TemplatePath,
        [Parameter(Mandatory=$true)] [hashtable] $Tokens
    )
    $content = Get-Content -Path $TemplatePath -Raw
    foreach ($key in $Tokens.Keys) {
        $placeholder = "{{$key}}"
        $value       = if ($null -ne $Tokens[$key]) { [string]$Tokens[$key] } else { "" }
        $content     = $content -replace [regex]::Escape($placeholder), $value
    }
    return $content
}

# ---------------------------------------------------------------------------
# Send-SVCRunSummary
# Generates the HTML summary email and sends it to configured admin recipients.
# ---------------------------------------------------------------------------
function Send-SVCRunSummary {
    param(
        [Parameter(Mandatory=$true)] [hashtable]     $Tokens,
        [Parameter(Mandatory=$true)] [string]        $AnalysisReportFile,
        [Parameter(Mandatory=$true)] [PSCustomObject] $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [array]         $AdminTo,
        [Parameter(Mandatory=$false)][array]         $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]        $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]        $ScriptName,
        [Parameter(Mandatory=$true)] [string]        $LogPath,
        [Parameter(Mandatory=$false)][string]        $FromOverride = ""
    )

    if (-not $AdminTo -or $AdminTo.Count -eq 0) {
        Write-Log -Message "Send-SVCRunSummary: No AdminTo recipients specified. Skipping summary email." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    $templatePath = Join-Path $TemplatesPath "RunSummary.html"
    if (-not (Test-Path $templatePath)) {
        Write-Log -Message "Send-SVCRunSummary: Template not found at $templatePath" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    Write-Log -Message "Generating Run Summary Email for Admins..." -ScriptName $ScriptName -LogPath $LogPath
    $htmlBody = Resolve-SAATemplate -TemplatePath $templatePath -Tokens $Tokens

    $subject = "CyberArk Automated Report - Service Account Analysis ($($Tokens.EffectiveMode))"

    $fromAddress = if ($FromOverride) { $FromOverride } else { $GlobalEmailConfig.From }

    $attachments = @()
    if (Test-Path $AnalysisReportFile) { $attachments += $AnalysisReportFile }

    $mailParams = @{
        SmtpServer = $GlobalEmailConfig.SmtpServer
        From       = $fromAddress
        To         = $AdminTo
        Subject    = $subject
        Body       = $htmlBody
        BodyAsHtml = $true
    }
    if ($GlobalEmailConfig.SmtpPort) {
        $mailParams["Port"] = $GlobalEmailConfig.SmtpPort
    }
    if ($AdminCC -and $AdminCC.Count -gt 0) {
        $mailParams["Cc"] = $AdminCC
    }
    if ($attachments.Count -gt 0) {
        $mailParams["Attachments"] = $attachments
    }

    try {
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Log -Message "Run Summary Email sent to: $($AdminTo -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send Run Summary Email: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    }
}
