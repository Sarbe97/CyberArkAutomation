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
        Write-Host "Fetching all platforms..." -ForegroundColor Cyan

        # Single API call to get all platforms with full details
        $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Platforms/"

        $platforms = @()
        if ($response.Platforms) { $platforms = @($response.Platforms) }
        elseif ($response.value) { $platforms = @($response.value) }
        elseif ($response -is [array]) { $platforms = @($response) }

        if ($platforms.Count -eq 0) {
            Write-Host "No platforms found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($platforms.Count) platforms" "INFO"

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
# 2. Export Platform Package (ZIP)
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
    Export-CACPlatform
