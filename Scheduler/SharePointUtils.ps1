# ============================================================
# SharePoint Utilities (Microsoft Graph API)
# Common functions for SharePoint Excel integration shared
# across all Scheduler features.
#
# Auth: Azure AD App  OAuth 2.0 Client Credentials flow
# API:  Microsoft Graph v1.0
# Dependencies: ImportExcel (for Excel file manipulation only)
#
# Required Azure AD App Permission:
#   Sites.ReadWrite.All (Application)  Microsoft Graph
#
# Exposes:
#   Get-GraphAccessToken       OAuth2 token via client credentials
#   Get-SharePointClientSecret  Resolve secret (direct or CCP)
#   Update-SharePointExcel     Download/create Excel, merge daily
#                               data column, upload back via Graph
# ============================================================

# -------------------------------------------------------
# Get-GraphAccessToken
# OAuth 2.0 Client Credentials flow.
# POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
# Returns: Bearer access token string.
# -------------------------------------------------------
function Get-GraphAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
        grant_type    = "client_credentials"
    }

    if ($LogPath) {
        Write-Log -Message "Requesting Graph access token from Azure AD (TenantId: $TenantId, ClientId: $ClientId)..." -ScriptName $ScriptName -LogPath $LogPath
    }

    $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

    if ($LogPath) {
        Write-Log -Message "Graph access token acquired successfully." -ScriptName $ScriptName -LogPath $LogPath
    }

    return $response.access_token
}

# -------------------------------------------------------
# Get-SharePointClientSecret
# Resolves the client secret: direct value if non-blank,
# otherwise falls back to CCP retrieval (Option C pattern).
# Returns the plain-text secret string.
# -------------------------------------------------------
function Get-SharePointClientSecret {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointConfig,

        [string]$GlobalCCPUrl,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    # Direct secret takes priority if non-blank
    if (-not [string]::IsNullOrWhiteSpace($SharePointConfig.ClientSecret)) {
        if ($LogPath) {
            Write-Log -Message "Using direct ClientSecret from config." -ScriptName $ScriptName -LogPath $LogPath
        }
        return $SharePointConfig.ClientSecret
    }

    # Fall back to CCP
    if ($null -eq $SharePointConfig.CCP) {
        throw "SharePoint ClientSecret is blank and no CCP config provided. Cannot authenticate."
    }

    if ($LogPath) {
        Write-Log -Message "ClientSecret is blank. Fetching from CyberArk CCP..." -ScriptName $ScriptName -LogPath $LogPath
    }

    $ccpConfig = [PSCustomObject]@{
        Url    = if ($SharePointConfig.CCP.Url) { $SharePointConfig.CCP.Url } else { $GlobalCCPUrl }
        AppId  = $SharePointConfig.CCP.AppId
        Safe   = $SharePointConfig.CCP.Safe
        Object = $SharePointConfig.CCP.Object
    }

    $credential = Get-CCPCredential -CCPConfig $ccpConfig -ScriptName $ScriptName -LogPath $LogPath
    return $credential.Password
}

# -------------------------------------------------------
# Get-GraphSiteId
# Resolves a SharePoint site URL to a Graph site ID.
# GET https://graph.microsoft.com/v1.0/sites/{host}:/{path}
# -------------------------------------------------------
function Get-GraphSiteId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $uri = [System.Uri]$SiteUrl
    $hostName = $uri.Host
    $sitePath = $uri.AbsolutePath.TrimEnd('/')

    $graphUrl = "https://graph.microsoft.com/v1.0/sites/${hostName}:${sitePath}"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    if ($LogPath) {
        Write-Log -Message "Resolving SharePoint site ID: $graphUrl" -ScriptName $ScriptName -LogPath $LogPath
    }

    $site = Invoke-RestMethod -Uri $graphUrl -Headers $headers -ErrorAction Stop

    if ($LogPath) {
        Write-Log -Message "Site ID resolved: $($site.id)" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $site.id
}

