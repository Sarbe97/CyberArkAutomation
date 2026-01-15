# ============================================================================
# MODULE: Platforms.psm1
# DESCRIPTION: Platform Management using raw CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get All Platforms
# ============================================================
function Get-CACAllPlatforms {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAllPlatforms()" "DEBUG"

    try {
        Write-Host "Fetching all platforms..." -ForegroundColor Cyan

        $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms"

        $platforms = @()
        if ($response.Platforms) { $platforms = @($response.Platforms) }
        elseif ($response.value) { $platforms = @($response.value) }
        elseif ($response -is [array]) { $platforms = @($response) }

        if ($platforms.Count -eq 0) {
            Write-Host "No platforms found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($platforms.Count) platforms" "INFO"

        # Format output
        $formattedPlatforms = @()
        $counter = 0

        foreach ($plat in $platforms) {
            $counter++
            Write-Progress -Activity "Processing Platforms" -Status "$counter of $($platforms.Count)" -PercentComplete (($counter / $platforms.Count) * 100)

            $details = $plat.Details
            $workflows = if ($details) { $details.PrivilegedAccessWorkflows } else { $null }

            $formattedPlatforms += [PSCustomObject]@{
                PlatformID      = $plat.PlatformID
                PlatformName    = if ($details) { $details.Name } else { $plat.Name }
                Active          = $plat.Active
                SystemType      = if ($details) { $details.SystemType } else { "" }
                PlatformType    = $plat.PlatformType
                CheckinCheckout = if ($workflows -and $workflows.EnforceCheckinCheckoutExclusiveAccess) { $workflows.EnforceCheckinCheckoutExclusiveAccess.IsActive } else { "N/A" }
                OTP             = if ($workflows -and $workflows.EnforceOnetimePasswordAccess) { $workflows.EnforceOnetimePasswordAccess.IsActive } else { "N/A" }
                DualControl     = if ($workflows -and $workflows.RequireDualControlPasswordAccessApproval) { $workflows.RequireDualControlPasswordAccessApproval.IsActive } else { "N/A" }
                ReasonRequired  = if ($workflows -and $workflows.RequireUsersToSpecifyReasonForAccess) { $workflows.RequireUsersToSpecifyReasonForAccess.IsActive } else { "N/A" }
            }
        }

        Write-Progress -Activity "Processing Platforms" -Completed

        # Display summary
        Write-Host ""
        Write-Host "===== Platforms =====" -ForegroundColor Cyan
        Write-Host "Total Platforms: $($formattedPlatforms.Count)"
        
        $activeCount = ($formattedPlatforms | Where-Object { $_.Active -eq $true }).Count
        Write-Host "  Active: $activeCount"
        Write-Host "  Inactive: $($formattedPlatforms.Count - $activeCount)"
        Write-Host ""

        $formattedPlatforms | Format-Table PlatformID, PlatformName, Active, SystemType, PlatformType -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/platforms_$timestamp.csv"

            $formattedPlatforms | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedPlatforms
    }
    catch {
        Write-Log "Error in Get-CACAllPlatforms(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 2. Get Platform Details
# ============================================================
function Get-CACPlatformDetails {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACPlatformDetails()" "DEBUG"

    try {
        $platformId = Read-Host "Enter Platform ID"
        if ([string]::IsNullOrWhiteSpace($platformId)) {
            Write-Host "Platform ID cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching platform details..." -ForegroundColor Cyan

        $platform = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms/$([System.Web.HttpUtility]::UrlEncode($platformId))"

        if (-not $platform) {
            Write-Host "Platform not found." -ForegroundColor Yellow
            return
        }

        $details = $platform.Details
        $workflows = if ($details) { $details.PrivilegedAccessWorkflows } else { $null }

        Write-Host ""
        Write-Host "===== Platform Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Platform ID:      $($platform.PlatformID)" -ForegroundColor White
        Write-Host "  Platform Name:    $(if ($details) { $details.Name } else { 'N/A' })" -ForegroundColor White
        Write-Host "  Active:           $($platform.Active)" -ForegroundColor $(if ($platform.Active) { "Green" } else { "Yellow" })
        Write-Host "  Platform Type:    $($platform.PlatformType)" -ForegroundColor White
        Write-Host "  System Type:      $(if ($details) { $details.SystemType } else { 'N/A' })" -ForegroundColor White
        Write-Host ""
        Write-Host "  --- Workflows ---" -ForegroundColor Yellow
        Write-Host "  Checkin/Checkout: $(if ($workflows -and $workflows.EnforceCheckinCheckoutExclusiveAccess) { $workflows.EnforceCheckinCheckoutExclusiveAccess.IsActive } else { 'N/A' })" -ForegroundColor White
        Write-Host "  One-Time Password:$(if ($workflows -and $workflows.EnforceOnetimePasswordAccess) { $workflows.EnforceOnetimePasswordAccess.IsActive } else { 'N/A' })" -ForegroundColor White
        Write-Host "  Dual Control:     $(if ($workflows -and $workflows.RequireDualControlPasswordAccessApproval) { $workflows.RequireDualControlPasswordAccessApproval.IsActive } else { 'N/A' })" -ForegroundColor White
        Write-Host "  Reason Required:  $(if ($workflows -and $workflows.RequireUsersToSpecifyReasonForAccess) { $workflows.RequireUsersToSpecifyReasonForAccess.IsActive } else { 'N/A' })" -ForegroundColor White
        Write-Host ""

        return $platform
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
# 4. Search Platforms
# ============================================================
function Search-CACPlatform {
    [CmdletBinding()]
    param()

    Write-Log "Started Search-CACPlatform()" "DEBUG"

    try {
        $search = Read-Host "Enter search term (platform name/ID)"
        if ([string]::IsNullOrWhiteSpace($search)) {
            Write-Host "Search term cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Searching platforms..." -ForegroundColor Cyan

        $endpoint = "/API/Platforms?search=$([System.Web.HttpUtility]::UrlEncode($search))"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $platforms = @()
        if ($response.Platforms) { $platforms = @($response.Platforms) }
        elseif ($response.value) { $platforms = @($response.value) }
        elseif ($response -is [array]) { $platforms = @($response) }

        if ($platforms.Count -eq 0) {
            Write-Host "No platforms found matching '$search'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Search Results =====" -ForegroundColor Cyan
        Write-Host "Found $($platforms.Count) platform(s)"
        Write-Host ""

        $platforms | ForEach-Object {
            $details = $_.Details
            [PSCustomObject]@{
                PlatformID   = $_.PlatformID
                PlatformName = if ($details) { $details.Name } else { $_.Name }
                Active       = $_.Active
                PlatformType = $_.PlatformType
            }
        } | Format-Table -AutoSize

        return $platforms
    }
    catch {
        Write-Log "Error in Search-CACPlatform(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Get-CACAllPlatforms, `
    Get-CACPlatformDetails, `
    Export-CACPlatform, `
    Search-CACPlatform
