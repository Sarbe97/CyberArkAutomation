# =============================================================================
# DR_SharePoint.ps1
# Handles data mapping and reporting for Dashboard Report.
# =============================================================================

function Publish-DRSharePointReport {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$GlobalConfig,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointFeatureConfig,

        [Parameter(Mandatory = $true)]
        [array]$SummaryRows,

        [Parameter(Mandatory = $true)]
        [string]$ExportDir,

        [string]$ScriptName = "DashboardReport",
        [string]$LogPath
    )

    try {
        $spDataRows = [System.Collections.Generic.List[object]]::new()
        $spSectionHeaders = [System.Collections.Generic.List[string]]::new()

        foreach ($row in $SummaryRows) {
            if ($row.Category -eq "Metadata") {
                continue
            }
            if ($row.Category -eq "SectionHeader") {
                $spSectionHeaders.Add($row.Metric)
                $spDataRows.Add([PSCustomObject]@{ Metric = $row.Metric; Value = "" })
            } else {
                $spDataRows.Add([PSCustomObject]@{ Metric = $row.Metric; Value = $row.Value })
            }
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