# -------------------------------------------------------
# Get-GraphDriveId
# Finds the drive (document library) ID by name.
# GET https://graph.microsoft.com/v1.0/sites/{siteId}/drives
# -------------------------------------------------------
function Get-GraphDriveId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteId,

        [Parameter(Mandatory = $true)]
        [string]$LibraryName,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $graphUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drives"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    if ($LogPath) {
        Write-Log -Message "Looking up document library '$LibraryName'..." -ScriptName $ScriptName -LogPath $LogPath
    }

    $drives = Invoke-RestMethod -Uri $graphUrl -Headers $headers -ErrorAction Stop
    $drive = $drives.value | Where-Object { $_.name -eq $LibraryName }

    if (-not $drive) {
        $available = ($drives.value | Select-Object -ExpandProperty name) -join ', '
        throw "Document library '$LibraryName' not found on this site. Available libraries: $available"
    }

    if ($LogPath) {
        Write-Log -Message "Drive ID for '$LibraryName': $($drive.id)" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $drive.id
}

# -------------------------------------------------------
# Get-GraphFile (Download)
# Downloads a file from SharePoint via Graph.
# GET /drives/{driveId}/root:/{path}:/content
# Returns $true if downloaded, $false if file not found.
# -------------------------------------------------------
function Get-GraphFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveId,

        [Parameter(Mandatory = $true)]
        [string]$ItemPath,           # Path within the drive (e.g. "Folder/SubFolder/File.xlsx")

        [Parameter(Mandatory = $true)]
        [string]$LocalFilePath,      # Where to save locally

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $encodedPath = $ItemPath -replace ' ', '%20'
    $graphUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedPath`:/content"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    try {
        Invoke-RestMethod -Uri $graphUrl -Headers $headers -OutFile $LocalFilePath -ErrorAction Stop

        if ($LogPath) {
            Write-Log -Message "Downloaded file from SharePoint: $ItemPath" -ScriptName $ScriptName -LogPath $LogPath
        }
        return $true
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 404) {
            if ($LogPath) {
                Write-Log -Message "File not found on SharePoint: $ItemPath. A new file will be created." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
            return $false
        }

        throw
    }
}

# -------------------------------------------------------
# Set-GraphFile (Upload)
# Uploads a file to SharePoint via Graph.
# PUT /drives/{driveId}/root:/{path}:/content
# Simple upload  works for files up to 4 MB.
# -------------------------------------------------------
function Set-GraphFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveId,

        [Parameter(Mandatory = $true)]
        [string]$ItemPath,           # Path within the drive

        [Parameter(Mandatory = $true)]
        [string]$LocalFilePath,      # Local file to upload

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $encodedPath = $ItemPath -replace ' ', '%20'
    $graphUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedPath`:/content"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    $fileBytes = [System.IO.File]::ReadAllBytes($LocalFilePath)

    if ($LogPath) {
        $fileSizeKB = [math]::Round($fileBytes.Length / 1024, 1)
        Write-Log -Message "Uploading file to SharePoint: $ItemPath ($fileSizeKB KB)" -ScriptName $ScriptName -LogPath $LogPath
    }

    $null = Invoke-RestMethod -Uri $graphUrl -Headers $headers -Method Put -Body $fileBytes -ContentType "application/octet-stream" -ErrorAction Stop

    if ($LogPath) {
        Write-Log -Message "File uploaded successfully." -ScriptName $ScriptName -LogPath $LogPath
    }
}

