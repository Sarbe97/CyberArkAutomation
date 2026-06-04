# =============================================================================
# DR_SharePoint.ps1
# Downloads the dashboard Excel file from SharePoint, merges today's counts
# as a new date column (or overwrites if same day), applies section header
# formatting, and uploads the file back.
# Sheet per calendar month (e.g. "May-2026"). Creates file if not found.
# Requires: PnP.PowerShell, ImportExcel
# Exposes: Update-SharePointDashboard
# =============================================================================

function Update-SharePointDashboard {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$SharePointConfig,          # Features.DashboardReport.SharePoint

        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$SummaryRows,        # Output of Build-SummaryRows

        [Parameter(Mandatory=$true)]
        [string]$ExportDir,                   # Local temp directory for today's run

        [System.Management.Automation.PSCredential]$FallbackCredential,
        [switch]$ManualLogin,
        [string]$ScriptName,
        [string]$LogPath,
        [string]$GlobalCCPUrl
    )

    Write-Log -Message "SharePoint Excel Update started..." -ScriptName $ScriptName -LogPath $LogPath

    $SpUrl              = $SharePointConfig.SiteUrl
    $SpRelativeFilePath = $SharePointConfig.FileRelativePath
    $SpFolderRelPath    = (Split-Path $SpRelativeFilePath -Parent) -replace '\\', '/'
    $SpFileName         = Split-Path $SpRelativeFilePath -Leaf
    $localTempXlsx      = Join-Path $ExportDir $SpFileName

    # -- Credentials --
    $SpCredential = $FallbackCredential
    if ($null -ne $SharePointConfig.CCP) {
        Write-Log -Message "Fetching SharePoint service account credential from CyberArk CCP..." -ScriptName $ScriptName -LogPath $LogPath
        $ccpConfig = [PSCustomObject]@{
            Url    = if ($SharePointConfig.CCP.Url) { $SharePointConfig.CCP.Url } else { $GlobalCCPUrl }
            AppId  = $SharePointConfig.CCP.AppId
            Safe   = $SharePointConfig.CCP.Safe
            Object = $SharePointConfig.CCP.Object
        }
        $SpCredential = Get-SchedulerCredential -CCPConfig $ccpConfig -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
    }

    # -- Connect --
    Write-Log -Message "Connecting to SharePoint: $SpUrl" -ScriptName $ScriptName -LogPath $LogPath
    Import-Module PnP.PowerShell -ErrorAction Stop
    Import-Module ImportExcel    -ErrorAction Stop
    Connect-PnPOnline -Url $SpUrl -Credentials $SpCredential -ErrorAction Stop

    try {
        # -- Download existing file OR start fresh --
        $fileExists = $false
        try {
            Get-PnPFile -Url $SpRelativeFilePath -Path $ExportDir -FileName $SpFileName -AsFile -Force -ErrorAction Stop
            $fileExists = $true
            Write-Log -Message "Downloaded existing Excel file from SharePoint." -ScriptName $ScriptName -LogPath $LogPath
        }
        catch {
            Write-Log -Message "Excel file not found on SharePoint. A new file will be created." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
        }

        # -- Context --
        $RunDate   = Get-Date -Format "yyyy-MM-dd"
        $SheetName = Get-Date -Format "MMM-yyyy"   # e.g. "May-2026"

        # -- Build today's value lookup (skip metadata and section headers) --
        $TodayValues = [ordered]@{}
        foreach ($row in $SummaryRows) {
            if ($row.Category -eq "Metadata" -or $row.Category -eq "SectionHeader") { continue }
            $TodayValues[$row.Metric] = $row.Value
        }

        # -- Names of section header rows (for Excel styling) --
        $SectionHeaderNames = @($SummaryRows | Where-Object { $_.Category -eq "SectionHeader" } | Select-Object -ExpandProperty Metric)

        # -- Read existing sheet if available --
        $SheetData   = [ordered]@{}
        $DateColumns = [System.Collections.Generic.List[string]]::new()

        if ($fileExists -and (Test-Path $localTempXlsx)) {
            $existingRows = Import-Excel -Path $localTempXlsx -WorksheetName $SheetName -ErrorAction SilentlyContinue
            if ($existingRows) {
                $allProps = $existingRows[0].PSObject.Properties.Name
                foreach ($col in ($allProps | Select-Object -Skip 1)) {
                    if (-not $DateColumns.Contains($col)) { $DateColumns.Add($col) }
                }
                foreach ($existRow in $existingRows) {
                    $mName = $existRow.Metric
                    if (-not $SheetData.Contains($mName)) { $SheetData[$mName] = [ordered]@{} }
                    foreach ($col in $DateColumns) { $SheetData[$mName][$col] = $existRow.$col }
                }
                Write-Log -Message "Loaded existing sheet '$SheetName' with $($DateColumns.Count) date column(s)." -ScriptName $ScriptName -LogPath $LogPath
            }
        }

        # -- Merge today's column --
        if (-not $DateColumns.Contains($RunDate)) {
            $DateColumns.Add($RunDate)
            Write-Log -Message "Adding new date column: $RunDate" -ScriptName $ScriptName -LogPath $LogPath
        }
        else {
            Write-Log -Message "Date column '$RunDate' already exists. Overwriting today's values." -ScriptName $ScriptName -LogPath $LogPath
        }

        # Preserve existing row order; insert section headers back in correct position
        # Build a canonical ordered metric list from SummaryRows (all rows, including headers)
        $canonicalOrder = @($SummaryRows | Where-Object { $_.Category -ne "Metadata" } | Select-Object -ExpandProperty Metric)

        foreach ($metric in $TodayValues.Keys) {
            if (-not $SheetData.Contains($metric)) { $SheetData[$metric] = [ordered]@{} }
            $SheetData[$metric][$RunDate] = $TodayValues[$metric]
        }

        # -- Build export rows in canonical order --
        $ExportRows = foreach ($metric in $canonicalOrder) {
            $obj = [ordered]@{ Metric = $metric }
            foreach ($dateCol in $DateColumns) {
                $obj[$dateCol] = if ($SheetData.Contains($metric) -and $SheetData[$metric].Contains($dateCol)) { $SheetData[$metric][$dateCol] } else { "" }
            }
            [PSCustomObject]$obj
        }

        # -- Write sheet --
        $excelParams = @{
            Path          = $localTempXlsx
            WorksheetName = $SheetName
            ClearSheet    = $true
            AutoSize      = $true
            FreezeTopRow  = $true
            BoldTopRow    = $true
            TableName     = ("Counts_" + (Get-Date -Format "MMMyyyy"))
            TableStyle    = "Medium9"
            ErrorAction   = "Stop"
        }
        $ExportRows | Export-Excel @excelParams

        # -- Apply section header row styling (dark purple bold white text) --
        $pkg = Open-ExcelPackage -Path $localTempXlsx
        $ws  = $pkg.Workbook.Worksheets[$SheetName]
        if ($ws) {
            $endCol     = $ws.Dimension.End.Column
            $purpleDark = [System.Drawing.Color]::FromArgb(91, 74, 130)
            $white      = [System.Drawing.Color]::White
            for ($r = 2; $r -le $ws.Dimension.End.Row; $r++) {
                if ([string]$ws.Cells[$r, 1].Value -in $SectionHeaderNames) {
                    $rng = $ws.Cells[$r, 1, $r, $endCol]
                    $rng.Style.Font.Bold = $true
                    $rng.Style.Font.Color.SetColor($white)
                    $rng.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rng.Style.Fill.BackgroundColor.SetColor($purpleDark)
                }
            }
        }
        Close-ExcelPackage $pkg
        Write-Log -Message "Excel sheet '$SheetName' updated with $($DateColumns.Count) date column(s) and section headers styled." -ScriptName $ScriptName -LogPath $LogPath

        # -- Upload --
        Write-Log -Message "Uploading updated Excel to SharePoint folder: $SpFolderRelPath" -ScriptName $ScriptName -LogPath $LogPath
        Add-PnPFile -Path $localTempXlsx -Folder $SpFolderRelPath -ErrorAction Stop
        Write-Log -Message "SharePoint Excel update completed successfully." -ScriptName $ScriptName -LogPath $LogPath
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }
}
