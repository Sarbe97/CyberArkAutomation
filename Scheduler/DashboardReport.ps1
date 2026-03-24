param (
    [switch]$ManualLogin
)

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

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $FeatureConfig -or -not $FeatureConfig.Enabled) {
    Write-Log -Message "DashboardReport feature disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}
Write-Log -Message "DashboardReport feature enabled. Starting data collection." -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Get Credential and Login
# ------------------------
Write-Log -Message "Retrieving credentials..." -ScriptName $ScriptName -LogPath $LogPath
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ------------------------
    # ------------------------
    # Setup Paths and Cache
    # ------------------------
    $TodayStr = Get-Date -Format "yyyyMMdd"
    $ExportDir = Join-Path $RootPath "Logs"
    if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
    
    $invCacheFile = Join-Path $ExportDir "Cache_Inventory_$TodayStr.csv"
    $platsCacheFile = Join-Path $ExportDir "Cache_Platforms_$TodayStr.csv"
    $safesCacheFile = Join-Path $ExportDir "Cache_Safes_$TodayStr.csv"

    # ------------------------
    # Step 1: Fetch Accounts (Inventory) & Analytics
    # ------------------------
    $InventoryExport = @()
    if (Test-Path $invCacheFile) {
        Write-Log -Message "Loading Inventory from cache: $invCacheFile" -ScriptName $ScriptName -LogPath $LogPath
        $InventoryExport = Import-Csv $invCacheFile
    } else {
        Write-Log -Message "Fetching Accounts for Inventory and analytics. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true
        $TotalAccountsFound = 0
        $CfgDomains = $FeatureConfig.Domains
        if ($null -eq $CfgDomains) { $CfgDomains = @() }

        while ($hasMore) {
            $accUri = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset&Fields=name,address,userName,platformId,safeName,secretType,secretManagement"
            $accResp = Invoke-CyberArkApi -Uri $accUri
            
            $accounts = if ($accResp.value) { $accResp.value } else { @() }
            
            if ($accounts.Count -eq 0 -or $accounts.Count -lt $limit) {
                $hasMore = $false
            }
            
            if ($accounts.Count -gt 0) {
                $TotalAccountsFound += $accounts.Count
                foreach ($acc in $accounts) {
                    # Domain vs Non-Domain
                    $isDomain = $false
                    if ($acc.address) {
                        $firstPart = ($acc.address -split '\.')[0]
                        foreach ($d in $CfgDomains) {
                            if ($firstPart -ieq $d) {
                                $isDomain = $true
                                break
                            }
                        }
                    }

                    # Check CPM disabled status
                    $cpmDisabled = $false
                    if ($acc.secretManagement) {
                        if (($acc.secretManagement.automaticManagementEnabled -eq $false) -or ($acc.secretManagement.manualManagementReason)) {
                            $cpmDisabled = $true
                        }
                    }

                    $InventoryExport += [PSCustomObject]@{
                        AccountName  = $acc.name
                        Address      = $acc.address
                        UserName     = $acc.userName
                        PlatformID   = $acc.platformId
                        SafeName     = $acc.safeName
                        SecretType   = $acc.secretType
                        CPMDisabled  = $cpmDisabled
                        IsDomain     = $isDomain
                    }
                }
                $offset += $limit
                Write-Log -Message "Fetched $TotalAccountsFound accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        $InventoryExport | Export-Csv -Path $invCacheFile -NoTypeInformation
        Write-Log -Message "Inventory saved to $invCacheFile" -ScriptName $ScriptName -LogPath $LogPath
    }

    # Recalculate Inventory Analytics
    Write-Log -Message "Running Inventory analytics..." -ScriptName $ScriptName -LogPath $LogPath
    $TotalAccountsFound = $InventoryExport.Count
    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0

    foreach ($row in $InventoryExport) {
        $pId = $row.PlatformID
        if ($pId) { $InUsePlatformIds[$pId] = $true }
        
        $sName = $row.SafeName
        if ($sName) { $InUseSafeNames[$sName] = $true }

        # Domain vs Non-Domain
        $isDomainCalc = $false
        if ($row.Address) {
            $firstPart = ($row.Address -split '\.')[0]
            foreach ($d in $CfgDomains) {
                if ($firstPart -ieq $d) {
                    $isDomainCalc = $true
                    break
                }
            }
        }
        if ($isDomainCalc) { $DomainAccountsCount++ } else { $NonDomainAccountsCount++ }
        if ($row.CPMDisabled -eq $true -or $row.CPMDisabled -eq "True") { $CpmDisabledCount++ }
    }
    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count
    $InUseSafesCount = $InUseSafeNames.Keys.Count
    Write-Log -Message "Inventory complete. Total: $TotalAccountsFound, Domain: $DomainAccountsCount, InUsePlats: $InUsePlatformsCount" -ScriptName $ScriptName -LogPath $LogPath

    # ------------------------
    # Step 2: Failed Accounts Count
    # ------------------------
    Write-Log -Message "Fetching Failed Accounts Count..." -ScriptName $ScriptName -LogPath $LogPath
    $failedAccUri = "$BaseUrl/PasswordVault/API/Accounts?savedFilter=PolicyFailures&limit=1"
    $failedAccResp = Invoke-CyberArkApi -Uri $failedAccUri
    $FailedAccountsCount = if ($failedAccResp.Total) { $failedAccResp.Total } else { 0 }
    Write-Log -Message "Failed Accounts Count: $FailedAccountsCount" -ScriptName $ScriptName -LogPath $LogPath

    # ------------------------
    # Step 3: Fetch Platforms
    # ------------------------
    $PlatsExport = @()
    if (Test-Path $platsCacheFile) {
        Write-Log -Message "Loading Platforms from cache: $platsCacheFile" -ScriptName $ScriptName -LogPath $LogPath
        $PlatsExport = Import-Csv $platsCacheFile
    } else {
        Write-Log -Message "Fetching Platforms from API..." -ScriptName $ScriptName -LogPath $LogPath
        $platsUri = "$BaseUrl/PasswordVault/API/Platforms?limit=1000"
        $platsResponse = Invoke-CyberArkApi -Uri $platsUri
        $allPlats = if ($platsResponse.Platforms) { $platsResponse.Platforms } else { @() }
        
        $MigplatsKeywords = $FeatureConfig.MigratedPlatformKeywords

        foreach ($plat in $allPlats) {
            $platId = if ($plat.PlatformID) { $plat.PlatformID } else { $plat.platformID }
            $platName = $plat.Name
            $isActive = ($plat.Active -eq $true)
            
            $isMigPlat = $false
            if ($MigplatsKeywords) {
                foreach ($kw in $MigplatsKeywords) {
                    if ($platName -match "^$kw") { $isMigPlat = $true; break }
                }
            }

            $PlatsExport += [PSCustomObject]@{
                PlatformID   = $platId
                Name         = $platName
                Active       = $isActive
                IsMigrated   = $isMigPlat
                IsInUse      = ($null -ne $platId -and $InUsePlatformIds.ContainsKey($platId))
            }
        }
        $PlatsExport | Export-Csv -Path $platsCacheFile -NoTypeInformation
        Write-Log -Message "Platforms saved to $platsCacheFile" -ScriptName $ScriptName -LogPath $LogPath
    }

    # Recalculate Platform Analytics
    $ActivePlatformsCount = 0
    $MigratedPlatformsCount = 0
    foreach ($row in $PlatsExport) {
        if ($row.Active -eq $true -or $row.Active -eq "True") { $ActivePlatformsCount++ }
        if ($row.IsMigrated -eq $true -or $row.IsMigrated -eq "True") { $MigratedPlatformsCount++ }
    }

    # ------------------------
    # Step 4: Fetch Safes
    # ------------------------
    $SafesExport = @()
    if (Test-Path $safesCacheFile) {
        Write-Log -Message "Loading Safes from cache: $safesCacheFile" -ScriptName $ScriptName -LogPath $LogPath
        $SafesExport = Import-Csv $safesCacheFile
    } else {
        Write-Log -Message "Fetching Safes from API..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true
        $allSafes = @()
        $seenSafes = @{}

        while ($hasMore) {
            $safesUri = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
            $safesResponse = Invoke-CyberArkApi -Uri $safesUri
            $batch = if ($safesResponse.value) { $safesResponse.value } elseif ($safesResponse.Safes) { $safesResponse.Safes } else { @() }

            foreach ($s in $batch) {
                $sName = if ($s.safeName) { $s.safeName } else { $s.SafeName }
                if (-not $sName -or $seenSafes.ContainsKey($sName)) { continue }
                $seenSafes[$sName] = $true
                $allSafes += $s
            }
            if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
        }

        $InbuiltSafes = $FeatureConfig.InbuiltSafes
        if ($null -eq $InbuiltSafes) { $InbuiltSafes = @() }
        $MigKeywords = $FeatureConfig.MigratedSafeKeywords
        $PersRegex = $FeatureConfig.PersonalSafePattern

        foreach ($safe in $allSafes) {
            $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
            $isInbuilt = $false
            foreach ($ib in $InbuiltSafes) { if ($safeName -ieq $ib) { $isInbuilt = $true; break } }
            if ($isInbuilt) { continue }

            $isPersonal = $false
            if ($PersRegex -and $safeName -match $PersRegex) {
                $isPersonal = $true
                $isMigrated = $false
            } else {
                $isMigrated = $false
                if ($MigKeywords) {
                    foreach ($kw in $MigKeywords) { if ($safeName -match "^$kw") { $isMigrated = $true; break } }
                }
            }

            $creationTime = if ($safe.creationTime) { $safe.creationTime } else { $safe.CreationDate }
            $creator = if ($safe.creator.name) { $safe.creator.name } elseif ($safe.creator) { $safe.creator } else { "Unknown" }

            $SafesExport += [PSCustomObject]@{
                SafeName      = $safeName
                Description   = $safe.description
                CreationTime  = $creationTime
                Creator       = $creator
                IsPersonal    = $isPersonal
                IsMigrated    = $isMigrated
            }
        }
        $SafesExport | Export-Csv -Path $safesCacheFile -NoTypeInformation
        Write-Log -Message "Safes saved to $safesCacheFile" -ScriptName $ScriptName -LogPath $LogPath
    }

    # Recalculate Safe Analytics
    $TotalSafes = $SafesExport.Count
    $MigratedSharedSafes = 0
    $PersonalSafesCount = 0
    $SharedSafesCount = 0
    foreach ($row in $SafesExport) {
        if ($row.IsPersonal -eq $true -or $row.IsPersonal -eq "True") {
            $PersonalSafesCount++
        } else {
            $SharedSafesCount++
            if ($row.IsMigrated -eq $true -or $row.IsMigrated -eq "True") { $MigratedSharedSafes++ }
        }
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
        TotalAccounts          = $TotalAccountsFound
        DomainAccounts         = $DomainAccountsCount
        NonDomainAccounts      = $NonDomainAccountsCount
        FailedAccounts         = $FailedAccountsCount
        CPMDisabledAccounts    = $CpmDisabledCount
        TotalSafes             = $TotalSafes
        PersonalSafes          = $PersonalSafesCount
        SharedSafes            = $SharedSafesCount
        MigratedSharedSafes    = $MigratedSharedSafes
        InUseSafes             = $InUseSafesCount
        TotalPlatforms         = $PlatsExport.Count
        ActivePlatforms        = $ActivePlatformsCount
        MigratedPlatforms      = $MigratedPlatformsCount
        InUsePlatforms         = $InUsePlatformsCount
        Timestamp              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $SummaryData | Export-Csv -Path $summaryFile -NoTypeInformation

    Write-Log -Message "Reports generated successfully:" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Inventory: $invFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Safes: $safesFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Platforms: $platsFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Summary: $summaryFile" -ScriptName $ScriptName -LogPath $LogPath

}
catch {
    Write-Log -Message "Dashboard Report failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
}
