function Get-CACSystemHealth {
    param(
        [bool]$ExportToCSV = $true
    )

    Write-Log "Started Get-CACSystemHealth()" "DEBUG"
    Write-Log "Retrieving system health summary and component details from CyberArk APIs" "INFO"

    try {
        $allHealthData = @()

        Write-Log "Calling ComponentsMonitoringSummary API" "DEBUG"
        Write-Host "Fetching component summary..." -ForegroundColor Cyan

        $summaryResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/ComponentsMonitoringSummary/" -ErrorAction Stop

        if (-not $summaryResponse) {
            Write-Log "Component summary returned empty" "WARN"
            Write-Host "No summary data returned from CyberArk." -ForegroundColor Yellow
            return
        }

        Write-Log "Component summary retrieved successfully" "DEBUG"

        if ($summaryResponse.Vaults) {
            Write-Log "Found $($summaryResponse.Vaults.Count) vault instances in summary" "DEBUG"

            foreach ($vault in $summaryResponse.Vaults) {
                $vaultRecord = [PSCustomObject]@{
                    HealthType          = "Vault"
                    ComponentID         = "VAULT"
                    ComponentName       = $vault.Role
                    ComponentIP         = $vault.IP
                    ComponentUserName   = $vault.Role
                    ComponentVersion    = $null
                    IsLoggedOn          = $vault.IsLoggedOn
                    LastLogonDate       = $null
                    ReportedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }

                $allHealthData += $vaultRecord

                Write-Log "Added vault instance: $($vault.ComponentIP)" "DEBUG"
            }
        }

        if (-not $summaryResponse.Components) {
            Write-Log "No Components array in summary response" "WARN"
            Write-Host "No components found in summary." -ForegroundColor Yellow
        }
        else {
            Write-Log "Found $($summaryResponse.Components.Count) component types" "DEBUG"

            foreach ($component in $summaryResponse.Components) {
                $componentID = $component.ComponentID
                $componentName = $component.ComponentName
                
                Write-Log "Processing component: $componentID - $componentName" "DEBUG"
                Write-Host "Retrieving details for $componentName..." -ForegroundColor Cyan

                try {
                    $detailEndpoint = "/API/ComponentsMonitoringDetails/$componentID/"
                    $detailResponse = Invoke-CACAPIRequest -Method GET -Endpoint $detailEndpoint -ErrorAction Stop

                    if (-not $detailResponse.ComponentsDetails) {
                        Write-Log "No ComponentsDetails found for: $componentID" "WARN"
                        continue
                    }

                    Write-Log "Retrieved $($detailResponse.ComponentsDetails.Count) instances for $componentID" "DEBUG"

                    foreach ($detail in $detailResponse.ComponentsDetails) {
                        $healthRecord = [PSCustomObject]@{
                            HealthType          = "Component"
                            ComponentID         = $componentID
                            ComponentName       = $componentName
                            ComponentIP         = $detail.ComponentIP
                            ComponentUserName   = $detail.ComponentUserName
                            ComponentVersion    = $detail.ComponentVersion
                            IsLoggedOn          = $detail.IsLoggedOn
                            LastLogonDate       = $detail.LastLogonDate
                            ReportedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        }

                        $allHealthData += $healthRecord

                        Write-Log "Processed component instance: $($detail.ComponentIP) for $componentName" "DEBUG"
                    }
                }
                catch {
                    Write-Log "Error retrieving details for $componentID`: $($_.Exception.Message)" "WARN"
                    Write-Host "Error retrieving $componentName details: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        if ($allHealthData.Count -eq 0) {
            Write-Log "No health data retrieved" "WARN"
            Write-Host "No health data was retrieved." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "System Health Summary" -ForegroundColor Cyan
        Write-Host ""

        $allHealthData | Format-Table -AutoSize @(
            "HealthType",
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

            Write-Log "Exporting $($allHealthData.Count) health records to CSV: $outputFile" "INFO"
            $allHealthData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "CSV export successful: $outputFile" "SUCCESS"
            Write-Host ""
            Write-Host "Export Summary" -ForegroundColor Cyan
            Write-Host "Total Records: $($allHealthData.Count)"
            Write-Host "Export File: $outputFile" -ForegroundColor Green
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
