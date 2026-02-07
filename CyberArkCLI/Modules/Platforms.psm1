# ============================================================
# 1. Get Platform Details (Consolidated)
# ============================================================
function Get-CACAllPlatforms {
    <#
    .SYNOPSIS
        Fetches platform details with multiple source and output options.
    .DESCRIPTION
        Consolidated platform details function with:
        - Source options: Active/Inactive/All platforms from API, or Manual/CSV input
        - Output options: Individual txt files per platform OR formatted CSV
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAllPlatforms()" "DEBUG"

    try {
        # ==========================================
        # STEP 1: SOURCE SELECTION
        # ==========================================
        Write-Host ""
        Write-Host "===== Get Platform Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Select Platform Source:" -ForegroundColor Yellow
        Write-Host "  1. Active Platforms Only"
        Write-Host "  2. Inactive Platforms Only"
        Write-Host "  3. All Platforms"
        Write-Host "  4. Manual Input (enter platform names)"
        Write-Host "  5. Import from CSV"
        Write-Host ""
        
        $sourceChoice = Read-Host "Select source (1-5)"

        $platformNames = @()
        $platformDataList = @()

        switch ($sourceChoice) {
            '1' {
                # Fetch Active Platforms from API
                Write-Host "Fetching active platforms from API..." -ForegroundColor Cyan
                $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms?Active=true"
                $platformDataList = @(Get-PlatformDataFromResponse $response)
                $platformNames = $platformDataList | ForEach-Object { if ($_.general) { $_.general.id } else { $_.PlatformID } } | Where-Object { $_ }
            }
            '2' {
                # Fetch Inactive Platforms from API
                Write-Host "Fetching inactive platforms from API..." -ForegroundColor Cyan
                $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms?Active=false"
                $platformDataList = @(Get-PlatformDataFromResponse $response)
                $platformNames = $platformDataList | ForEach-Object { if ($_.general) { $_.general.id } else { $_.PlatformID } } | Where-Object { $_ }
            }
            '3' {
                # Fetch All Platforms from API
                Write-Host "Fetching all platforms from API..." -ForegroundColor Cyan
                $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms?PlatformType=Regular"
                $platformDataList = @(Get-PlatformDataFromResponse $response)
                $platformNames = $platformDataList | ForEach-Object { if ($_.general) { $_.general.id } else { $_.PlatformID } } | Where-Object { $_ }
            }
            '4' {
                # Manual Input
                Write-Host ""
                Write-Host "Enter platform names (one per line). Type 'done' or leave empty when finished:" -ForegroundColor Yellow
                while ($true) {
                    $userInput = Read-Host "Platform Name"
                    if ($userInput -eq 'done' -or [string]::IsNullOrWhiteSpace($userInput)) {
                        break
                    }
                    $platformNames += $userInput.Trim()
                }
            }
            '5' {
                # CSV Import
                $csvPath = Read-Host "Enter CSV Path"
                if ([string]::IsNullOrWhiteSpace($csvPath) -or -not (Test-Path $csvPath)) {
                    Write-Host "File not found." -ForegroundColor Red
                    return
                }
                $csvData = Import-Csv $csvPath
                $platformNames = $csvData | ForEach-Object { 
                    if ($_.PlatformID) { $_.PlatformID } 
                    elseif ($_.PlatformName) { $_.PlatformName }
                    elseif ($_.Platform) { $_.Platform }
                    elseif ($_.ID) { $_.ID }
                    elseif ($_.Name) { $_.Name }
                } | Where-Object { $_ }
            }
            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                return
            }
        }

        if ($platformNames.Count -eq 0 -and $platformDataList.Count -eq 0) {
            Write-Host "No platforms found or provided." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "Found $($platformNames.Count) platform(s)" -ForegroundColor Cyan

        # ==========================================
        # STEP 2: OUTPUT FORMAT SELECTION
        # ==========================================
        Write-Host ""
        Write-Host "Select Output Format:" -ForegroundColor Yellow
        Write-Host "  1. Individual Files (Full JSON per platform as .txt)"
        Write-Host "  2. Single CSV (Formatted columns for all platforms)"
        Write-Host ""
        
        $outputChoice = Read-Host "Select output format (1/2)"

        $outputDir = Get-CACOutputDir
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

        # ==========================================
        # OUTPUT OPTION 1: Individual Files
        # ==========================================
        if ($outputChoice -eq '1') {
            $platformsDir = Join-Path $outputDir "PlatformDetails_$timestamp"
            if (-not (Test-Path $platformsDir)) {
                New-Item -ItemType Directory -Path $platformsDir | Out-Null
            }

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $successCount = 0
            $failCount = 0
            $counter = 0
            $total = $platformNames.Count

            foreach ($platformName in $platformNames) {
                $counter++
                $percentComplete = [math]::Round(($counter / $total) * 100)
                Write-Progress -Activity "Fetching Platform Details" -Status "$counter of $total : $platformName" -PercentComplete $percentComplete
                
                Write-Host "[$counter/$total] Fetching: $platformName" -ForegroundColor Cyan
                
                $status = "Success"
                $errorMessage = ""

                try {
                    # Check if we already have data from API bulk fetch
                    $platformData = $null
                    if ($platformDataList.Count -gt 0) {
                        $platformData = $platformDataList | Where-Object { 
                            ($_.general -and $_.general.id -eq $platformName) -or 
                            ($_.PlatformID -eq $platformName) 
                        } | Select-Object -First 1
                    }
                    
                    # If not found in bulk, fetch individually
                    if (-not $platformData) {
                        $endpoint = "/API/Platforms/$([System.Web.HttpUtility]::UrlEncode($platformName))"
                        $platformData = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
                    }
                    
                    if ($platformData) {
                        $safeFileName = $platformName -replace '[\\/*?:"<>|]', '_'
                        $outputFile = Join-Path $platformsDir "${safeFileName}.txt"
                        $platformData | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8
                        Write-Host "  [SUCCESS] Saved: ${safeFileName}.txt" -ForegroundColor Green
                        $successCount++
                    }
                    else {
                        $status = "Failed"
                        $errorMessage = "Empty response"
                        Write-Host "  [FAILED] Empty response" -ForegroundColor Red
                        $failCount++
                    }
                }
                catch {
                    $status = "Failed"
                    $errorMessage = $_.Exception.Message
                    Write-Host "  [FAILED] $errorMessage" -ForegroundColor Red
                    $failCount++
                }

                $results.Add([PSCustomObject]@{
                        PlatformName = $platformName
                        Status       = $status
                        Error        = $errorMessage
                        Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    })
            }

            Write-Progress -Activity "Fetching Platform Details" -Completed

            # Generate status report
            $statusFile = Join-Path $platformsDir "_status_report.csv"
            $results | Export-Csv -Path $statusFile -NoTypeInformation -Encoding UTF8

            Write-Host ""
            Write-Host "===== Summary =====" -ForegroundColor Cyan
            Write-Host "Total: $total  |  Success: $successCount  |  Failed: $failCount"
            Write-Host "Output: $platformsDir" -ForegroundColor Yellow
        }

        # ==========================================
        # OUTPUT OPTION 2: Single CSV
        # ==========================================
        elseif ($outputChoice -eq '2') {
            $formattedPlatforms = [System.Collections.Generic.List[PSCustomObject]]::new()
            $counter = 0
            $total = $platformNames.Count

            foreach ($platformName in $platformNames) {
                $counter++
                $percentComplete = [math]::Round(($counter / $total) * 100)
                Write-Progress -Activity "Processing Platforms" -Status "$counter of $total : $platformName" -PercentComplete $percentComplete

                try {
                    # Check if we already have data from API bulk fetch
                    $plat = $null
                    if ($platformDataList.Count -gt 0) {
                        $plat = $platformDataList | Where-Object { 
                            ($_.general -and $_.general.id -eq $platformName) -or 
                            ($_.PlatformID -eq $platformName) 
                        } | Select-Object -First 1
                    }
                    
                    # If not found in bulk, fetch individually
                    if (-not $plat) {
                        $endpoint = "/API/Platforms/$([System.Web.HttpUtility]::UrlEncode($platformName))"
                        $plat = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
                    }

                    if ($plat) {
                        $general = $plat.general
                        $linkedAccounts = $plat.linkedAccounts
                        $credsMgmt = $plat.credentialsManagement
                        $sessionMgmt = $plat.sessionManagement
                        $workflows = $plat.privilegedAccessWorkflows

                        $linkedAccountsStr = ""
                        if ($linkedAccounts -and $linkedAccounts.Count -gt 0) {
                            $linkedAccountsStr = ($linkedAccounts | ForEach-Object { "$($_.name):$($_.displayName)" }) -join "; "
                        }

                        $formattedPlatforms.Add([PSCustomObject]@{
                                ID                                    = if ($general) { $general.id } else { $plat.PlatformID }
                                Name                                  = if ($general) { $general.name } else { $plat.Name }
                                SystemType                            = if ($general) { $general.systemType } else { "" }
                                Active                                = if ($general) { $general.active } else { $plat.Active }
                                Description                           = if ($general) { $general.description } else { "" }
                                PlatformBaseID                        = if ($general) { $general.platformBaseID } else { "" }
                                PlatformType                          = if ($general) { $general.platformType } else { $plat.PlatformType }
                                LinkedAccounts                        = $linkedAccountsStr
                                AllowedSafes                          = if ($credsMgmt) { $credsMgmt.allowedSafes } else { "" }
                                AllowManualChange                     = if ($credsMgmt) { $credsMgmt.allowManualChange } else { "" }
                                PerformPeriodicChange                 = if ($credsMgmt) { $credsMgmt.performPeriodicChange } else { "" }
                                RequirePasswordChangeEveryXDays       = if ($credsMgmt) { $credsMgmt.requirePasswordChangeEveryXDays } else { "" }
                                AllowManualVerification               = if ($credsMgmt) { $credsMgmt.allowManualVerification } else { "" }
                                PerformPeriodicVerification           = if ($credsMgmt) { $credsMgmt.performPeriodicVerification } else { "" }
                                RequirePasswordVerificationEveryXDays = if ($credsMgmt) { $credsMgmt.requirePasswordVerificationEveryXDays } else { "" }
                                AllowManualReconciliation             = if ($credsMgmt) { $credsMgmt.allowManualReconciliation } else { "" }
                                AutomaticReconcileWhenUnsynched       = if ($credsMgmt) { $credsMgmt.automaticReconcileWhenUnsynched } else { "" }
                                RequirePSMMonitoringAndIsolation      = if ($sessionMgmt) { $sessionMgmt.requirePrivilegedSessionMonitoringAndIsolation } else { "" }
                                RecordAndSaveSessionActivity          = if ($sessionMgmt) { $sessionMgmt.recordAndSaveSessionActivity } else { "" }
                                PSMServerID                           = if ($sessionMgmt) { $sessionMgmt.PSMServerID } else { "" }
                                RequireDualControlApproval            = if ($workflows) { $workflows.requireDualControlPasswordAccessApproval } else { "" }
                                EnforceCheckinCheckoutExclusiveAccess = if ($workflows) { $workflows.enforceCheckinCheckoutExclusiveAccess } else { "" }
                                EnforceOnetimePasswordAccess          = if ($workflows) { $workflows.enforceOnetimePasswordAccess } else { "" }
                            })
                    }
                }
                catch {
                    Write-Log "Error processing platform '$platformName': $($_.Exception.Message)" "WARN"
                }
            }

            Write-Progress -Activity "Processing Platforms" -Completed

            if ($formattedPlatforms.Count -gt 0) {
                Write-Host ""
                Write-Host "===== Platforms =====" -ForegroundColor Cyan
                Write-Host "Total: $($formattedPlatforms.Count)"
                Write-Host ""
                
                $formattedPlatforms | Format-Table ID, Name, Active, SystemType, PlatformType -AutoSize

                $outputFile = "$outputDir/platforms_$timestamp.csv"
                $formattedPlatforms | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
                Write-Host "Export File: $outputFile" -ForegroundColor Green
            }
            else {
                Write-Host "No platform data retrieved." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Invalid output option." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Log "Error in Get-CACAllPlatforms(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# HELPER: Extract platforms from API response
# ============================================================
function Get-PlatformDataFromResponse {
    param($Response)
    
    if ($Response.Platforms) { return @($Response.Platforms) }
    elseif ($Response.value) { return @($Response.value) }
    elseif ($Response -is [array]) { return @($Response) }
    return @()
}

# ============================================================
# 2. Get Platform Details (Manual or CSV Input)
# ============================================================
function Get-CACPlatformDetails {
    <#
    .SYNOPSIS
        Fetches platform details by name (manual input or CSV) with error tracking.
    .DESCRIPTION
        Workaround for the 500 error when fetching all platforms.
        Allows you to provide platform names manually or via CSV and fetches details for each.
        Saves each platform's details to a separate txt file and generates a status CSV.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACPlatformDetails()" "DEBUG"

    try {
        Write-Host ""
        Write-Host "===== Get Platform Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  1. Enter platform name manually"
        Write-Host "  2. Import from CSV (Column: PlatformID or PlatformName)"
        Write-Host ""
        
        $mode = Read-Host "Select mode (1/2)"

        $platformNames = @()

        if ($mode -eq '1') {
            Write-Host ""
            Write-Host "Enter platform names (one per line). Type 'done' when finished:" -ForegroundColor Yellow
            while ($true) {
                $userInput = Read-Host "Platform Name"
                if ($userInput -eq 'done' -or [string]::IsNullOrWhiteSpace($userInput)) {
                    break
                }
                $platformNames += $userInput.Trim()
            }
        }
        elseif ($mode -eq '2') {
            $csvPath = Read-Host "Enter CSV Path"
            if ([string]::IsNullOrWhiteSpace($csvPath) -or -not (Test-Path $csvPath)) {
                Write-Host "File not found." -ForegroundColor Red
                return
            }
            $csvData = Import-Csv $csvPath
            $platformNames = $csvData | ForEach-Object { 
                if ($_.PlatformID) { $_.PlatformID } 
                elseif ($_.PlatformName) { $_.PlatformName }
                elseif ($_.Platform) { $_.Platform }
                elseif ($_.ID) { $_.ID }
                elseif ($_.Name) { $_.Name }
            } | Where-Object { $_ }
        }
        else {
            Write-Host "Invalid option." -ForegroundColor Yellow
            return
        }

        if ($platformNames.Count -eq 0) {
            Write-Host "No platform names provided." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "Processing $($platformNames.Count) platform(s)..." -ForegroundColor Cyan

        # Prepare output directory
        $outputDir = Get-CACOutputDir
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $platformsDir = Join-Path $outputDir "PlatformDetails_$timestamp"
        if (-not (Test-Path $platformsDir)) {
            New-Item -ItemType Directory -Path $platformsDir | Out-Null
        }

        # Results tracking
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $successCount = 0
        $failCount = 0
        $counter = 0
        $total = $platformNames.Count

        foreach ($platformName in $platformNames) {
            $counter++
            $percentComplete = [math]::Round(($counter / $total) * 100)
            Write-Progress -Activity "Fetching Platform Details" -Status "$counter of $total : $platformName" -PercentComplete $percentComplete
            
            Write-Host ""
            Write-Host "[$counter/$total] Fetching: $platformName" -ForegroundColor Cyan
            
            $status = "Success"
            $errorMessage = ""
            $platformData = $null

            try {
                # Try to get platform details using the platform ID/name
                $endpoint = "/API/Platforms/$([System.Web.HttpUtility]::UrlEncode($platformName))"
                Write-Log "Calling endpoint: $endpoint" "DEBUG"
                
                $platformData = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
                
                if ($platformData) {
                    # Save to txt file
                    $safeFileName = $platformName -replace '[\\/*?:"<>|]', '_'
                    $outputFile = Join-Path $platformsDir "${safeFileName}.txt"
                    
                    # Format the platform data nicely
                    $platformJson = $platformData | ConvertTo-Json -Depth 10
                    $platformJson | Out-File -FilePath $outputFile -Encoding UTF8
                    
                    Write-Host "  [SUCCESS] Saved to: ${safeFileName}.txt" -ForegroundColor Green
                    $successCount++
                }
                else {
                    $status = "Failed"
                    $errorMessage = "Empty response"
                    Write-Host "  [FAILED] Empty response" -ForegroundColor Red
                    $failCount++
                }
            }
            catch {
                $status = "Failed"
                $errorMessage = $_.Exception.Message
                Write-Host "  [FAILED] $errorMessage" -ForegroundColor Red
                Write-Log "Failed to get platform '$platformName': $errorMessage" "ERROR"
                $failCount++
            }

            # Track result
            $results.Add([PSCustomObject]@{
                    PlatformName = $platformName
                    Status       = $status
                    Error        = $errorMessage
                    Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                })
        }

        # Clear progress bar
        Write-Progress -Activity "Fetching Platform Details" -Completed

        # Generate status CSV
        $statusFile = Join-Path $platformsDir "_status_report.csv"
        $results | Export-Csv -Path $statusFile -NoTypeInformation -Encoding UTF8

        # Summary
        Write-Host ""
        Write-Host "===== Summary =====" -ForegroundColor Cyan
        Write-Host "Total Platforms: $($platformNames.Count)"
        Write-Host "  Success: $successCount" -ForegroundColor Green
        Write-Host "  Failed:  $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
        Write-Host ""
        Write-Host "Output Directory: $platformsDir" -ForegroundColor Yellow
        Write-Host "Status Report:    _status_report.csv" -ForegroundColor Yellow
        Write-Log "Platform details fetch completed. Success: $successCount, Failed: $failCount" "INFO"

        return $results
    }
    catch {
        Write-Log "Error in Get-CACPlatformDetails(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 3. Export Platform Package (ZIP)
# ============================================================
function Export-CACPlatform {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACPlatform()" "DEBUG"

    try {
        Write-Host ""
        Write-Host "===== Export Platform Package =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  1. Export single platform"
        Write-Host "  2. Export from CSV (Column: PlatformID)"
        Write-Host ""
        
        $mode = Read-Host "Select mode (1/2)"

        $platformIds = @()

        if ($mode -eq '1') {
            $platformId = Read-Host "Enter Platform ID"
            if (-not [string]::IsNullOrWhiteSpace($platformId)) {
                $platformIds = @($platformId)
            }
        }
        elseif ($mode -eq '2') {
            $csvPath = Read-Host "Enter CSV Path"
            if ([string]::IsNullOrWhiteSpace($csvPath) -or -not (Test-Path $csvPath)) {
                Write-Host "File not found." -ForegroundColor Red
                return
            }
            $csvData = Import-Csv $csvPath
            $platformIds = $csvData | ForEach-Object { 
                if ($_.PlatformID) { $_.PlatformID } elseif ($_.PlatformName) { $_.PlatformName } 
            } | Where-Object { $_ }
        }
        else {
            return
        }

        if ($platformIds.Count -eq 0) {
            Write-Host "No platforms to export." -ForegroundColor Yellow
            return
        }

        # Prepare output directory
        $outputDir = Get-CACOutputDir
        $exportDir = Join-Path $outputDir "PlatformExports"
        if (-not (Test-Path $exportDir)) {
            New-Item -ItemType Directory -Path $exportDir | Out-Null
        }

        Write-Host ""
        Write-Host "Exporting $($platformIds.Count) platform(s)..." -ForegroundColor Cyan

        $counter = 0
        foreach ($platformId in $platformIds) {
            $counter++
            Write-Progress -Activity "Exporting Platforms" -Status "$counter of $($platformIds.Count): $platformId" -PercentComplete (($counter / $platformIds.Count) * 100)

            try {
                # Sanitize filename
                $safeFileName = $platformId -replace '[\\/*?:"<>|]', '_'
                $outputPath = Join-Path $exportDir "${safeFileName}.zip"

                # Export platform package
                $endpoint = "/API/Platforms/$([System.Web.HttpUtility]::UrlEncode($platformId))/Export"
                
                $session = Get-CACSession
                $exportUrl = "$($session.BaseURI)$endpoint"
                
                Invoke-WebRequest -Uri $exportUrl -Method POST -WebSession $session.WebSession -OutFile $outputPath -UseBasicParsing

                Write-Host "  Exported: $outputPath" -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed: $platformId - $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Progress -Activity "Exporting Platforms" -Completed
        Write-Host ""
        Write-Host "Export completed. Files saved to: $exportDir" -ForegroundColor Cyan
    }
    catch {
        Write-Log "Error in Export-CACPlatform(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Get-CACAllPlatforms, `
    Get-CACPlatformDetails, `
    Export-CACPlatform