# -------------------------------------------------------
# Update-SharePointExcel
# Generic function: download/create an Excel file on
# SharePoint via Microsoft Graph, merge a daily data
# column into a named sheet, and upload it back.
#
# DataRows: Array of objects with 'Metric' and 'Value'
#           properties.
# SheetName: If blank/omitted, defaults to "MMM-yyyy"
#            (e.g. "Jul-2026")  monthly sheets.
# SectionHeaders: Optional array of Metric names to
#                 style as section header rows.
# -------------------------------------------------------
function Update-SharePointExcel {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SharePointGlobalConfig,    # Global SharePoint config block

        [Parameter(Mandatory = $true)]
        [string]$FileName,                          # Excel file name (e.g. "SAA_DailyReport.xlsx")

        [string]$FolderPath,                        # Path within the document library (from feature config)

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$DataRows,                # Objects with .Metric and .Value

        [string]$SheetName,                         # Sheet name (blank = MMM-yyyy)

        [string]$LocalTempDir,                      # Temp dir for download/create

        [string[]]$SectionHeaders = @(),            # Metric names that are section headers

        [string]$GlobalCCPUrl,                      # Fallback CCP URL from global config
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    Import-Module ImportExcel -ErrorAction Stop

    if ($LogPath) {
        Write-Log -Message "SharePoint Excel update started (Microsoft Graph)..." -ScriptName $ScriptName -LogPath $LogPath
    }

    # -- Resolve Client Secret (direct or CCP) --
    $clientSecret = Get-SharePointClientSecret `
        -SharePointConfig $SharePointGlobalConfig `
        -GlobalCCPUrl     $GlobalCCPUrl `
        -ScriptName       $ScriptName `
        -LogPath          $LogPath

    # -- Get Graph Access Token --
    $accessToken = Get-GraphAccessToken `
        -TenantId     $SharePointGlobalConfig.TenantId `
        -ClientId     $SharePointGlobalConfig.ClientId `
        -ClientSecret $clientSecret `
        -ScriptName   $ScriptName `
        -LogPath      $LogPath

    # -- Resolve Site ID and Drive ID --
    $siteId = Get-GraphSiteId `
        -SiteUrl     $SharePointGlobalConfig.SiteUrl `
        -AccessToken $accessToken `
        -ScriptName  $ScriptName `
        -LogPath     $LogPath

    $driveId = Get-GraphDriveId `
        -SiteId      $siteId `
        -LibraryName $SharePointGlobalConfig.DocumentLibrary `
        -AccessToken $accessToken `
        -ScriptName  $ScriptName `
        -LogPath     $LogPath

    # -- Build paths --
    $cleanFolderPath = if ($FolderPath) { $FolderPath.TrimEnd('/') } else { "" }
    $graphItemPath   = if ($cleanFolderPath) { "$cleanFolderPath/$FileName" } else { $FileName }
    $localTempXlsx   = Join-Path $LocalTempDir $FileName

    # -- Download existing file or start fresh --
    $fileExists = Get-GraphFile `
        -DriveId       $driveId `
        -ItemPath      $graphItemPath `
        -LocalFilePath $localTempXlsx `
        -AccessToken   $accessToken `
        -ScriptName    $ScriptName `
        -LogPath       $LogPath

    # -- Resolve sheet name --
    $effectiveSheet = if (-not [string]::IsNullOrWhiteSpace($SheetName)) { $SheetName } else { Get-Date -Format "MMM-yyyy" }
    $RunDate        = Get-Date -Format "yyyy-MM-dd"

    if ($LogPath) {
        Write-Log -Message "Target sheet: '$effectiveSheet', Date column: '$RunDate'" -ScriptName $ScriptName -LogPath $LogPath
    }

    # -- Build today's value lookup (skip section headers) --
    $TodayValues = [ordered]@{}
    foreach ($row in $DataRows) {
        if ($row.Metric -in $SectionHeaders) { continue }
        $TodayValues[$row.Metric] = $row.Value
    }

    # -- Read existing sheet if available --
    $SheetData   = [ordered]@{}
    $DateColumns = [System.Collections.Generic.List[string]]::new()

    if ($fileExists -and (Test-Path $localTempXlsx)) {

        # Peek at sheet names to diagnose any name mismatch
        try {
            $peekPkg    = Open-ExcelPackage -Path $localTempXlsx
            $sheetNames = $peekPkg.Workbook.Worksheets | Select-Object -ExpandProperty Name
            Write-Host "[DBG] Sheets in workbook: $($sheetNames -join ', ')" -ForegroundColor Yellow
            Close-ExcelPackage $peekPkg
        }
        catch {
            Write-Host "[DBG] Could not peek at workbook sheets: $($_.Exception.Message)" -ForegroundColor Red
        }

        # Import existing rows - wrapped in try/catch because EPPlus can throw .NET exceptions
        # that bypass -ErrorAction SilentlyContinue
        $rawImport = $null
        try {
            $rawImport = Import-Excel -Path $localTempXlsx -WorksheetName $effectiveSheet -ErrorAction Stop
            Write-Host "[DBG] Import-Excel: $(@($rawImport).Count) row(s) read from sheet '$effectiveSheet'" -ForegroundColor Yellow
        }
        catch {
            Write-Host "[DBG] Import-Excel failed for sheet '$effectiveSheet': $($_.Exception.Message)" -ForegroundColor Red
            if ($LogPath) {
                Write-Log -Message "Could not read existing sheet '$effectiveSheet' (will start fresh): $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
        }

        $existingRows = @($rawImport | Where-Object { $_ -ne $null })

        if ($existingRows.Count -gt 0 -and $null -ne $existingRows[0]) {
            $allProps = $existingRows[0].PSObject.Properties.Name
            foreach ($col in ($allProps | Select-Object -Skip 1)) {
                if (-not $DateColumns.Contains($col)) { $DateColumns.Add($col) }
            }
            foreach ($existRow in $existingRows) {
                if ($null -eq $existRow) { continue }
                $mName = $existRow.Metric
                if ([string]::IsNullOrWhiteSpace($mName)) { continue }
                if (-not $SheetData.Contains($mName)) { $SheetData[$mName] = [ordered]@{} }
                foreach ($col in $DateColumns) { $SheetData[$mName][$col] = $existRow.$col }
            }
            if ($LogPath) {
                Write-Log -Message "Loaded existing sheet '$effectiveSheet' with $($DateColumns.Count) date column(s)." -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        else {
            if ($LogPath) {
                Write-Log -Message "Existing file found but sheet '$effectiveSheet' has no readable rows. Starting fresh." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
        }
    }

    # -- Merge today's column --
    if (-not $DateColumns.Contains($RunDate)) {
        $DateColumns.Add($RunDate)
        if ($LogPath) {
            Write-Log -Message "Adding new date column: $RunDate" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    else {
        if ($LogPath) {
            Write-Log -Message "Date column '$RunDate' already exists. Overwriting today's values." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # -- Build canonical ordered metric list from DataRows (including section headers) --
    $canonicalOrder = @($DataRows | Select-Object -ExpandProperty Metric)

    # -- Merge today's values into SheetData --
    foreach ($metric in $TodayValues.Keys) {
        if (-not $SheetData.Contains($metric)) { $SheetData[$metric] = [ordered]@{} }
        $SheetData[$metric][$RunDate] = $TodayValues[$metric]
    }

    # -- Build export rows in canonical order --
    $ExportRows = foreach ($metric in $canonicalOrder) {
        $obj = [ordered]@{ Metric = $metric }
        foreach ($dateCol in $DateColumns) {
            $obj[$dateCol] = if ($SheetData.Contains($metric) -and $SheetData[$metric].Contains($dateCol)) {
                $SheetData[$metric][$dateCol]
            } else { "" }
        }
        [PSCustomObject]$obj
    }

    # -- Write sheet --
    $safeTableName = ($effectiveSheet -replace '[^A-Za-z0-9]', '') + "_" + (Get-Date -Format "MMMyyyy")
    $excelParams = @{
        Path          = $localTempXlsx
        WorksheetName = $effectiveSheet
        ClearSheet    = $true
        AutoSize      = $true
        FreezeTopRow  = $true
        TableName     = $safeTableName
        TableStyle    = "None"
        ErrorAction   = "Stop"
    }
    $ExportRows | Export-Excel @excelParams

    # -- Apply styling, formatting, and colors --
    $pkg = Open-ExcelPackage -Path $localTempXlsx
    $ws  = $pkg.Workbook.Worksheets[$effectiveSheet]

    if ($ws -and $null -ne $ws.Dimension) {
        $endCol     = $ws.Dimension.End.Column
        $endRow     = $ws.Dimension.End.Row
        
        # Format all data columns with thousand separators
        if ($endCol -ge 2) {
            $ws.Cells[2, 2, $endRow, $endCol].Style.Numberformat.Format = "#,##0"
        }
        
        # Make the Metric column (Column A) bold
        $ws.Cells[2, 1, $endRow, 1].Style.Font.Bold = $true

        # --- Custom Theme Colors (Rose & Turquoise) ---
        $colorWhite     = [System.Drawing.Color]::White
        $colorHeader    = [System.Drawing.Color]::FromArgb(233, 132, 181) # E984B5 (Rose Pink)
        $colorAltRow    = [System.Drawing.Color]::FromArgb(240, 251, 250) # F0FBFA (Soft Turquoise)
        $colorSecHeader = [System.Drawing.Color]::FromArgb(69, 184, 172)  # 45B8AC (Turquoise)
        
        $green          = [System.Drawing.Color]::FromArgb(39, 174, 96) # Success Green
        $red            = [System.Drawing.Color]::FromArgb(231, 76, 60) # Alert Red

        # Style the Top Header Row
        $headerRng = $ws.Cells[1, 1, 1, $endCol]
        $headerRng.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $headerRng.Style.Fill.BackgroundColor.SetColor($colorHeader)
        $headerRng.Style.Font.Color.SetColor($colorWhite)
        $headerRng.Style.Font.Bold = $true

        for ($r = 2; $r -le $endRow; $r++) {
            $metricName = [string]$ws.Cells[$r, 1].Value
            $rowRng = $ws.Cells[$r, 1, $r, $endCol]
            
            # Apply Alternating Row Colors
            $rowRng.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            if ($r % 2 -eq 0) {
                $rowRng.Style.Fill.BackgroundColor.SetColor($colorAltRow)
            } else {
                $rowRng.Style.Fill.BackgroundColor.SetColor($colorWhite)
            }
            
            # Section Header formatting overrides
            if ($SectionHeaders.Count -gt 0 -and $metricName -in $SectionHeaders) {
                $rowRng.Style.Font.Bold = $true
                $rowRng.Style.Font.Color.SetColor($colorWhite)
                $rowRng.Style.Fill.BackgroundColor.SetColor($colorSecHeader)
            }

            # Trend Colors (Red/Green) for Delta metrics
            for ($c = 2; $c -le $endCol; $c++) {
                $cellStr = [string]$ws.Cells[$r, $c].Value
                if ($cellStr -match "^-\d+") {
                    $ws.Cells[$r, $c].Style.Font.Color.SetColor($green)
                    $ws.Cells[$r, $c].Style.Font.Bold = $true
                } elseif ($cellStr -match "^\+\d+") {
                    $ws.Cells[$r, $c].Style.Font.Color.SetColor($red)
                    $ws.Cells[$r, $c].Style.Font.Bold = $true
                }
            }
        }
        
        Close-ExcelPackage $pkg
        
        if ($LogPath) {
            Write-Log -Message "Formatting and section header styling applied." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    if ($LogPath) {
        Write-Log -Message "Excel sheet '$effectiveSheet' updated with $($DateColumns.Count) date column(s)." -ScriptName $ScriptName -LogPath $LogPath
    }

    # -- Upload via Graph --
    Set-GraphFile `
        -DriveId       $driveId `
        -ItemPath      $graphItemPath `
        -LocalFilePath $localTempXlsx `
        -AccessToken   $accessToken `
        -ScriptName    $ScriptName `
        -LogPath       $LogPath

    if ($LogPath) {
        Write-Log -Message "SharePoint Excel update completed successfully." -ScriptName $ScriptName -LogPath $LogPath
    }
}
