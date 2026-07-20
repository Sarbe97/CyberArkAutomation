# ============================================================
# SharePoint Utilities (Microsoft Graph API)
# Common functions for SharePoint Excel integration shared
# across all Scheduler features.
#
# Auth: Azure AD App — OAuth 2.0 Client Credentials flow
# API:  Microsoft Graph v1.0
# Dependencies: ImportExcel (for Excel file manipulation only)
#
# Required Azure AD App Permission:
#   Sites.ReadWrite.All (Application) — Microsoft Graph
#
# Exposes:
#   Get-GraphAccessToken      — OAuth2 token via client credentials
#   Get-SharePointClientSecret — Resolve secret (direct or CCP)
#   Update-SharePointExcel    — Download/create Excel, merge daily
#                               data column, upload back via Graph
# ============================================================

# -------------------------------------------------------
# Get-SPAccessToken
# OAuth 2.0 Client Credentials flow for SharePoint REST.
# POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
# Returns: Bearer access token string.
# -------------------------------------------------------
function Get-SPAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $uri = [System.Uri]$SiteUrl
    $spScope = "https://$($uri.Host)/.default"

    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $spScope
        grant_type    = "client_credentials"
    }

    if ($LogPath) {
        Write-Log -Message "Requesting SP access token from Azure AD (TenantId: $TenantId, ClientId: $ClientId, Scope: $spScope)..." -ScriptName $ScriptName -LogPath $LogPath
    }

    $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

    if ($LogPath) {
        Write-Log -Message "SP access token acquired successfully." -ScriptName $ScriptName -LogPath $LogPath
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
# Get-SPFile (Download)
# Downloads a file from SharePoint via SP REST API.
# GET {siteUrl}/_api/web/GetFileByServerRelativeUrl('{fileRelativeUrl}')/$value
# Returns $true if downloaded, $false if file not found.
# -------------------------------------------------------
function Get-SPFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$FileRelativeUrl,

        [Parameter(Mandatory = $true)]
        [string]$LocalFilePath,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $fileRelUrlEncoded = $FileRelativeUrl -replace "'", "''"
    $restUrl = "$SiteUrl/_api/web/GetFileByServerRelativeUrl('$fileRelUrlEncoded')/`$value"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    try {
        Invoke-RestMethod -Uri $restUrl -Headers $headers -OutFile $LocalFilePath -ErrorAction Stop

        if ($LogPath) {
            Write-Log -Message "Downloaded file from SharePoint: $FileRelativeUrl" -ScriptName $ScriptName -LogPath $LogPath
        }
        return $true
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 404 -or $_.Exception.Message -match "404") {
            if ($LogPath) {
                Write-Log -Message "File not found on SharePoint: $FileRelativeUrl. A new file will be created." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
            return $false
        }
        throw
    }
}

