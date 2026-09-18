# =============================================================================
# SHR_SharePoint.ps1
# Self-contained Microsoft Graph API and SharePoint module for Shift Handover
# =============================================================================

function Get-CCPCredential {
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$CCPConfig,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $query = "Safe=$($CCPConfig.Safe);Object=$($CCPConfig.Object)"
    $uri = "$($CCPConfig.Url)?AppID=$($CCPConfig.AppId)&Query=$query"
    Write-Log -Message "Retrieving secret from CyberArk CCP: Safe=$($CCPConfig.Safe), Object=$($CCPConfig.Object)" -ScriptName $ScriptName -LogPath $LogPath

    $lastError = ""
    for ($i = 1; $i -le 3; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            return @{
                Username = $resp.UserName
                Password = $resp.Content
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Log -Message "CCP retrieval attempt $i failed: $lastError" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            if ($i -lt 3) { Start-Sleep -Seconds 1 }
        }
    }

    throw "CyberArk CCP credential retrieval failed after 3 attempts: $lastError"
}

function Get-SharePointClientSecret {
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$SharePointConfig,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    # Direct secret takes priority
    if (-not [string]::IsNullOrWhiteSpace($SharePointConfig.ClientSecret)) {
        Write-Log -Message "Using direct ClientSecret specified in config." -ScriptName $ScriptName -LogPath $LogPath
        return $SharePointConfig.ClientSecret
    }

    # Fall back to CCP if configured
    if ($null -ne $SharePointConfig.CCP -and -not [string]::IsNullOrWhiteSpace($SharePointConfig.CCP.Safe)) {
        Write-Log -Message "Direct ClientSecret is blank. Fetching from CyberArk CCP..." -ScriptName $ScriptName -LogPath $LogPath
        $cred = Get-CCPCredential -CCPConfig $SharePointConfig.CCP -ScriptName $ScriptName -LogPath $LogPath
        return $cred.Password
    }

    throw "SharePoint ClientSecret is blank and no CCP configuration is available."
}

