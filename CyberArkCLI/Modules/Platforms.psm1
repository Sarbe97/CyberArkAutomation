# ============================================================================
# MODULE: Platforms.psm1
# DESCRIPTION: Platform Management using raw CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get All Platforms (with full details)
# ============================================================
function Get-CACAllPlatforms {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAllPlatforms()" "DEBUG"

    try {
        Write-Host ""
        Write-Host "===== Platform Filter =====" -ForegroundColor Cyan
        Write-Host "1. Active Platforms Only"
        Write-Host "2. Inactive Platforms Only"
        Write-Host "3. All Platforms"
        Write-Host "4. Get Platform Details (Manual/CSV)" -ForegroundColor Yellow
        $filterChoice = Read-Host "Select filter (1/2/3/4)"

        # Option 4: Call Get-CACPlatformDetails and return
        if ($filterChoice -eq '4') {
            Get-CACPlatformDetails
            return
        }

        $endpoint = "/API/Platforms"
        switch ($filterChoice) {
            '1' { $endpoint = "/API/Platforms?Active=true" }
            '2' { $endpoint = "/API/Platforms?Active=false" }
            '3' { $endpoint = "/API/Platforms?PlatformType=Regular" }
            default { $endpoint = "/API/Platforms?Active=true" }
        }

        Write-Host "Fetching platforms..." -ForegroundColor Cyan
        Write-Host "[DEBUG] Endpoint: $endpoint" -ForegroundColor Gray
        Write-Log "Calling endpoint: $endpoint" "DEBUG"

        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        # Debug: Show response structure
        Write-Host "[DEBUG] Response Type: $($response.GetType().Name)" -ForegroundColor Gray
        Write-Log "Response Type: $($response.GetType().Name)" "DEBUG"

        if ($response -is [PSCustomObject] -or $response -is [hashtable]) {
            $responseKeys = $response.PSObject.Properties.Name -join ", "
            Write-Host "[DEBUG] Response Keys: $responseKeys" -ForegroundColor Gray
            Write-Log "Response Keys: $responseKeys" "DEBUG"
        }

        $platforms = @()
        if ($response.Platforms) { 
            $platforms = @($response.Platforms) 
            Write-Host "[DEBUG] Found 'Platforms' property with $($platforms.Count) items" -ForegroundColor Gray
        }
        elseif ($response.value) { 
            $platforms = @($response.value) 
            Write-Host "[DEBUG] Found 'value' property with $($platforms.Count) items" -ForegroundColor Gray
        }
        elseif ($response -is [array]) { 
            $platforms = @($response) 
            Write-Host "[DEBUG] Response is array with $($platforms.Count) items" -ForegroundColor Gray
        }

        if ($platforms.Count -eq 0) {
            Write-Host "No platforms found." -ForegroundColor Yellow
            Write-Host "[DEBUG] Raw response:" -ForegroundColor Gray
            Write-Host ($response | ConvertTo-Json -Depth 2 -Compress) -ForegroundColor Gray
            return
        }

        Write-Log "Retrieved $($platforms.Count) platforms" "INFO"

        # Debug: Show first platform structure
        $firstPlat = $platforms[0]
        Write-Host "[DEBUG] First platform keys: $($firstPlat.PSObject.Properties.Name -join ', ')" -ForegroundColor Gray
        Write-Host "[DEBUG] First platform JSON:" -ForegroundColor Gray
        Write-Host ($firstPlat | ConvertTo-Json -Depth 3 -Compress) -ForegroundColor Gray
        Write-Log "First platform: $($firstPlat | ConvertTo-Json -Depth 3 -Compress)" "DEBUG"

        # Format output from the response
        $formattedPlatforms = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($plat in $platforms) {
            # Extract sections from response
            $general = $plat.general
            $linkedAccounts = $plat.linkedAccounts
            $credsMgmt = $plat.credentialsManagement
            $sessionMgmt = $plat.sessionManagement
            $workflows = $plat.privilegedAccessWorkflows

            # Format linkedAccounts as comma-separated string
            $linkedAccountsStr = ""
            if ($linkedAccounts -and $linkedAccounts.Count -gt 0) {
                $linkedAccountsStr = ($linkedAccounts | ForEach-Object { "$($_.name):$($_.displayName)" }) -join "; "
            }

            $formattedPlatforms.Add([PSCustomObject]@{
                    # General section
                    ID                                    = if ($general) { $general.id } else { $plat.PlatformID }
                    Name                                  = if ($general) { $general.name } else { $plat.Name }
                    SystemType                            = if ($general) { $general.systemType } else { "" }
                    Active                                = if ($general) { $general.active } else { $plat.Active }
                    Description                           = if ($general) { $general.description } else { "" }
                    PlatformBaseID                        = if ($general) { $general.platformBaseID } else { "" }
                    PlatformType                          = if ($general) { $general.platformType } else { $plat.PlatformType }
                
                    # Linked Accounts (formatted as string)
                    LinkedAccounts                        = $linkedAccountsStr
                
                    # Credentials Management section
                    AllowedSafes                          = if ($credsMgmt) { $credsMgmt.allowedSafes } else { "" }
                    AllowManualChange                     = if ($credsMgmt) { $credsMgmt.allowManualChange } else { "" }
                    PerformPeriodicChange                 = if ($credsMgmt) { $credsMgmt.performPeriodicChange } else { "" }
                    RequirePasswordChangeEveryXDays       = if ($credsMgmt) { $credsMgmt.requirePasswordChangeEveryXDays } else { "" }
                    AllowManualVerification               = if ($credsMgmt) { $credsMgmt.allowManualVerification } else { "" }
                    PerformPeriodicVerification           = if ($credsMgmt) { $credsMgmt.performPeriodicVerification } else { "" }
                    RequirePasswordVerificationEveryXDays = if ($credsMgmt) { $credsMgmt.requirePasswordVerificationEveryXDays } else { "" }
                    AllowManualReconciliation             = if ($credsMgmt) { $credsMgmt.allowManualReconciliation } else { "" }
                    AutomaticReconcileWhenUnsynched       = if ($credsMgmt) { $credsMgmt.automaticReconcileWhenUnsynched } else { "" }
                
                    # Session Management section
                    RequirePSMMonitoringAndIsolation      = if ($sessionMgmt) { $sessionMgmt.requirePrivilegedSessionMonitoringAndIsolation } else { "" }
                    RecordAndSaveSessionActivity          = if ($sessionMgmt) { $sessionMgmt.recordAndSaveSessionActivity } else { "" }
                    PSMServerID                           = if ($sessionMgmt) { $sessionMgmt.PSMServerID } else { "" }
                
                    # Privileged Access Workflows section
                    RequireDualControlApproval            = if ($workflows) { $workflows.requireDualControlPasswordAccessApproval } else { "" }
                    EnforceCheckinCheckoutExclusiveAccess = if ($workflows) { $workflows.enforceCheckinCheckoutExclusiveAccess } else { "" }
                    EnforceOnetimePasswordAccess          = if ($workflows) { $workflows.enforceOnetimePasswordAccess } else { "" }
                })
        }

        # Display summary
        Write-Host ""
        Write-Host "===== Platforms =====" -ForegroundColor Cyan
        Write-Host "Total Platforms: $($formattedPlatforms.Count)"
        
        $activeCount = ($formattedPlatforms | Where-Object { $_.Active -eq $true }).Count
        Write-Host "  Active: $activeCount"
        Write-Host "  Inactive: $($formattedPlatforms.Count - $activeCount)"
        Write-Host ""

        # Display basic table in console
        $formattedPlatforms | Format-Table ID, Name, Active, SystemType, PlatformType -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export full details to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/platforms_$timestamp.csv"

            $formattedPlatforms | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
            Write-Log "Exported $($formattedPlatforms.Count) platforms to $outputFile" "INFO"
        }

        return $formattedPlatforms
    }
    catch {
        Write-Log "Error in Get-CACAllPlatforms(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
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

        foreach ($platformName in $platformNames) {
            Write-Host ""
            Write-Host "Fetching: $platformName" -ForegroundColor Cyan
            
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
