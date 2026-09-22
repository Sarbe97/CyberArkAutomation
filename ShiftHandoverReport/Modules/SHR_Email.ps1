# =============================================================================
# SHR_Email.ps1
# Executive-grade HTML rendering and SMTP email dispatch module
# =============================================================================

function Get-PriorityBadgeHtml {
    param ([string]$PriorityDisplay)
    if ([string]::IsNullOrWhiteSpace($PriorityDisplay)) {
        return "&mdash;"
    }
    $isCrit = ($PriorityDisplay -like "*0*" -or $PriorityDisplay -like "*1*" -or $PriorityDisplay -like "*2*" -or $PriorityDisplay -like "*Critical*" -or $PriorityDisplay -like "*High*")
    $badgeClass = if ($isCrit) { "badge pri-crit" } else { "badge pri-neutral" }
    return "<span class='$badgeClass'>$PriorityDisplay</span>"
}

function Get-StatusBadgeHtml {
    param ([string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) {
        return "&mdash;"
    }
    return "<span class='badge st-badge'>$Status</span>"
}

function Get-HandoverBadgeHtml {
    param ([bool]$IsHandover)
    if ($IsHandover) {
        return "<span class='hnd-yes'>Yes</span>"
    }
    else {
        return "<span class='hnd-no'>No</span>"
    }
}

function Get-IncidentTableHtml {
    param ([System.Collections.IEnumerable]$Incidents)

    if (-not $Incidents -or @($Incidents).Count -eq 0) { return "" }

    $rows = foreach ($inc in $Incidents) {
        $pBadge   = Get-PriorityBadgeHtml -PriorityDisplay $inc.PriorityDisplay
        $sBadge   = Get-StatusBadgeHtml -Status $inc.State
        $hBadge   = Get-HandoverBadgeHtml -IsHandover $inc.IsHandover
        $safeDesc = [System.Web.HttpUtility]::HtmlEncode($inc.ShortDescription)
        $rowStyle = if ($inc.PriorityCode -in @("P0", "P1", "P2")) { "class='row-highlight'" } else { "" }

        @"
                <tr $rowStyle>
                    <td><span class='ticket-num'>$($inc.TicketNumber)</span></td>
                    <td>$pBadge</td>
                    <td>$sBadge</td>
                    <td>$safeDesc</td>
                    <td style='font-weight: 600;'>$($inc.ETA)</td>
                    <td style='text-align: center;'>$hBadge</td>
                </tr>
"@
    }

    return @"
        <table class='styled-table'>
            <thead>
                <tr>
                    <th style='width: 115px;'>Number</th>
                    <th style='width: 105px;'>Priority</th>
                    <th style='width: 95px;'>State</th>
                    <th>Short Description</th>
                    <th style='width: 90px;'>ETA</th>
                    <th style='width: 85px; text-align: center;'>Handed Over</th>
                </tr>
            </thead>
            <tbody>
$($rows -join "`n")
            </tbody>
        </table>
"@
}

function Get-ChangeTableHtml {
    param ([System.Collections.IEnumerable]$Changes)

    if (-not $Changes -or @($Changes).Count -eq 0) { return "" }

    $rows = foreach ($chg in $Changes) {
        $sBadge   = Get-StatusBadgeHtml -Status $chg.State
        $hBadge   = Get-HandoverBadgeHtml -IsHandover $chg.IsHandover
        $safeDesc = [System.Web.HttpUtility]::HtmlEncode($chg.ShortDescription)

        @"
                <tr>
                    <td><span class='ticket-num'>$($chg.TicketNumber)</span></td>
                    <td><span class='badge pri-neutral'>$($chg.TicketType)</span></td>
                    <td>$sBadge</td>
                    <td>$safeDesc</td>
                    <td style='font-weight: 600;'>$($chg.ETA)</td>
                    <td style='text-align: center;'>$hBadge</td>
                </tr>
"@
    }

    return @"
        <table class='styled-table'>
            <thead>
                <tr>
                    <th style='width: 115px;'>Number</th>
                    <th style='width: 75px;'>Type</th>
                    <th style='width: 100px;'>State</th>
                    <th>Short Description</th>
                    <th style='width: 95px;'>ETA</th>
                    <th style='width: 90px; text-align: center;'>Handed Over</th>
                </tr>
            </thead>
            <tbody>
$($rows -join "`n")
            </tbody>
        </table>
"@
}

function Get-CriticalIncidentsTableHtml {
    param ([System.Collections.IEnumerable]$CriticalIncidents)

    if (-not $CriticalIncidents -or @($CriticalIncidents).Count -eq 0) {
        return "<div class='all-clear-box'>&#10003; All Clear &bull; No Critical or Major Incidents reported during this shift.</div>"
    }

    $rows = foreach ($ci in $CriticalIncidents) {
        $pBadge   = Get-PriorityBadgeHtml -PriorityDisplay $ci.PriorityDisplay
        $sBadge   = Get-StatusBadgeHtml -Status $ci.State
        $hBadge   = Get-HandoverBadgeHtml -IsHandover $ci.IsHandover
        $safeDesc = [System.Web.HttpUtility]::HtmlEncode($ci.ShortDescription)
        $rowStyle = if ($ci.PriorityCode -in @("P0", "P1", "P2")) { "class='row-highlight'" } else { "" }

        @"
        <tr $rowStyle>
            <td><strong>$($ci.Application)</strong></td>
            <td><span class='ticket-num'>$($ci.TicketNumber)</span></td>
            <td>$pBadge</td>
            <td>$sBadge</td>
            <td>$safeDesc</td>
            <td style='font-weight: 600;'>$($ci.ETA)</td>
            <td style='text-align: center;'>$hBadge</td>
        </tr>
"@
    }

    return @"
<table class='styled-table' style='border-top: 2px solid #991b1b;'>
    <thead>
        <tr>
            <th style='width: 85px;'>App</th>
            <th style='width: 115px;'>Number</th>
            <th style='width: 105px;'>Priority</th>
            <th style='width: 95px;'>State</th>
            <th>Short Description</th>
            <th style='width: 90px;'>ETA</th>
            <th style='width: 85px; text-align: center;'>Handed Over</th>
        </tr>
    </thead>
    <tbody>
$($rows -join "`n")
    </tbody>
</table>
"@
}

function Get-AppCardHtml {
    param ([PSCustomObject]$App)

    # 1. Incidents block
    $incHtml = if ($App.IncidentCount -eq 0) {
        "        <div class='metric-title' style='color: #64748b;'><strong>Incidents:</strong> 0 Handled</div>"
    } else {
        $incTable = Get-IncidentTableHtml -Incidents $App.ActiveIncidents
        "        <div class='metric-title'><strong>Incidents:</strong> $($App.IncidentCount) Handled</div>`n$incTable"
    }

    # 2. Service Requests block (Count & summary chip only)
    $srHtml = if ($App.RequestCount -eq 0) {
        "        <div class='metric-title' style='margin-top: 14px;'><strong>Service Requests:</strong> 0</div>`n        <div class='summary-chip' style='color: #64748b;'>0 active / closed today</div>"
    } else {
        "        <div class='metric-title' style='margin-top: 14px;'><strong>Service Requests:</strong> $($App.RequestCount)</div>`n        <div class='summary-chip'>$($App.RequestSummary)</div>"
    }

    # 3. Change Requests block
    $chgHtml = if ($App.ChangeCount -eq 0) {
        "        <div class='metric-title' style='margin-top: 14px;'><strong>Change Requests:</strong> 0</div>`n        <div class='summary-chip' style='color: #64748b;'>0 active / scheduled</div>"
    } else {
        $chgTable = Get-ChangeTableHtml -Changes $App.ActiveChanges
        "        <div class='metric-title' style='margin-top: 14px;'><strong>Change Requests:</strong> $($App.ChangeCount)</div>`n        <div class='summary-chip'>$($App.ChangeSummary)</div>`n$chgTable"
    }

    return @"
<div class='app-card'>
    <div class='app-card-header'>
        <div class='app-title'>$($App.Application) Operations</div>
        <div class='app-meta-counts'>Incidents: $($App.IncidentCount) &bull; Requests: $($App.RequestCount) &bull; Changes: $($App.ChangeCount)</div>
    </div>
    <div class='app-card-body'>
$incHtml
$srHtml
$chgHtml
    </div>
</div>
"@
}

function Build-ShiftHandoverHtml {
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$MetricsResult,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][string]$ShiftName,
        [Parameter(Mandatory = $true)][string]$ReportDate,
        [Parameter(Mandatory = $true)][string]$TemplatesDir,
        [string]$ScriptName = "Email",
        [string]$LogPath
    )

    $templatePath = Join-Path $TemplatesDir "ShiftHandoverReport.html"
    $htmlContent = ""

    if (Test-Path $templatePath) {
        Write-Log -Message "Loading HTML template from: $templatePath" -ScriptName $ScriptName -LogPath $LogPath
        $htmlContent = Get-Content -Path $templatePath -Raw -Encoding UTF8
    }
    else {
        Write-Log -Message "HTML template not found at $templatePath. Generating minimal fallback." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        $htmlContent = "<html><body><p>Shift Handover: {{ReportDateFormatted}} ({{ShiftName}})</p>{{ApplicationSectionsHtml}}</body></html>"
    }

    # Render Application Cards cleanly in one pass
    $appCards = foreach ($app in $MetricsResult.Applications) {
        Get-AppCardHtml -App $app
    }
    $appSectionsHtml = $appCards -join "`n`n"

    # Render Critical / Major Incidents Table cleanly in one pass
    $critHtml = Get-CriticalIncidentsTableHtml -CriticalIncidents $MetricsResult.CriticalIncidents

    $reportDateFormatted = Get-FormattedDateString -DateString $ReportDate
    $timestampNow = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $spFileLink = if ($Config.SharePoint -and $Config.SharePoint.SiteUrl) { $Config.SharePoint.SiteUrl } else { "#" }
    $spFileName = if ($Config.SharePoint -and $Config.SharePoint.FileName) { $Config.SharePoint.FileName } else { "ShiftHandover_Tracker.xlsx" }

    $RenderedHtml = $htmlContent
    $RenderedHtml = $RenderedHtml.Replace("{{ReportDateFormatted}}",     $reportDateFormatted)
    $RenderedHtml = $RenderedHtml.Replace("{{ReportDateOrdinal}}",       $reportDateFormatted)
    $RenderedHtml = $RenderedHtml.Replace("{{ReportDate}}",              $ReportDate)
    $RenderedHtml = $RenderedHtml.Replace("{{ShiftName}}",               $ShiftName)
    $RenderedHtml = $RenderedHtml.Replace("{{Timestamp}}",               $timestampNow)
    $RenderedHtml = $RenderedHtml.Replace("{{TotalActiveIncidents}}",    "$($MetricsResult.TotalActiveInc)")
    $RenderedHtml = $RenderedHtml.Replace("{{TotalActiveRequests}}",     "$($MetricsResult.TotalActiveReq)")
    $RenderedHtml = $RenderedHtml.Replace("{{TotalActiveChanges}}",      "$($MetricsResult.TotalActiveChg)")
    $RenderedHtml = $RenderedHtml.Replace("{{TotalClosedToday}}",        "$($MetricsResult.TotalClosedToday)")
    $RenderedHtml = $RenderedHtml.Replace("{{TotalHandoverItems}}",      "$($MetricsResult.TotalHandoverItems)")
    $RenderedHtml = $RenderedHtml.Replace("{{ApplicationSectionsHtml}}", $appSectionsHtml)
    $RenderedHtml = $RenderedHtml.Replace("{{CriticalIncidentsHtml}}",   $critHtml)
    $RenderedHtml = $RenderedHtml.Replace("{{SharePointFileLink}}",      $spFileLink)
    $RenderedHtml = $RenderedHtml.Replace("{{SharePointFileName}}",      $spFileName)

    return $RenderedHtml
}

