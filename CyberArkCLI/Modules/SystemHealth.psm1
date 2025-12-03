function Get-CACSystemHealth {
    param(
        [bool]$ExportToCSV = $true
    )

    Write-Log "Started Get-CACSystemHealth()" "DEBUG"
    Write-Log "Retrieving system health summary and component details" "INFO"

    try {
        Write-Log "Calling Get-PASComponentSummary" "DEBUG"
        Write-Host "Fetching component summary..." -ForegroundColor Cyan

        $summary = Get-PASComponentSummary -ErrorAction Stop

        if (-not $summary) {
            Write-Log "Component summary returned empty" "WARN"
            Write-Host "No summary data returned from CyberArk." -ForegroundColor Yellow
            return
        }

        Write-Log "Component summary retrieved successfully" "DEBUG"

        $allComponentsHealth = @()

        foreach ($component in $summary.Components) {
            $componentID = $component.ComponentID
            
            Write-Log "Processing component: $componentID" "DEBUG"
            Write-Host "Retrieving details for $($component.ComponentName)..." -ForegroundColor Cyan

            try {
                $componentDetails = Get-PASComponentDetail -ComponentID $componentID -ErrorAction Stop

                if ($componentDetails.ComponentsDetails) {
                    foreach ($detail in $componentDetails.ComponentsDetails) {
                        $healthRecord = [PSCustomObject]@{
                            ComponentID         = $componentID
                            ComponentName       = $component.ComponentName
                            ComponentIP         = $detail.ComponentIP
                            ComponentUserName   = $detail.ComponentUserName
                            ComponentVersion    = $detail.ComponentVersion
                            IsLoggedOn          = $detail.IsLoggedOn
                            LastLogonDate       = $detail.LastLogonDate
                            ConnectedCount      = $component.ConnectedComponentCount
                            TotalCount          = $component.ComponentTotalCount
                            ReportedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        }

                        $allComponentsHealth += $healthRecord

                        Write-Log "Processed component instance: $($detail.ComponentIP)" "DEBUG"
                    }
                }
                else {
                    Write-Log "No details found for component: $componentID" "WARN"
                }
            }
            catch {
                Write-Log "Error retrieving details for $componentID`: $($_.Exception.Message)" "WARN"
                Write-Host "Error retrieving $($component.ComponentName) details: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        if ($allComponentsHealth.Count -eq 0) {
            Write-Log "No component health data retrieved" "WARN"
            Write-Host "No component health data was retrieved." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "System Health Summary" -ForegroundColor Cyan
        Write-Host ""

        $allComponentsHealth | Format-Table -AutoSize @(
            "ComponentName",
            "ComponentIP",
            "ComponentUserName",
            "ComponentVersion",
            "IsLoggedOn",
            "LastLogonDate",
            "ConnectedCount",
            "TotalCount"
        )

        if ($ExportToCSV) {
            $outputDir = "$PSScriptRoot/../Output"
            if (-not (Test-Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir | Out-Null
                Write-Log "Output directory created: $outputDir" "DEBUG"
            }

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/system_health_$timestamp.csv"

            Write-Log "Exporting $($allComponentsHealth.Count) component records to CSV: $outputFile" "INFO"
            $allComponentsHealth | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "CSV export successful: $outputFile" "SUCCESS"
            Write-Host ""
            Write-Host "Export Summary" -ForegroundColor Cyan
            Write-Host "  Total Components: $($allComponentsHealth.Count)"
            Write-Host "  Export File: $outputFile" -ForegroundColor Green
        }

        Write-Log "Completed Get-CACSystemHealth()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in Get-CACSystemHealth(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Export-ModuleMember -Function Get-CACSystemHealth
