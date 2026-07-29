# ============================================================
# SAA_Reporting
# Handles data mapping and reporting for Secondary Account Analysis.
# ============================================================

function Publish-SAASharePointReport {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$GlobalConfig,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointFeatureConfig,

        [Parameter(Mandatory = $true)]
        [hashtable]$Metrics,

        [Parameter(Mandatory = $true)]
        [string]$ExportDir,

        [string]$ScriptName = "SAA_Analysis",
        [string]$LogPath
    )

    try {
        $spDataRows = [System.Collections.Generic.List[object]]::new()
        $spSectionHeaders = [System.Collections.Generic.List[string]]::new()

        # Secondary Accounts Section
        $spSectionHeaders.Add("Secondary Accounts")
        $spDataRows.Add([PSCustomObject]@{ Metric = "Secondary Accounts"; Value = "" })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Total Scanned"; Value = $Metrics.TotalScanned })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Already Managed"; Value = $Metrics.CountManaged })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Orphaned But Managed"; Value = $Metrics.CountOrphanedButManaged })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Needs Safe + Onboard"; Value = $Metrics.CountNeedsAll })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Needs Onboarding Only"; Value = $Metrics.CountNeedsOnboarding })

        # Issues Section
        $spSectionHeaders.Add("Issues")
        $spDataRows.Add([PSCustomObject]@{ Metric = "Issues"; Value = "" })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Missing AD Group"; Value = $Metrics.CountMissingGroup })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Primary Disabled"; Value = $Metrics.CountPrimaryDisabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Secondary Disabled"; Value = $Metrics.CountSecondaryDisabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Missing Primary"; Value = $Metrics.CountMissingPrimary })

        # EPV Impact Section (Only present if passed in Metrics)
        if ($Metrics.ContainsKey("NewEPVUsersConsumed")) {
            $spSectionHeaders.Add("EPV Impact")
            $spDataRows.Add([PSCustomObject]@{ Metric = "EPV Impact"; Value = "" })
            
            $epvDisplay = if ($Metrics.ContainsKey("TotalEPVUsers")) {
                "$($Metrics.NewEPVUsersConsumed) ($($Metrics.TotalEPVUsers))"
            } else {
                $Metrics.NewEPVUsersConsumed
            }
            $spDataRows.Add([PSCustomObject]@{ Metric = "Licenses to Consume (Existing)"; Value = $epvDisplay })
        }

        Update-SharePointExcel `
            -SharePointGlobalConfig $GlobalConfig.SharePoint `
            -FileName               $SharePointFeatureConfig.FileName `
            -FolderPath             $SharePointFeatureConfig.FolderPath `
            -DataRows               $spDataRows `
            -SheetName              $SharePointFeatureConfig.SheetName `
            -LocalTempDir           $ExportDir `
            -SectionHeaders         $spSectionHeaders `
            -GlobalCCPUrl           $GlobalConfig.CCP.Url `
            -ScriptName             $ScriptName `
            -LogPath                $LogPath
    }
    catch {
        Write-Log -Message "SharePoint upload failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    }
}
