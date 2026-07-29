# =============================================================================
# DR_Email.ps1
# Builds the HTML email body from the template, zips all report files,
# and sends the notification via SMTP.
# Exposes: Send-DashboardEmail
# =============================================================================

function Send-DashboardEmail {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$EmailConfig,              # config.Email object

        [PSObject]$NotificationsConfig,      # Feature-specific notification config

        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$SummaryRows,

        [Parameter(Mandatory=$true)]
        [string[]]$FilesToZip,

        [Parameter(Mandatory=$true)]
        [string]$FailCompXls,                # Attached separately outside zip

        [Parameter(Mandatory=$true)]
        [string]$ExportDir,

        [Parameter(Mandatory=$true)]
        [string]$TodayStr,

        [Parameter(Mandatory=$true)]
        [string]$Timestamp,

        [Parameter(Mandatory=$true)]
        [string]$RootPath,

        [Parameter(Mandatory=$true)]
        [string]$BaseOutputDir,

        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Preparing email notification..." -ScriptName $ScriptName -LogPath $LogPath

    $zipFile = Join-Path $ExportDir "DashboardReports_$Timestamp.zip"
    Write-Log -Message "Zipping reports to $zipFile..." -ScriptName $ScriptName -LogPath $LogPath
    Compress-Archive -Path $FilesToZip -DestinationPath $zipFile -Force

    $Subject      = "CyberArk Dashboard Report - $TodayStr"
    $templatePath = Join-Path $RootPath "Templates\DashboardReport.html"

    if (-not (Test-Path $templatePath)) {
        Write-Log -Message "Email template not found. Falling back to plain text." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
        $Body = "Dashboard Report completed successfully.`n"
        foreach ($row in $SummaryRows) {
            if ($row.Category -in @("Metadata","SectionHeader")) { continue }
            $Body += "$($row.Metric): $($row.Value)`n"
        }
    }
    else {
        $templateContent = Get-Content $templatePath -Raw
        $accRows = ""; $safeRows = ""; $platRows = ""; $trackedRows = ""; $compRows = ""
        $prevCounts = Get-PreviousDayCounts -BaseOutputDir $BaseOutputDir -TodayStr $TodayStr

        foreach ($row in $SummaryRows) {
            if ($row.Category -in @("Metadata","SectionHeader")) { continue }
            if ($row.Value -eq "") { continue }   # skip placeholder rows

            $todayVal   = try { [int]$row.Value } catch { 0 }
            $prevValStr = if ($prevCounts -and $prevCounts.ContainsKey($row.Metric)) { $prevCounts[$row.Metric] } else { "N/A" }
            $prevVal    = if ($prevValStr -ne "N/A") { [int]$prevValStr } else { $null }

            $changeText  = "---"
            $changeClass = ""

            if ($null -ne $prevVal) {
                $diff = $todayVal - $prevVal
                if ($diff -gt 0) {
                    $changeText  = "+$diff"
                    $changeClass = if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { "trend-bad" } else { "trend-up" }
                }
                elseif ($diff -lt 0) {
                    $changeText  = "$diff"
                    $changeClass = if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { "trend-good" } else { "trend-down" }
                }
                else { $changeText = "0" }
            }

            $valClass = "metric"
            if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { $valClass = "priority-failed" }
            if ($row.Category -eq "Tracked Account Metrics" -and $row.Value -gt 0) { $valClass = "priority-failed" }

            $html = "<tr>
                <td>$($row.Metric)</td>
                <td class='metric'>$prevValStr</td>
                <td class='$valClass'>$todayVal</td>
                <td class='$changeClass'>$changeText</td>
            </tr>"

            switch ($row.Category) {
                "Account Metrics"         { $accRows     += $html }
                "Safe Metrics"            { $safeRows    += $html }
                "Platform Metrics"        { $platRows    += $html }
                "Tracked Account Metrics" { $trackedRows += $html }
                "Failure Comparison"      { $compRows    += $html }
            }
        }

        $Body = $templateContent.Replace("{{AccountTable}}",    $accRows)
        $Body = $Body.Replace("{{SafeTable}}",                  $safeRows)
        $Body = $Body.Replace("{{PlatformTable}}",              $platRows)
        $Body = $Body.Replace("{{TrackedTable}}",               $trackedRows)
        $Body = $Body.Replace("{{ComparisonTable}}",            $compRows)
        $Body = $Body.Replace("{{Timestamp}}",                  (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    }

    $SmtpServer  = $EmailConfig.SmtpServer
    
    $From = if ($NotificationsConfig -and $NotificationsConfig.AdminFrom) { $NotificationsConfig.AdminFrom } else { $EmailConfig.From }
    
    $To = if ($NotificationsConfig -and $NotificationsConfig.AdminTo -and $NotificationsConfig.AdminTo.Count -gt 0) {
        $NotificationsConfig.AdminTo -join ","
    } else {
        $EmailConfig.To -join ","
    }
    
    $Cc = $null
    if ($NotificationsConfig -and $NotificationsConfig.AdminCC -and $NotificationsConfig.AdminCC.Count -gt 0) {
        $Cc = $NotificationsConfig.AdminCC -join ","
    }

    $Attachments = @($zipFile, $FailCompXls)

    Write-Log -Message "Sending email to $To via $SmtpServer..." -ScriptName $ScriptName -LogPath $LogPath
    if ($Cc) {
        Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To -Cc $Cc -Subject $Subject -Body $Body -BodyAsHtml -Attachments $Attachments
    } else {
        Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml -Attachments $Attachments
    }
    Write-Log -Message "Email sent successfully." -ScriptName $ScriptName -LogPath $LogPath
}
