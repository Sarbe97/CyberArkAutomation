function Get-CACUserLicenseReport {
    try {
        Write-Host "Fetching User License Report..." -ForegroundColor Cyan
        $result = Get-PASUserLicenseReport

        $csv = Join-Path $PSScriptRoot "..\Data\UserLicenseReport.csv"
        $result | Export-Csv -NoTypeInformation -Path $csv

        Write-Host "Report saved: $csv" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-CACReport {
    try {
        $reportID = Read-Host "Enter Report ID"
        if (-not $reportID) { throw "Report ID cannot be empty." }

        $result = Get-PASReport -ReportID $reportID

        $csv = Join-Path $PSScriptRoot "..\Data\Report_$reportID.csv"
        $result | Export-Csv -NoTypeInformation -Path $csv

        Write-Host "Report saved: $csv" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-CACReportSchedule {
    try {
        Write-Host "Fetching Report Schedules..." -ForegroundColor Cyan
        $result = Get-PASReportSchedule

        $csv = Join-Path $PSScriptRoot "..\Data\ReportSchedules.csv"
        $result | Export-Csv -NoTypeInformation -Path $csv

        Write-Host "Schedules saved: $csv" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-CACReportSchedule {
    try {
        $reportID = Read-Host "Report ID"
        $scheduleName = Read-Host "Schedule Name"
        $cron = Read-Host "Cron Expression (example: 0 0 * * *)"

        $params = @{
            ReportID = $reportID
            ScheduleName = $scheduleName
            CronExpression = $cron
        }

        $result = New-PASReportSchedule @params

        Write-Host "Schedule created:" -ForegroundColor Green
        $result | Format-List
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Export-CACReport {
    try {
        $reportID = Read-Host "Report ID"

        if (-not $reportID) { throw "Report ID cannot be empty." }

        $file = Join-Path $PSScriptRoot "..\Data\ExportedReport_$reportID.csv"

        Export-PASReport -ReportID $reportID -Path $file

        Write-Host "Report exported to: $file" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Export-ModuleMember -Function `
    Get-CACUserLicenseReport, `
    Get-CACReport, `
    Get-CACReportSchedule, `
    New-CACReportSchedule, `
    Export-CACReport
