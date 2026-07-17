# =============================================================================
# PSA_Notifications.ps1
# Handles generating and sending summary emails for PersonalSafeAnalysis.
# =============================================================================

function Send-PSARunSummary {
    param(
        [Parameter(Mandatory=$true)] [hashtable] $Tokens,
        [Parameter(Mandatory=$true)] [string]    $AnalysisReportFile,
        [Parameter(Mandatory=$false)][string]    $BlankSafesReportFile = "",
        [Parameter(Mandatory=$true)] [PSCustomObject] $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [array]     $AdminTo,
        [Parameter(Mandatory=$false)][array]     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]    $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]    $ScriptName,
        [Parameter(Mandatory=$true)] [string]    $LogPath,
        [Parameter(Mandatory=$false)][string]    $FromOverride = ""
    )

    if (-not $AdminTo -or $AdminTo.Count -eq 0) {
        Write-Log -Message "Send-PSARunSummary: No AdminTo recipients specified. Skipping summary email." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    $templatePath = Join-Path $TemplatesPath "RunSummary.html"
    if (-not (Test-Path $templatePath)) {
        Write-Log -Message "Send-PSARunSummary: Template not found at $templatePath" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    Write-Log -Message "Generating Run Summary Email for Admins..." -ScriptName $ScriptName -LogPath $LogPath
    $htmlBody = Get-TemplateContent -TemplateName "RunSummary" -Data $Tokens -TemplatesPath $TemplatesPath

    $subject = "CyberArk Automated Report - Personal Safe Analysis ($($Tokens.EffectiveMode))"
    
    $fromAddress = if ($FromOverride) { $FromOverride } else { $GlobalEmailConfig.From }

    $attachments = @()
    if (Test-Path $AnalysisReportFile) { $attachments += $AnalysisReportFile }
    if ($BlankSafesReportFile -and (Test-Path $BlankSafesReportFile)) { $attachments += $BlankSafesReportFile }

    $emailCfg = [PSCustomObject]@{
        SmtpServer = $GlobalEmailConfig.SmtpServer
        From       = $fromAddress
        To         = $AdminTo
        CC         = $AdminCC
        Bcc        = @()
    }

    Send-SchedulerEmailWithAttachment `
        -Subject     $subject `
        -Body        $htmlBody `
        -EmailConfig $emailCfg `
        -Attachments $attachments `
        -IsHtml `
        -ScriptName  $ScriptName `
        -LogPath     $LogPath

    Write-Log -Message "Run Summary Email sent to: $($AdminTo -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
}
