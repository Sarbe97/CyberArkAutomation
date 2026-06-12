# =============================================================================
# SVC_Notifications.ps1
# Handles generating and sending summary emails for ServiceAccountAnalysis.
# =============================================================================

function Send-SVCRunSummary {
    param(
        [Parameter(Mandatory=$true)] [hashtable] $Tokens,
        [Parameter(Mandatory=$true)] [string]    $AnalysisReportFile,
        [Parameter(Mandatory=$true)] [PSCustomObject] $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [array]     $AdminTo,
        [Parameter(Mandatory=$false)][array]     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]    $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]    $ScriptName,
        [Parameter(Mandatory=$true)] [string]    $LogPath,
        [Parameter(Mandatory=$false)][string]    $FromOverride = ""
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
    
    $fromAddress = if ($FromOverride) { $FromOverride } else { $GlobalEmailConfig.FromAddress }

    $attachments = @()
    if (Test-Path $AnalysisReportFile) { $attachments += $AnalysisReportFile }

    Send-SchedulerEmail `
        -SmtpServer  $GlobalEmailConfig.SmtpServer `
        -SmtpPort    $GlobalEmailConfig.SmtpPort `
        -From        $fromAddress `
        -To          $AdminTo `
        -Cc          $AdminCC `
        -Subject     $subject `
        -BodyHtml    $htmlBody `
        -Attachments $attachments `
        -ScriptName  $ScriptName `
        -LogPath     $LogPath

    Write-Log -Message "Run Summary Email sent to: $($AdminTo -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
}
