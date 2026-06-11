# =============================================================================
# SAA_Notifications.ps1
# All email notifications for SecondaryAccountAnalysis.
# Uses Get-TemplateContent (Utils.ps1) for {{Token}} HTML rendering.
# Uses Send-SchedulerEmail / Send-SchedulerEmailWithAttachment (Utils.ps1) for delivery.
#
# Exposes:
#   Send-SAAUserSuccessNotification   - Successful onboarding → primary account's email
#   Send-SAARunSummary                - End-of-run summary email with CSV attachments
# =============================================================================

# ---------------------------------------------------------------------------
# Internal: Build an email config PSCustomObject with overridden recipients.
# Allows sending to specific To/CC while reusing SmtpServer and From from config.
# ---------------------------------------------------------------------------
function Get-SAAEmailConfig {
    param (
        [PSCustomObject] $GlobalEmailConfig,
        [string[]]       $To,
        [string[]]       $CC = @(),
        [string[]]       $Bcc = @(),
        [string]         $FromOverride = ""
    )

    $obj = [PSCustomObject]@{
        SmtpServer = $GlobalEmailConfig.SmtpServer
        From       = if (-not [string]::IsNullOrWhiteSpace($FromOverride)) { $FromOverride } else { $GlobalEmailConfig.From }
        To         = $To
        CC         = $CC
        Bcc        = $Bcc
    }
    return $obj
}


# ---------------------------------------------------------------------------
# Send-SAAUserSuccessNotification
# Sent to the primary account's email address (from AD mail attribute) after
# their secondary account is successfully onboarded.
# If UseADMailAttribute=true and no mail was found, falls back to constructing
# address from UserEmailFallbackDomain.
# In SimulationMode: logs only.
# ---------------------------------------------------------------------------
function Send-SAAUserSuccessNotification {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [string]          $UserEmail,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [string] $FromOverride = "",
        [string[]] $Bcc = @(),
        [bool] $SimulationMode = $false
    )

    if ([string]::IsNullOrWhiteSpace($UserEmail)) {
        Write-Log -Message "No email address for primary account '$($Tokens['PrimaryAccount'])'. User notification skipped." `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would send success notification to '$UserEmail' for secondary account '$($Tokens['SecondaryAccount'])'" `
            -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    try {
        $body     = Get-TemplateContent -TemplateName "UserNotification_Success" -Data $Tokens -TemplatesPath $TemplatesPath
        $subject  = "CyberArk Secondary Account Onboarding Notification - $($Tokens['PrimaryAccount'])"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To @($UserEmail) -FromOverride $FromOverride -Bcc $Bcc
        Send-SchedulerEmail -Subject $subject -Body $body -EmailConfig $emailCfg -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send user success notification to '$UserEmail': $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}

# ---------------------------------------------------------------------------
# Send-SAARunSummary
# Sent to admins at the end of a Simulation or Onboarding run.
# Attaches CSV reports with results and planned actions.
# ---------------------------------------------------------------------------
function Send-SAARunSummary {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [string]          $AnalysisReportFile,
        [Parameter(Mandatory=$false)][string]          $OnboardingResultsFile,
        [Parameter(Mandatory=$false)][string]          $SkippedAccountsFile,
        [Parameter(Mandatory=$false)][string]          $MissingGroupFile,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string[]]        $AdminTo,
        [string[]]                                     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [string]                                       $FromOverride = ""
    )

    try {
        $body     = Get-TemplateContent -TemplateName "RunSummary" -Data $Tokens -TemplatesPath $TemplatesPath
        $modeStr  = if ($Tokens["EffectiveMode"] -eq "Simulation") { "Simulation" } else { "Execution" }
        $subject  = "CyberArk SAA: $modeStr Run Complete - $(Get-Date -Format 'yyyy-MM-dd')"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To $AdminTo -CC $AdminCC -FromOverride $FromOverride

        $attachments = @($AnalysisReportFile, $OnboardingResultsFile, $SkippedAccountsFile, $MissingGroupFile) | Where-Object { $_ -and (Test-Path $_) }

        Send-SchedulerEmailWithAttachment -Subject $subject -Body $body -EmailConfig $emailCfg `
            -Attachments $attachments -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send run summary email: $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}
