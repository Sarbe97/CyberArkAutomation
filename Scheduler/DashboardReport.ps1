param ()

# ------------------------
# Script Identity
# ------------------------
$ScriptName = "DashboardReport"
$RootPath = $PSScriptRoot
$ConfigPath = Join-Path $RootPath "config.json"
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"

# ------------------------
# Load Utils
# ------------------------
. (Join-Path $RootPath "Utils.ps1")

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Load Config
# ------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Log -Message "config.json not found" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$BaseUrl = $config.BaseUrl
$FeatureConfig = $config.Features.DashboardReport

if ($null -eq $FeatureConfig -or -not $FeatureConfig.Enabled) {
    Write-Log -Message "DashboardReport feature disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ------------------------
# Get Credential from CCP and Login
# ------------------------
Write-Log -Message "Retrieving CCP credentials..." -ScriptName $ScriptName -LogPath $LogPath
$Credential = Get-CCPCredential -CCPConfig $config.CCP -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ------------------------
    # Fetch Safes
    # ------------------------
    Write-Log -Message "Fetching Safes..." -ScriptName $ScriptName -LogPath $LogPath
    $limit = 1000
    $offset = 0
    $hasMore = $true
    $allSafes = @()
    $seenSafes = @{}

    while ($hasMore) {
        $safesUri = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
        $safesResponse = Invoke-CyberArkApi -Uri $safesUri
        
        $batch = @()
        if ($safesResponse.value) { $batch = $safesResponse.value }
        elseif ($safesResponse.Safes) { $batch = $safesResponse.Safes }

        $newAdded = 0
        foreach ($s in $batch) {
            $sName = $s.safeName
            if (-not $sName) { $sName = $s.SafeName }
            
            if (-not $seenSafes.ContainsKey($sName)) {
                $seenSafes[$sName] = $true
                $allSafes += $s
                $newAdded++
            }
        }

        if ($newAdded -eq 0 -or $batch.Count -lt $limit) {
            $hasMore = $false
        } else {
            $offset += $limit
        }
    }

    $TotalSafes = $allSafes.Count
    $MigratedSafes = 0
    $PersonalSafes = 0

    $MigKeywords = $FeatureConfig.MigratedSafeKeywords
    $PersRegex = $FeatureConfig.PersonalSafePattern

    $SafesExport = @()

    foreach ($safe in $allSafes) {
        $safeName = $safe.safeName
        if (-not $safeName) { $safeName = $safe.SafeName }

        # Check Migrated
        $isMigrated = $false
        if ($MigKeywords) {
            foreach ($kw in $MigKeywords) {
                if ($safeName -match "^$kw") { $isMigrated = $true; break }
            }
        }
        if ($isMigrated) { $MigratedSafes++ }

        # Check Personal
        $isPersonal = $false
        if ($PersRegex -and $safeName -match $PersRegex) {
            $isPersonal = $true
            $PersonalSafes++
        }

        # Creator and CreationTime
        $creationTime = $safe.creationTime
        if (-not $creationTime) { $creationTime = $safe.CreationDate }
        $creator = $safe.creator.name
        if (-not $creator -and $safe.creator) { $creator = $safe.creator }
        if (-not $creator) { $creator = "Unknown" }

        $SafesExport += [PSCustomObject]@{
            SafeName      = $safeName
            Description   = $safe.description
            CreationTime  = $creationTime
            Creator       = $creator
            IsMigrated    = $isMigrated
            IsPersonal    = $isPersonal
        }
    }

    # ------------------------
    # Fetch Platforms
    # ------------------------
    Write-Log -Message "Fetching Platforms..." -ScriptName $ScriptName -LogPath $LogPath
    $limit = 1000
    $offset = 0
    $hasMore = $true
    $allPlats = @()
    $seenPlats = @{}

    while ($hasMore) {
        $platsUri = "$BaseUrl/PasswordVault/API/Platforms?limit=$limit&offset=$offset"
        $platsResponse = Invoke-CyberArkApi -Uri $platsUri
        
        $batch = @()
        if ($platsResponse.Platforms) { $batch = $platsResponse.Platforms }
        
        $newAdded = 0
        foreach ($p in $batch) {
            if (-not $seenPlats.ContainsKey($p.PlatformID)) {
                $seenPlats[$p.PlatformID] = $true
                $allPlats += $p
                $newAdded++
            }
        }

        if ($newAdded -eq 0 -or $batch.Count -lt $limit) {
            $hasMore = $false
        } else {
            $offset += $limit
        }
    }
    
    $TotalPlatforms = $allPlats.Count
    $MigplatsKeywords = $FeatureConfig.MigratedPlatformKeywords
    $MigratedPlatforms = 0

    $PlatsExport = @()

    foreach ($plat in $allPlats) {
        $platName = $plat.Name
        $isMigPlat = $false
        if ($MigplatsKeywords) {
            foreach ($kw in $MigplatsKeywords) {
                if ($platName -match "^$kw") { $isMigPlat = $true; break }
            }
        }
        if ($isMigPlat) { $MigratedPlatforms++ }

        $PlatsExport += [PSCustomObject]@{
            PlatformID   = $plat.PlatformID
            Name         = $platName
            Active       = $plat.Active
            IsMigrated   = $isMigPlat
        }
    }

    # ------------------------
    # Fetch Accounts for Inventory & InUse Plats & CPM Disabled
    # ------------------------
    Write-Log -Message "Fetching Accounts to determine In-Use Platforms and CPM Disabled. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
    $limit = 1000
    $offset = 0
    $hasMore = $true

    $InUsePlatformIds = @{}
    $CpmDisabledCount = 0
    $TotalAccountsFound = 0
    $InventoryExport = @()

    while ($hasMore) {
        $accUri = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset&Fields=name,address,userName,platformId,safeName,secretType,secretManagement"
        $accResp = Invoke-CyberArkApi -Uri $accUri
        
        $accounts = if ($accResp.value) { $accResp.value } else { @() }
        
        if ($accounts.Count -eq 0) {
            $hasMore = $false
        } else {
            $TotalAccountsFound += $accounts.Count
            foreach ($acc in $accounts) {
                # Track in-use platform
                $platId = $acc.platformId
                if ($platId) {
                    $InUsePlatformIds[$platId] = $true
                }

                # Check CPM disabled status
                $cpmDisabled = $false
                if ($acc.secretManagement) {
                    if (($acc.secretManagement.automaticManagementEnabled -eq $false) -or ($acc.secretManagement.manualManagementReason)) {
                        $cpmDisabled = $true
                        $CpmDisabledCount++
                    }
                }

                $InventoryExport += [PSCustomObject]@{
                    AccountName  = $acc.name
                    Address      = $acc.address
                    UserName     = $acc.userName
                    PlatformID   = $platId
                    SafeName     = $acc.safeName
                    SecretType   = $acc.secretType
                    CPMDisabled  = $cpmDisabled
                }
            }
            $offset += $limit
            Write-Log -Message "Fetched $TotalAccountsFound accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count

    # Mark which platforms are in-use
    foreach ($p in $PlatsExport) {
        $p | Add-Member -MemberType NoteProperty -Name "IsInUse" -Value ($InUsePlatformIds.ContainsKey($p.PlatformID))
    }

    # ------------------------
    # Export Data
    # ------------------------
    $ExportDir = Join-Path $RootPath "Logs"
    if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    $invFile = Join-Path $ExportDir "DashboardInventoryDetails_$timestamp.csv"
    $safesFile = Join-Path $ExportDir "DashboardSafesDetails_$timestamp.csv"
    $platsFile = Join-Path $ExportDir "DashboardPlatformsDetails_$timestamp.csv"
    $summaryFile = Join-Path $ExportDir "DashboardCounts_$timestamp.csv"

    $InventoryExport | Export-Csv -Path $invFile -NoTypeInformation
    $SafesExport | Export-Csv -Path $safesFile -NoTypeInformation
    $PlatsExport | Export-Csv -Path $platsFile -NoTypeInformation

    $SummaryData = [PSCustomObject]@{
        TotalSafes          = $TotalSafes
        MigratedSafes       = $MigratedSafes
        PersonalSafes       = $PersonalSafes
        TotalPlatforms      = $TotalPlatforms
        MigratedPlatforms   = $MigratedPlatforms
        InUsePlatforms      = $InUsePlatformsCount
        CPMDisabledAccounts = $CpmDisabledCount
        TotalAccounts       = $TotalAccountsFound
        Timestamp           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $SummaryData | Export-Csv -Path $summaryFile -NoTypeInformation

    Write-Log -Message "Reports generated: DashboardCounts, DashboardSafesDetails, DashboardPlatformsDetails, DashboardInventoryDetails" -ScriptName $ScriptName -LogPath $LogPath

}
catch {
    Write-Log -Message "Dashboard Report failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
}
