# ============================================================
# PSA_SharePointReport
# Handles data mapping and reporting for Personal Safe Analysis.
# ============================================================

function Publish-PSASharePointReport {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$GlobalConfig,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointFeatureConfig,

        [Parameter(Mandatory = $true)]
        [hashtable]$Metrics,

        [Parameter(Mandatory = $true)]
        [string]$ExportDir,

        [string]$ScriptName = "PSA_Analysis",
        [string]$LogPath
    )

    try {
        $spDataRows = [System.Collections.Generic.List[object]]::new()
        $spSectionHeaders = [System.Collections.Generic.List[string]]::new()

        # Personal Safes Overview Section
        $spSectionHeaders.Add("Personal Safes Overview")
        $spDataRows.Add([PSCustomObject]@{ Metric = "Personal Safes Overview"; Value = "" })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Total Safes"; Value = $Metrics.TotalSafes })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Total Accounts Stored"; Value = $Metrics.TotalAccounts })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Blank Safes (0 Accounts)"; Value = $Metrics.BlankSafesCount })

        # Owner IS Safe Member Section
        $spSectionHeaders.Add("Owner IS Safe Member")
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner IS Safe Member"; Value = "" })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner is Active in AD"; Value = $Metrics.MemberEnabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner is Disabled in AD"; Value = $Metrics.MemberDisabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner NOT FOUND in AD"; Value = $Metrics.MemberNotFound })

        # Owner is NOT Safe Member Section
        $spSectionHeaders.Add("Owner is NOT Safe Member")
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner is NOT Safe Member"; Value = "" })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner is Active in AD (Not Member)"; Value = $Metrics.NotMemberEnabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner is Disabled in AD (Not Member)"; Value = $Metrics.NotMemberDisabled })
        $spDataRows.Add([PSCustomObject]@{ Metric = "Owner NOT FOUND in AD (Not Member)"; Value = $Metrics.NotMemberNotFound })

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
