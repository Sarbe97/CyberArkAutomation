# ============================================================
# SVC_SharePointReport
# Handles data mapping and reporting for Service Account Analysis.
# ============================================================

function Publish-SVCSharePointReport {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$GlobalConfig,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointFeatureConfig,

        [Parameter(Mandatory = $true)]
        [array]$AnalysisReport,

        [Parameter(Mandatory = $true)]
        [array]$Domains,

        [Parameter(Mandatory = $true)]
        [string]$ExportDir,

        [string]$ScriptName = "SVC_Analysis",
        [string]$LogPath
    )

    try {
        $spDataRows = [System.Collections.Generic.List[object]]::new()
        $spSectionHeaders = [System.Collections.Generic.List[string]]::new()

        # Build hashtable to count metrics per domain in a single pass (high performance)
        $domainStats = @{}
        foreach ($acct in $AnalysisReport) {
            $dom = $acct.Domain
            if (-not $domainStats.ContainsKey($dom)) {
                $domainStats[$dom] = @{ Total = 0; Enabled = 0; Disabled = 0; EnabledInCA = 0; EnabledNotInCA = 0; DisabledInCA = 0; DisabledNotInCA = 0 }
            }
            $stats = $domainStats[$dom]
            $stats.Total++
            
            $isInCA = ([string]$acct.InCyberArk -eq "True")
            if ([string]$acct.Enabled -ne "False") {
                $stats.Enabled++
                if ($isInCA) { $stats.EnabledInCA++ } else { $stats.EnabledNotInCA++ }
            } else {
                $stats.Disabled++
                if ($isInCA) { $stats.DisabledInCA++ } else { $stats.DisabledNotInCA++ }
            }
        }

        foreach ($domain in $Domains) {
            $dName = $domain.Name
            
            if ($domainStats.ContainsKey($dName)) {
                $stats = $domainStats[$dName]
            } else {
                $stats = @{ Total = 0; Enabled = 0; Disabled = 0; EnabledInCA = 0; EnabledNotInCA = 0; DisabledInCA = 0; DisabledNotInCA = 0 }
            }

            # Active Directory Status (Section Header)
            $spSectionHeaders.Add("[$dName] Active Directory Status")
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Active Directory Status"; Value = "" })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Total Scanned"; Value = $stats.Total })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled in AD"; Value = $stats.Enabled })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled - In CyberArk"; Value = $stats.EnabledInCA })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled - NOT in CyberArk"; Value = $stats.EnabledNotInCA })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled in AD"; Value = $stats.Disabled })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled - In CyberArk"; Value = $stats.DisabledInCA })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled - NOT in CyberArk"; Value = $stats.DisabledNotInCA })
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
