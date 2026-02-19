# ============================================================================
# MODULE: SystemHealth.psm1
# DESCRIPTION: System health monitoring using raw CyberArk REST API
# ============================================================================

function Get-CACSystemHealth {
    <#
    .SYNOPSIS
        Retrieves CyberArk system health summary and component details.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACSystemHealth()" "DEBUG"
    Write-Log "Retrieving system health summary and component details from CyberArk APIs" "INFO"

    try {
        $allHealthData = @()

        Write-Log "Calling ComponentsMonitoringSummary API" "DEBUG"
        Write-Host "Fetching component summary..." -ForegroundColor Cyan

        $summaryResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/ComponentsMonitoringSummary/"

        if (-not $summaryResponse) {
            Write-Log "Component summary returned empty" "WARN"
            Write-Host "No summary data returned from CyberArk." -ForegroundColor Yellow
            return
        }

        Write-Log "Component summary retrieved successfully" "DEBUG"

        # Process Vault instances
        if ($summaryResponse.Vaults) {
            Write-Log "Found $($summaryResponse.Vaults.Count) vault instances in summary" "DEBUG"
            Write-Host "Processing $($summaryResponse.Vaults.Count) vault instance(s)..." -ForegroundColor Cyan

            foreach ($vault in $summaryResponse.Vaults) {
                $statusText = if ($vault.IsLoggedOn) { "[OK]" } else { "[DOWN]" }
                $vaultRecord = [PSCustomObject]@{
                    HealthType        = "Vault"
                    ComponentID       = "VAULT"
                    ComponentName     = $vault.Role
                    ComponentIP       = $vault.IP
                    ComponentUserName = $vault.Role
                    ComponentVersion  = "-"
                    Status            = $statusText
                    IsLoggedOn        = $vault.IsLoggedOn
                    LastLogonDate     = "-"
                    ReportedAt        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }

                $allHealthData += $vaultRecord
                Write-Log "Added vault instance: $($vault.IP)" "DEBUG"
            }
        }

        # Process Components
        if (-not $summaryResponse.Components) {
            Write-Log "No Components array in summary response" "WARN"
            Write-Host "No components found in summary." -ForegroundColor Yellow
        }
        else {
            $totalComponents = $summaryResponse.Components.Count
            Write-Log "Found $totalComponents component types" "DEBUG"
            Write-Host "Retrieving details for $totalComponents component type(s)..." -ForegroundColor Cyan

            $compIndex = 0
            foreach ($component in $summaryResponse.Components) {
                $compIndex++
                $componentID = $component.ComponentID
                $componentName = $component.ComponentName
                
                Write-Log "Processing component: $componentID - $componentName" "DEBUG"
                Write-Host "  [$compIndex/$totalComponents] $componentName ..." -NoNewline
                Write-Progress -Activity "Fetching System Health" -Status "[$compIndex/$totalComponents] $componentName" -PercentComplete (($compIndex / $totalComponents) * 100)

                try {
                    $detailEndpoint = "/API/ComponentsMonitoringDetails/$componentID/"
                    $detailResponse = Invoke-CACAPIRequest -Method GET -Endpoint $detailEndpoint

                    if (-not $detailResponse.ComponentsDetails) {
                        Write-Log "No ComponentsDetails found for: $componentID" "WARN"
                        Write-Host " No instances found" -ForegroundColor Yellow
                        continue
                    }

                    $instanceCount = $detailResponse.ComponentsDetails.Count
                    Write-Host " $instanceCount instance(s)" -ForegroundColor Green
                    Write-Log "Retrieved $instanceCount instances for $componentID" "DEBUG"

                    foreach ($detail in $detailResponse.ComponentsDetails) {
                        $statusText = if ($detail.IsLoggedOn) { "[OK]" } else { "[DOWN]" }
                        $healthRecord = [PSCustomObject]@{
                            HealthType        = "Component"
                            ComponentID       = $componentID
                            ComponentName     = $componentName
                            ComponentIP       = $detail.ComponentIP
                            ComponentUserName = $detail.ComponentUserName
                            ComponentVersion  = if ($detail.ComponentVersion) { $detail.ComponentVersion } else { "-" }
                            Status            = $statusText
                            IsLoggedOn        = $detail.IsLoggedOn
                            LastLogonDate     = Convert-CACTimestamp $detail.LastLogonDate
                            ReportedAt        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        }

                        $allHealthData += $healthRecord
                        Write-Log "Processed component instance: $($detail.ComponentIP) for $componentName" "DEBUG"
                    }
                }
                catch {
                    Write-Host " Error" -ForegroundColor Red
                    Write-Log "Error retrieving details for $componentID : $($_.Exception.Message)" "WARN"
                }
            }
            Write-Progress -Activity "Fetching System Health" -Completed
        }

        if ($allHealthData.Count -eq 0) {
            Write-Log "No health data retrieved" "WARN"
            Write-Host "No health data was retrieved." -ForegroundColor Yellow
            return
        }

        # Display results
        Write-Host ""
        Write-Host "===== System Health Summary =====" -ForegroundColor Cyan
        Write-Host "Total Components: $($allHealthData.Count)"
        Write-Host ""

        $allHealthData | Format-Table -AutoSize @(
            "Status",
            "HealthType",
            "ComponentName",
            "ComponentIP",
            "ComponentUserName",
            "ComponentVersion",
            "LastLogonDate"
        )

        # Quick status count
        $okCount = ($allHealthData | Where-Object { $_.IsLoggedOn -eq $true }).Count
        $downCount = ($allHealthData | Where-Object { $_.IsLoggedOn -ne $true }).Count
        Write-Host "  OK: $okCount  |  DOWN: $downCount" -ForegroundColor $(if ($downCount -gt 0) { "Yellow" } else { "Green" })

        # Auto-export to CSV
        $outputDir = Get-CACOutputDir
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFile = "$outputDir/SystemHealth_$timestamp.csv"

        Write-Log "Exporting $($allHealthData.Count) health records to CSV: $outputFile" "INFO"
        $allHealthData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "CSV export successful: $outputFile" "SUCCESS"
        Write-Host ""
        Write-Host "Results exported: $outputFile" -ForegroundColor Green

        Write-Log "Completed Get-CACSystemHealth()" "DEBUG"
        return $allHealthData
    }
    catch {
        Write-Log "Fatal error in Get-CACSystemHealth(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Export-ModuleMember -Function Get-CACSystemHealth