function Get-GraphAccessToken {
    param (
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
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

    Write-Log -Message "Acquiring Microsoft Graph access token from Azure AD..." -ScriptName $ScriptName -LogPath $LogPath
    $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    Write-Log -Message "Microsoft Graph access token acquired successfully." -ScriptName $ScriptName -LogPath $LogPath
    return $response.access_token
}

function Get-GraphSiteId {
    param (
        [Parameter(Mandatory = $true)][string]$SiteUrl,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $uri = [System.Uri]$SiteUrl
    $hostName = $uri.Host
    $sitePath = $uri.AbsolutePath.TrimEnd('/')
    $graphUrl = "https://graph.microsoft.com/v1.0/sites/${hostName}:${sitePath}"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    Write-Log -Message "Resolving SharePoint site ID from Graph: $graphUrl" -ScriptName $ScriptName -LogPath $LogPath
    $site = Invoke-RestMethod -Uri $graphUrl -Headers $headers -ErrorAction Stop
    Write-Log -Message "Resolved Site ID: $($site.id)" -ScriptName $ScriptName -LogPath $LogPath
    return $site.id
}

function Get-GraphDriveId {
    param (
        [Parameter(Mandatory = $true)][string]$SiteId,
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $graphUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drives"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    Write-Log -Message "Looking up document library '$LibraryName'..." -ScriptName $ScriptName -LogPath $LogPath
    $drives = Invoke-RestMethod -Uri $graphUrl -Headers $headers -ErrorAction Stop
    $drive = $drives.value | Where-Object { $_.name -eq $LibraryName }

    if (-not $drive) {
        $available = ($drives.value | Select-Object -ExpandProperty name) -join ', '
        throw "Document library '$LibraryName' not found on site. Available libraries: $available"
    }

    Write-Log -Message "Resolved Drive ID for '$LibraryName': $($drive.id)" -ScriptName $ScriptName -LogPath $LogPath
    return $drive.id
}

function Download-SharePointFile {
    param (
        [Parameter(Mandatory = $true)][string]$DriveId,
        [Parameter(Mandatory = $true)][string]$ItemPath,
        [Parameter(Mandatory = $true)][string]$LocalDestination,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    $cleanPath = $ItemPath.TrimStart('/')
    $encodedPath = $cleanPath -replace ' ', '%20'
    $graphUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedPath`:/content"
    $headers = @{ Authorization = "Bearer $AccessToken" }

    Write-Log -Message "Downloading tracker from SharePoint: $cleanPath -> $LocalDestination" -ScriptName $ScriptName -LogPath $LogPath
    Invoke-RestMethod -Uri $graphUrl -Headers $headers -OutFile $LocalDestination -ErrorAction Stop
    Write-Log -Message "File downloaded successfully." -ScriptName $ScriptName -LogPath $LogPath
}

function Get-ShiftHandoverWorkbook {
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [string]$LocalExcelPath = "",
        [string]$DailyOutputDir,
        [switch]$ForceDownload,
        [string]$ScriptRoot = "",
        [string]$ScriptName = "SharePoint",
        [string]$LogPath
    )

    # Resolution 1: Runtime Command-Line Parameter (-LocalExcelPath)
    if (-not [string]::IsNullOrWhiteSpace($LocalExcelPath)) {
        if (Test-Path $LocalExcelPath) {
            $resolvedPath = (Resolve-Path $LocalExcelPath).Path
            Write-Log -Message "Runtime LocalExcelPath override specified. Using local file: $resolvedPath" -ScriptName $ScriptName -LogPath $LogPath
            return $resolvedPath
        }
        throw "Specified runtime LocalExcelPath does not exist: $LocalExcelPath"
    }

    # Resolution 2: Configured Local Path (config.json -> ExcelSource.LocalPath or ExcelPath)
    $cfgLocalPath = ""
    if ($Config.ExcelSource -and -not [string]::IsNullOrWhiteSpace($Config.ExcelSource.LocalPath)) {
        $cfgLocalPath = $Config.ExcelSource.LocalPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Config.ExcelPath)) {
        $cfgLocalPath = $Config.ExcelPath
    }

    $isExplicitLocalMode = ($Config.ExcelSource -and $Config.ExcelSource.Mode -ieq "Local")
    $hasConfigLocalPath  = (-not [string]::IsNullOrWhiteSpace($cfgLocalPath))

    if ($isExplicitLocalMode -or $hasConfigLocalPath) {
        if (-not $hasConfigLocalPath) {
            # Default to ShiftHandover_Tracker.xlsx in script directory if Local mode selected without path
            $cfgLocalPath = "ShiftHandover_Tracker.xlsx"
        }

        # Check direct path
        if (Test-Path $cfgLocalPath) {
            $resolvedPath = (Resolve-Path $cfgLocalPath).Path
            Write-Log -Message "Configured local Excel file found: $resolvedPath" -ScriptName $ScriptName -LogPath $LogPath
            return $resolvedPath
        }

        # Check relative to ScriptRoot if provided
        if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
            $combinedPath = Join-Path $ScriptRoot $cfgLocalPath
            if (Test-Path $combinedPath) {
                $resolvedPath = (Resolve-Path $combinedPath).Path
                Write-Log -Message "Configured local Excel file found in script directory: $resolvedPath" -ScriptName $ScriptName -LogPath $LogPath
                return $resolvedPath
            }
        }

        throw "Configured local Excel file does not exist: '$cfgLocalPath'"
    }

    # Resolution 3: SharePoint Download (via Microsoft Graph API)
    $spConfig = $Config.SharePoint
    if ($null -eq $spConfig -or -not $spConfig.Enabled) {
        throw "SharePoint integration is disabled in config and no local Excel file path was provided."
    }

    $fileName = if ($spConfig.FileName) { $spConfig.FileName } else { "ShiftHandover_Tracker.xlsx" }
    $localCachedFile = Join-Path $DailyOutputDir $fileName

    # Check daily cache
    if ((Test-Path $localCachedFile) -and -not $ForceDownload) {
        Write-Log -Message "Existing daily cache found at '$localCachedFile'. (Use -ForceDownload to refresh)" -ScriptName $ScriptName -LogPath $LogPath
        return $localCachedFile
    }

    Write-Log -Message "Connecting to SharePoint via Microsoft Graph API..." -ScriptName $ScriptName -LogPath $LogPath
    $clientSecret = Get-SharePointClientSecret -SharePointConfig $spConfig -ScriptName $ScriptName -LogPath $LogPath
    $token = Get-GraphAccessToken -TenantId $spConfig.TenantId -ClientId $spConfig.ClientId -ClientSecret $clientSecret -ScriptName $ScriptName -LogPath $LogPath
    $siteId = Get-GraphSiteId -SiteUrl $spConfig.SiteUrl -AccessToken $token -ScriptName $ScriptName -LogPath $LogPath
    $driveId = Get-GraphDriveId -SiteId $siteId -LibraryName $spConfig.DocumentLibrary -AccessToken $token -ScriptName $ScriptName -LogPath $LogPath

    $folderPath = if ($spConfig.FolderPath) { $spConfig.FolderPath.TrimEnd('/') } else { "" }
    $itemPath = if ($folderPath) { "$folderPath/$fileName" } else { $fileName }

    Download-SharePointFile -DriveId $driveId -ItemPath $itemPath -LocalDestination $localCachedFile -AccessToken $token -ScriptName $ScriptName -LogPath $LogPath
    return $localCachedFile
}
