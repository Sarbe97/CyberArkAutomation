# =============================================================================
# SAA_Notifications.ps1
# All email notifications for SecondaryAccountAnalysis.
# Uses Get-TemplateContent (Utils.ps1) for {{Token}} HTML rendering.
# Uses Send-SchedulerEmail / Send-SchedulerEmailWithAttachment (Utils.ps1) for delivery.
#
# Exposes:
#   Send-SAAAdminMissingAccessAlert   - Primary not in required CyberArk group
#   Send-SAASafeCreatedAlert          - Personal safe successfully created
#   Send-SAAFailureAlert              - Onboarding or safe creation failure
#   Send-SAAUserSuccessNotification   - Successful onboarding → primary account's email
#   Send-SAASimulationSummary         - End-of-simulation summary with attachments
# =============================================================================

# ---------------------------------------------------------------------------
# Internal: Build an email config PSCustomObject with overridden recipients.
# Allows sending to specific To/CC while reusing SmtpServer and From from config.
# ---------------------------------------------------------------------------
function Get-SAAEmailConfig {
    param (
        [PSCustomObject] $GlobalEmailConfig,
        [string[]]       $To,
        [string[]]       $CC = @()
    )

    $obj = [PSCustomObject]@{
        SmtpServer = $GlobalEmailConfig.SmtpServer
        From       = $GlobalEmailConfig.From
        To         = $To
    }
    return $obj
}

# ---------------------------------------------------------------------------
# Send-SAAAdminMissingAccessAlert
# Triggered when the primary account is NOT a member of the required group.
# In SimulationMode: logs only, does not send email.
# ---------------------------------------------------------------------------
function Send-SAAAdminMissingAccessAlert {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string[]]        $AdminTo,
        [string[]]                                     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would send MissingAccess admin alert - Primary: $($Tokens['PrimaryAccount']), Group: $($Tokens['RequiredGroup'])" `
            -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    try {
        $body     = Get-TemplateContent -TemplateName "AdminAlert_MissingAccess" -Data $Tokens -TemplatesPath $TemplatesPath
        $subject  = "CyberArk Alert: Missing Group Access - $($Tokens['PrimaryAccount'])"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To $AdminTo -CC $AdminCC
        Send-SchedulerEmail -Subject $subject -Body $body -EmailConfig $emailCfg -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send MissingAccess alert for '$($Tokens['PrimaryAccount'])': $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}

# ---------------------------------------------------------------------------
# Send-SAASafeCreatedAlert
# Sent to admins when a personal safe is successfully created.
# In SimulationMode: logs only.
# ---------------------------------------------------------------------------
function Send-SAASafeCreatedAlert {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string[]]        $AdminTo,
        [string[]]                                     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would send SafeCreated admin alert - Safe: $($Tokens['SafeName'])" `
            -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    try {
        $body     = Get-TemplateContent -TemplateName "AdminAlert_SafeCreated" -Data $Tokens -TemplatesPath $TemplatesPath
        $subject  = "CyberArk: Personal Safe Created - $($Tokens['SafeName'])"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To $AdminTo -CC $AdminCC
        Send-SchedulerEmail -Subject $subject -Body $body -EmailConfig $emailCfg -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send SafeCreated alert for '$($Tokens['SafeName'])': $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}

# ---------------------------------------------------------------------------
# Send-SAAFailureAlert
# Sent to admins when any onboarding or safe creation operation fails.
# In SimulationMode: logs only.
# ---------------------------------------------------------------------------
function Send-SAAFailureAlert {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string[]]        $AdminTo,
        [string[]]                                     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would send Failure admin alert - Primary: $($Tokens['PrimaryAccount']), Error: $($Tokens['ErrorMessage'])" `
            -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    try {
        $body     = Get-TemplateContent -TemplateName "AdminAlert_Failure" -Data $Tokens -TemplatesPath $TemplatesPath
        $subject  = "CyberArk ALERT: Onboarding Failed - $($Tokens['PrimaryAccount'])"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To $AdminTo -CC $AdminCC
        Send-SchedulerEmail -Subject $subject -Body $body -EmailConfig $emailCfg -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send Failure alert for '$($Tokens['PrimaryAccount'])': $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
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
        $subject  = "Your CyberArk Personal Safe is Ready - $($Tokens['SafeName'])"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To @($UserEmail)
        Send-SchedulerEmail -Subject $subject -Body $body -EmailConfig $emailCfg -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send user success notification to '$UserEmail': $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}

# ---------------------------------------------------------------------------
# Send-SAASimulationSummary
# Sent to admins at the end of a Simulation run.
# Attaches PlannedActions.csv and AnalysisReport.csv.
# ---------------------------------------------------------------------------
function Send-SAASimulationSummary {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [string]          $PlannedActionsFile,
        [Parameter(Mandatory=$true)] [string]          $AnalysisReportFile,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $GlobalEmailConfig,
        [Parameter(Mandatory=$true)] [string[]]        $AdminTo,
        [string[]]                                     $AdminCC = @(),
        [Parameter(Mandatory=$true)] [string]          $TemplatesPath,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath
    )

    try {
        $body     = Get-TemplateContent -TemplateName "SimulationSummary" -Data $Tokens -TemplatesPath $TemplatesPath
        $subject  = "CyberArk SAA: Simulation Run Complete - $(Get-Date -Format 'yyyy-MM-dd')"
        $emailCfg = Get-SAAEmailConfig -GlobalEmailConfig $GlobalEmailConfig -To $AdminTo -CC $AdminCC

        $attachments = @($PlannedActionsFile, $AnalysisReportFile) | Where-Object { Test-Path $_ }

        Send-SchedulerEmailWithAttachment -Subject $subject -Body $body -EmailConfig $emailCfg `
            -Attachments $attachments -IsHtml `
            -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send simulation summary email: $($_.Exception.Message)" `
            -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }
}
