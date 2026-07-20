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

        foreach ($domain in $Domains) {
            $dName = $domain.Name
            
            # Filter the analysis report for this domain
            $domainAccounts = @($AnalysisReport | Where-Object { [string]$_.Domain -eq $dName })
            
            $disabledAccounts = @($domainAccounts | Where-Object { [string]$_.Enabled -eq "False" })
            $enabledAccounts  = @($domainAccounts | Where-Object { [string]$_.Enabled -ne "False" })

            $enabledInCyberArk    = @($enabledAccounts  | Where-Object { [string]$_.InCyberArk -eq "True" })
            $enabledNotInCyberArk = @($enabledAccounts  | Where-Object { [string]$_.InCyberArk -ne "True" })
            
            $disabledInCyberArk   = @($disabledAccounts | Where-Object { [string]$_.InCyberArk -eq "True" })
            $disabledNotCyberArk  = @($disabledAccounts | Where-Object { [string]$_.InCyberArk -ne "True" })

            # Active Directory Status (Section Header)
            $spSectionHeaders.Add("[$dName] Active Directory Status")
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Active Directory Status"; Value = "" })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Total Scanned"; Value = $domainAccounts.Count })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled in AD"; Value = $enabledAccounts.Count })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled - In CyberArk"; Value = $enabledInCyberArk.Count })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Enabled - NOT in CyberArk"; Value = $enabledNotInCyberArk.Count })
            
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled in AD"; Value = $disabledAccounts.Count })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled - In CyberArk"; Value = $disabledInCyberArk.Count })
            $spDataRows.Add([PSCustomObject]@{ Metric = "[$dName] Disabled - NOT in CyberArk"; Value = $disabledNotCyberArk.Count })
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