function Send-ShiftHandoverEmail {
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$EmailConfig,
        [Parameter(Mandatory = $true)][string]$HtmlBody,
        [Parameter(Mandatory = $true)][string]$ShiftName,
        [Parameter(Mandatory = $true)][string]$ReportDate,
        [string[]]$RecipientOverride = @(),
        [string]$WorkbookAttachmentPath = "",
        [string]$ScriptName = "Email",
        [string]$LogPath
    )

    if ($null -eq $EmailConfig -or -not $EmailConfig.Enabled) {
        Write-Log -Message "Email dispatch is disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    if ([string]::IsNullOrWhiteSpace($EmailConfig.SmtpServer)) {
        Write-Log -Message "SmtpServer is missing in config. Skipping email." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    $toRecipients = if ($RecipientOverride -and $RecipientOverride.Count -gt 0) {
        $RecipientOverride
    }
    elseif ($EmailConfig.To -and $EmailConfig.To.Count -gt 0) {
        $EmailConfig.To
    }
    else {
        @()
    }

    if ($toRecipients.Count -eq 0) {
        Write-Log -Message "No recipient email addresses found. Skipping email dispatch." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return
    }

    $reportDateFormatted = Get-FormattedDateString -DateString $ReportDate
    $subjectTemplate = if ($EmailConfig.SubjectTemplate) { $EmailConfig.SubjectTemplate } else { "Shift Handover - {ReportDateFormatted} {ShiftName}" }
    $subject = $subjectTemplate.Replace("{ShiftName}", $ShiftName).Replace("{ReportDateFormatted}", $reportDateFormatted).Replace("{ReportDateOrdinal}", $reportDateFormatted).Replace("{ReportDate}", $ReportDate)

    $mailParams = @{
        SmtpServer  = $EmailConfig.SmtpServer
        From        = $EmailConfig.From
        To          = $toRecipients
        Subject     = $subject
        Body        = $HtmlBody
        BodyAsHtml  = $true
    }

    if ($EmailConfig.Cc -and $EmailConfig.Cc.Count -gt 0) {
        $mailParams.Cc = $EmailConfig.Cc
    }
    if ($EmailConfig.Bcc -and $EmailConfig.Bcc.Count -gt 0) {
        $mailParams.Bcc = $EmailConfig.Bcc
    }

    if ($EmailConfig.AttachWorkbook -and (Test-Path $WorkbookAttachmentPath)) {
        $mailParams.Attachments = @($WorkbookAttachmentPath)
        Write-Log -Message "Attaching Excel tracker workbook: $WorkbookAttachmentPath" -ScriptName $ScriptName -LogPath $LogPath
    }

    Write-Log -Message "Sending Shift Handover email to: $($toRecipients -join ', ') (Subject: '$subject')..." -ScriptName $ScriptName -LogPath $LogPath
    try {
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Log -Message "Shift Handover email sent successfully." -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Failed to send email notification: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    }
}
