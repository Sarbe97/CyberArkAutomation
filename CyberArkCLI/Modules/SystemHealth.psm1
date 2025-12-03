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
        $componentTypes = @("PVWA", "SessionManagement", "CPM", "AIM")
        $componentCount = 0
        $successCount = 0
        $errorCount = 0

        foreach ($componentType in $componentTypes) {
            $componentCount++
            
            try {
                Write-Log "Fetching details for component: $componentType" "DEBUG"
                Write-Host "Retrieving $componentType details..." -ForegroundColor Cyan

                $componentDetails = Get-PASComponentDetail -ComponentID $componentType -ErrorAction Stop

                if ($componentDetails) {
                    Write-Log "Retrieved $($componentDetails.Count) instances of $componentType" "DEBUG"

                    foreach ($instance in $componentDetails) {
                        try {
                            $healthRecord = [PSCustomObject]@{
                                ComponentType           = $componentType
                                ComponentID             = $instance.ComponentID
                                ComponentInstanceName   = $instance.ComponentInstanceName
                                MachineName             = $instance.MachineName
                                ServerAddress           = $instance.ServerAddress
                                ServerPort              = $instance.ServerPort
                                HealthStatus            = $instance.HealthStatus
                                ComponentStatus         = $instance.ComponentStatus
                                ConnectivityStatus      = $instance.ConnectivityStatus
                                OSVersion               = $instance.OSVersion
                                ProcessorCount          = $instance.ProcessorCount
                                ComponentVersion        = $instance.ComponentVersion
                                IsUserLoggedIn          = $instance.IsUserLoggedIn
                                LastHealthCheck         = Convert-CACTimestamp $instance.LastHealthCheck
                                LastReportTime          = Convert-CACTimestamp $instance.LastReportTime
                                RedundancyMode          = $instance.RedundancyMode
                                SoftwareVersion         = $instance.SoftwareVersion
                                ReportedAt              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            }

                            $allComponentsHealth += $healthRecord
                            $successCount++

                            Write-Log "Successfully processed $componentType instance: $($instance.ComponentInstanceName)" "DEBUG"
                        }
                        catch {
                            $errorCount++
                            Write-Log "Error processing $componentType instance: $($_.Exception.Message)" "WARN"
                        }
                    }
                }
                else {
                    Write-Log "No details found for component: $componentType" "WARN"
                }
            }
            catch {
                $errorCount++
                Write-Log "Error retrieving component details for $componentType`: $($_.Exception.Message)" "ERROR"
                Write-Host "Error retrieving $componentType details: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        Write-Log "Component retrieval complete. Success: $successCount, Errors: $errorCount" "INFO"

        if ($allComponentsHealth.Count -eq 0) {
            Write-Log "No component health data retrieved" "WARN"
            Write-Host "No component health data was retrieved." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== System Health Summary =====" -ForegroundColor Cyan
        Write-Host ""

        $grouped = $allComponentsHealth | Group-Object -Property ComponentType

        foreach ($group in $grouped) {
            Write-Host "$($group.Name):" -ForegroundColor Yellow
            $group.Group | Format-Table -AutoSize @(
                "ComponentInstanceName",
                "MachineName",
                "HealthStatus",
                "ComponentStatus",
                "ConnectivityStatus",
                "ComponentVersion"
            )
        }

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

function Get-CACComponentHealth {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("PVWA", "SessionManagement", "CPM", "AIM")]
        [string]$ComponentID
    )

    Write-Log "Started Get-CACComponentHealth()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($ComponentID)) {
            Write-Host "Available Components:" -ForegroundColor Cyan
            Write-Host "1 = PVWA (Web Portal)"
            Write-Host "2 = SessionManagement (PSM/PSMP)"
            Write-Host "3 = CPM (Password Manager)"
            Write-Host "4 = AIM (Application Identity Manager)"
            
            $choice = Read-Host "Enter component choice (1-4)"
            
            $ComponentID = switch ($choice) {
                '1' { "PVWA" }
                '2' { "SessionManagement" }
                '3' { "CPM" }
                '4' { "AIM" }
                default {
                    Write-Log "Invalid component choice" "WARN"
                    Write-Host "Invalid choice." -ForegroundColor Yellow
                    return
                }
            }
        }

        Write-Log "Fetching component health for: $ComponentID" "INFO"
        Write-Host "Retrieving $ComponentID health details..." -ForegroundColor Cyan

        $componentDetails = Get-PASComponentDetail -ComponentID $ComponentID -ErrorAction Stop

        if (-not $componentDetails) {
            Write-Log "No data returned for component: $ComponentID" "WARN"
            Write-Host "No component data found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($componentDetails.Count) instances of $ComponentID" "INFO"

        Write-Host ""
        Write-Host "===== $ComponentID Health Details =====" -ForegroundColor Cyan
        Write-Host ""

        $formatted = $componentDetails | ForEach-Object {
            [PSCustomObject]@{
                ComponentName      = $_.ComponentInstanceName
                MachineName        = $_.MachineName
                ServerAddress      = $_.ServerAddress
                Port               = $_.ServerPort
                HealthStatus       = $_.HealthStatus
                ComponentStatus    = $_.ComponentStatus
                Connectivity       = $_.ConnectivityStatus
                Version            = $_.ComponentVersion
                OS                 = $_.OSVersion
                Processors         = $_.ProcessorCount
                LastHealthCheck    = Convert-CACTimestamp $_.LastHealthCheck
                LastReport         = Convert-CACTimestamp $_.LastReportTime
                RedundancyMode     = $_.RedundancyMode
            }
        }

        $formatted | Format-Table -AutoSize

        Write-Host ""
        $exportChoice = Read-Host "Export to CSV? (Y/N)"

        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = "$PSScriptRoot/../Output"
            if (-not (Test-Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir | Out-Null
            }

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/component_health_${ComponentID}_$timestamp.csv"

            Write-Log "Exporting component health to CSV: $outputFile" "INFO"
            $formatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "CSV export successful: $outputFile" "SUCCESS"
            Write-Host "Exported to: $outputFile" -ForegroundColor Green
        }

        Write-Log "Completed Get-CACComponentHealth()" "DEBUG"
    }
    catch {
        Write-Log "Error in Get-CACComponentHealth(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-CACHealthCheck {
    Write-Log "Started Invoke-CACHealthCheck()" "DEBUG"
    Write-Log "Performing quick system health check" "INFO"

    try {
        Write-Host "Performing System Health Check..." -ForegroundColor Cyan
        Write-Host ""

        $componentTypes = @("PVWA", "SessionManagement", "CPM", "AIM")
        $healthSummary = @()
        $allHealthy = $true

        foreach ($componentType in $componentTypes) {
            try {
                Write-Host "Checking $componentType..." -ForegroundColor Gray

                $componentDetails = Get-PASComponentDetail -ComponentID $componentType -ErrorAction Stop

                if ($componentDetails) {
                    $unhealthyCount = ($componentDetails | Where-Object { $_.HealthStatus -ne "OK" }).Count
                    $disconnectedCount = ($componentDetails | Where-Object { $_.ConnectivityStatus -ne "Connected" }).Count
                    
                    $status = "OK"
                    $color = "Green"

                    if ($disconnectedCount -gt 0) {
                        $status = "DISCONNECTED"
                        $color = "Red"
                        $allHealthy = $false
                    }
                    elseif ($unhealthyCount -gt 0) {
                        $status = "WARNING"
                        $color = "Yellow"
                        $allHealthy = $false
                    }

                    $statusRecord = [PSCustomObject]@{
                        Component         = $componentType
                        Status            = $status
                        InstanceCount     = $componentDetails.Count
                        HealthyInstances  = ($componentDetails | Where-Object { $_.HealthStatus -eq "OK" }).Count
                        UnhealthyCount    = $unhealthyCount
                        DisconnectedCount = $disconnectedCount
                    }

                    $healthSummary += $statusRecord

                    Write-Host "  Status: $status" -ForegroundColor $color
                }
                else {
                    Write-Log "No data for component: $componentType" "WARN"
                    Write-Host "  NO DATA" -ForegroundColor Yellow
                    $allHealthy = $false
                }
            }
            catch {
                Write-Log "Error checking $componentType`: $($_.Exception.Message)" "WARN"
                Write-Host "  ERROR" -ForegroundColor Red
                $allHealthy = $false
            }
        }

        Write-Host ""
        Write-Host "===== Health Check Summary =====" -ForegroundColor Cyan
        Write-Host ""

        $healthSummary | Format-Table -AutoSize

        Write-Host ""
        if ($allHealthy) {
            Write-Host "Overall Status: ALL SYSTEMS OPERATIONAL" -ForegroundColor Green
            Write-Log "All components healthy" "SUCCESS"
        }
        else {
            Write-Host "Overall Status: ATTENTION REQUIRED" -ForegroundColor Red
            Write-Log "One or more components have issues" "WARN"
        }

        Write-Log "Completed Invoke-CACHealthCheck()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in Invoke-CACHealthCheck(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Export-CACSystemHealthReport {
    Write-Log "Started Export-CACSystemHealthReport()" "DEBUG"
    Write-Log "Generating comprehensive system health reports" "INFO"

    try {
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $reportTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Write-Host "Generating System Health Reports..." -ForegroundColor Cyan

        Write-Host "  Collecting detailed component data..." -ForegroundColor Gray

        $allDetails = @()
        foreach ($componentType in @("PVWA", "SessionManagement", "CPM", "AIM")) {
            try {
                $details = Get-PASComponentDetail -ComponentID $componentType -ErrorAction Stop
                if ($details) {
                    foreach ($instance in $details) {
                        $allDetails += [PSCustomObject]@{
                            ComponentType           = $componentType
                            ComponentID             = $instance.ComponentID
                            ComponentInstanceName   = $instance.ComponentInstanceName
                            MachineName             = $instance.MachineName
                            ServerAddress           = $instance.ServerAddress
                            ServerPort              = $instance.ServerPort
                            HealthStatus            = $instance.HealthStatus
                            ComponentStatus         = $instance.ComponentStatus
                            ConnectivityStatus      = $instance.ConnectivityStatus
                            OSVersion               = $instance.OSVersion
                            ProcessorCount          = $instance.ProcessorCount
                            ComponentVersion        = $instance.ComponentVersion
                            IsUserLoggedIn          = $instance.IsUserLoggedIn
                            LastHealthCheck         = Convert-CACTimestamp $instance.LastHealthCheck
                            LastReportTime          = Convert-CACTimestamp $instance.LastReportTime
                            RedundancyMode          = $instance.RedundancyMode
                            SoftwareVersion         = $instance.SoftwareVersion
                            ReportedAt              = $reportTimestamp
                        }
                    }
                }
            }
            catch {
                Write-Log "Error collecting details for $componentType`: $($_.Exception.Message)" "WARN"
            }
        }

        if ($allDetails.Count -gt 0) {
            $fullDetailFile = "$outputDir/system_health_full_$timestamp.csv"
            $allDetails | Export-Csv -Path $fullDetailFile -NoTypeInformation -Encoding UTF8
            Write-Log "Full details report created: $fullDetailFile" "SUCCESS"
            Write-Host "    Full Details Report created" -ForegroundColor Green
        }

        Write-Host "  Creating summary report..." -ForegroundColor Gray

        $summaryData = $allDetails | Group-Object -Property ComponentType | ForEach-Object {
            [PSCustomObject]@{
                ComponentType      = $_.Name
                TotalInstances     = $_.Count
                HealthyCount       = ($_.Group | Where-Object { $_.HealthStatus -eq "OK" }).Count
                UnhealthyCount     = ($_.Group | Where-Object { $_.HealthStatus -ne "OK" }).Count
                ConnectedCount     = ($_.Group | Where-Object { $_.ConnectivityStatus -eq "Connected" }).Count
                DisconnectedCount  = ($_.Group | Where-Object { $_.ConnectivityStatus -ne "Connected" }).Count
                HealthyPercentage  = [Math]::Round(
                    (($_.Group | Where-Object { $_.HealthStatus -eq "OK" }).Count / $_.Count * 100),
                    2
                )
                ReportedAt         = $reportTimestamp
            }
        }

        if ($summaryData.Count -gt 0) {
            $summaryFile = "$outputDir/system_health_summary_$timestamp.csv"
            $summaryData | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8
            Write-Log "Summary report created: $summaryFile" "SUCCESS"
            Write-Host "    Summary Report created" -ForegroundColor Green
        }

        Write-Host "  Creating status report..." -ForegroundColor Gray

        $statusData = @()
        foreach ($componentType in @("PVWA", "SessionManagement", "CPM", "AIM")) {
            $componentInstances = $allDetails | Where-Object { $_.ComponentType -eq $componentType }
            
            if ($componentInstances) {
                $overallHealth = if (($componentInstances | Where-Object { $_.HealthStatus -ne "OK" }).Count -gt 0) { "UNHEALTHY" } else { "HEALTHY" }
                $overallConnectivity = if (($componentInstances | Where-Object { $_.ConnectivityStatus -ne "Connected" }).Count -gt 0) { "DISCONNECTED" } else { "CONNECTED" }
                
                $statusData += [PSCustomObject]@{
                    Component        = $componentType
                    OverallHealth    = $overallHealth
                    OverallConnectivity = $overallConnectivity
                    InstanceCount    = $componentInstances.Count
                    LatestVersion    = ($componentInstances | Sort-Object -Property ComponentVersion -Descending | Select-Object -First 1).ComponentVersion
                    ReportedAt       = $reportTimestamp
                }
            }
        }

        if ($statusData.Count -gt 0) {
            $statusFile = "$outputDir/system_health_status_$timestamp.csv"
            $statusData | Export-Csv -Path $statusFile -NoTypeInformation -Encoding UTF8
            Write-Log "Status report created: $statusFile" "SUCCESS"
            Write-Host "    Status Quick Reference created" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "System Health Reports Generated" -ForegroundColor Cyan
        Write-Host "  Location: $outputDir" -ForegroundColor Green
        Write-Host "  Timestamp: $timestamp"

        Write-Log "Completed Export-CACSystemHealthReport()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in Export-CACSystemHealthReport(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Export-ModuleMember -Function `
    Get-CACSystemHealth, `
    Get-CACComponentHealth, `
    Invoke-CACHealthCheck, `
    Export-CACSystemHealthReport