# -------------------------------------------------------
# Set-SPFile (Upload)
# Uploads a file to SharePoint via SP REST API.
# POST {siteUrl}/_api/web/GetFolderByServerRelativeUrl('{folderRelativeUrl}')/Files/add(url='{filename}',overwrite=true)
# -------------------------------------------------------
function Set-SPFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$FolderRelativeUrl,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$LocalFilePath,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $folderRelUrlEncoded = $FolderRelativeUrl -replace "'", "''"
    $fileNameEncoded = $FileName -replace "'", "''"
    
    $restUrl = "$SiteUrl/_api/web/GetFolderByServerRelativeUrl('$folderRelUrlEncoded')/Files/add(url='$fileNameEncoded',overwrite=true)"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    $fileBytes = [System.IO.File]::ReadAllBytes($LocalFilePath)

    if ($LogPath) {
        $fileSizeKB = [math]::Round($fileBytes.Length / 1024, 1)
        Write-Log -Message "Uploading file to SharePoint: $FolderRelativeUrl/$FileName ($fileSizeKB KB)" -ScriptName $ScriptName -LogPath $LogPath
    }

    $null = Invoke-RestMethod -Uri $restUrl -Headers $headers -Method Post -Body $fileBytes -ContentType "application/octet-stream" -ErrorAction Stop

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
#            (e.g. "Jul-2026") — monthly sheets.
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

    # -- Get SP Access Token --
    $accessToken = Get-SPAccessToken `
        -TenantId     $SharePointGlobalConfig.TenantId `
        -ClientId     $SharePointGlobalConfig.ClientId `
        -ClientSecret $clientSecret `
        -SiteUrl      $SharePointGlobalConfig.SiteUrl `
        -ScriptName   $ScriptName `
        -LogPath       $LogPath

    # -- Build Server Relative URLs --
    $uri = [System.Uri]$SharePointGlobalConfig.SiteUrl
    $sitePath = $uri.AbsolutePath.TrimEnd('/')
    
    $folderRelUrl = "$sitePath/$($SharePointGlobalConfig.DocumentLibrary)"
    if (-not [string]::IsNullOrWhiteSpace($FolderPath)) {
        $folderRelUrl += "/$($FolderPath.Trim('/'))"
    }
    $fileRelUrl = "$folderRelUrl/$FileName"

    $localTempXlsx = Join-Path $LocalTempDir $FileName

    # -- Download existing file or start fresh --
    $fileExists = Get-SPFile `
        -SiteUrl         $SharePointGlobalConfig.SiteUrl `
        -FileRelativeUrl $fileRelUrl `
        -LocalFilePath   $localTempXlsx `
        -AccessToken     $accessToken `
        -ScriptName      $ScriptName `
        -LogPath         $LogPath

    # -- Resolve sheet name --
    $effectiveSheet = if (-not [string]::IsNullOrWhiteSpace($SheetName)) { $SheetName } else { Get-Date -Format "MMM-yyyy" }
    $RunDate = Get-Date -Format "yyyy-MM-dd"

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
        $existingRows = Import-Excel -Path $localTempXlsx -WorksheetName $effectiveSheet -ErrorAction SilentlyContinue
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
            if ($LogPath) {
                Write-Log -Message "Loaded existing sheet '$effectiveSheet' with $($DateColumns.Count) date column(s)." -ScriptName $ScriptName -LogPath $LogPath
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

    # Build canonical ordered metric list from DataRows (including section headers)
    $canonicalOrder = @($DataRows | Select-Object -ExpandProperty Metric)

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
    $safeTableName = ($effectiveSheet -replace '[^A-Za-z0-9]', '') + "_" + (Get-Date -Format "MMMyyyy")
    $excelParams = @{
        Path          = $localTempXlsx
        WorksheetName = $effectiveSheet
        ClearSheet    = $true
        AutoSize      = $true
        FreezeTopRow  = $true
        BoldTopRow    = $true
        TableName     = $safeTableName
        TableStyle    = "Medium9"
        ErrorAction   = "Stop"
    }
    $ExportRows | Export-Excel @excelParams

    # -- Apply section header styling if specified --
    if ($SectionHeaders.Count -gt 0) {
        $pkg = Open-ExcelPackage -Path $localTempXlsx
        $ws  = $pkg.Workbook.Worksheets[$effectiveSheet]
        if ($ws) {
            $endCol     = $ws.Dimension.End.Column
            $purpleDark = [System.Drawing.Color]::FromArgb(91, 74, 130)
            $white      = [System.Drawing.Color]::White
            for ($r = 2; $r -le $ws.Dimension.End.Row; $r++) {
                if ([string]$ws.Cells[$r, 1].Value -in $SectionHeaders) {
                    $rng = $ws.Cells[$r, 1, $r, $endCol]
                    $rng.Style.Font.Bold = $true
                    $rng.Style.Font.Color.SetColor($white)
                    $rng.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $rng.Style.Fill.BackgroundColor.SetColor($purpleDark)
                }
            }
        }
        Close-ExcelPackage $pkg

        if ($LogPath) {
            Write-Log -Message "Section header styling applied to $($SectionHeaders.Count) header row(s)." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    if ($LogPath) {
        Write-Log -Message "Excel sheet '$effectiveSheet' updated with $($DateColumns.Count) date column(s)." -ScriptName $ScriptName -LogPath $LogPath
    }

    # -- Upload via SP REST API --
    Set-SPFile `
        -SiteUrl           $SharePointGlobalConfig.SiteUrl `
        -FolderRelativeUrl $folderRelUrl `
        -FileName          $FileName `
        -LocalFilePath     $localTempXlsx `
        -AccessToken       $accessToken `
        -ScriptName        $ScriptName `
        -LogPath           $LogPath

    if ($LogPath) {
        Write-Log -Message "SharePoint Excel update completed successfully." -ScriptName $ScriptName -LogPath $LogPath
    }
}
