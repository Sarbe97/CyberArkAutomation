param (
    [switch]$ManualLogin
)

# ------------------------
# Script Identity
# ------------------------
$ScriptName = "DashboardReport"
$RootPath = $PSScriptRoot
$ConfigPath = Join-Path $RootPath "config.json"

# ------------------------
# Setup Paths (yyyyMMdd Subfolder)
# ------------------------
$TodayStr = Get-Date -Format "yyyyMMdd"
$BaseLogDir = Join-Path $RootPath "Logs"
$ExportDir = Join-Path $BaseLogDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
$LogPath = Join-Path $ExportDir "$ScriptName-$TodayStr.log"

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
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ------------------------
    # Setup Cache Paths
    # ------------------------
    $TodayStr = Get-Date -Format "yyyyMMdd"
    # ExportDir already created at script start
    
    $invCacheFile = Join-Path $ExportDir "Cache_Inventory_$TodayStr.csv"
    $platsCacheFile = Join-Path $ExportDir "Cache_Platforms_$TodayStr.csv"
    $safesCacheFile = Join-Path $ExportDir "Cache_Safes_$TodayStr.csv"

    # Load shared feature config
    $CfgDomains = if ($FeatureConfig.Domains) { $FeatureConfig.Domains } else { @() }
    $InbuiltSafes = if ($FeatureConfig.InbuiltSafes) { $FeatureConfig.InbuiltSafes } else { @() }
    $MigSafeKeywords = if ($FeatureConfig.MigratedSafeKeywords) { $FeatureConfig.MigratedSafeKeywords } else { @() }
    $PersSafeRegex = $FeatureConfig.PersonalSafePattern
    $MigPlatKeywords = if ($FeatureConfig.MigratedPlatformKeywords) { $FeatureConfig.MigratedPlatformKeywords } else { @() }
    $ExcludeFailedPlatforms = if ($FeatureConfig.FailedAccountExcludePlatforms) { $FeatureConfig.FailedAccountExcludePlatforms } else { @() }

    # ------------------------
    # Step 1: Fetch Accounts (Inventory) & Analytics
    # ------------------------
    $InventoryExport = @()
    if (Test-Path $invCacheFile) {
        $InventoryExport = Import-Csv $invCacheFile
    } else {
        Write-Log -Message "Fetching Accounts for Inventory and analytics. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true
        $TotalAccountsFound = 0

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
    }

    # Recalculate Inventory Analytics
    $TotalAccountsFound = $InventoryExport.Count
    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0

    foreach ($row in $InventoryExport) {
        $pltId = $row.PlatformID
        if ($pltId) { $InUsePlatformIds[$pltId] = $true }
        
        $sName = $row.SafeName
        if ($sName) { 
            # Check if this in-use safe is an inbuilt safe
            $isIB = $false
            foreach ($ib in $InbuiltSafes) { if ($sName -ieq $ib) { $isIB = $true; break } }
            if (-not $isIB) { $InUseSafeNames[$sName] = $true }
        }

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
    
    # Step 2: Failed Accounts Count (Filtered by InbuiltSafes)
    $failedAccUri = "$BaseUrl/PasswordVault/API/Accounts?savedFilter=PolicyFailures&limit=1000"
    $failedAccResp = Invoke-CyberArkApi -Uri $failedAccUri
    $failedAccounts = if ($failedAccResp.value) { $failedAccResp.value } else { @() }
    
    $filteredFailedAccounts = $failedAccounts | Where-Object {
        $pltId = $_.platformId
        $isExcluded = $false
        foreach ($ep in $ExcludeFailedPlatforms) { if ($pltId -ieq $ep) { $isExcluded = $true; break } }
        -not $isExcluded
    }
    $FailedAccountsCount = $filteredFailedAccounts.Count
    Write-Log -Message "Failed Accounts Count (filtered): $FailedAccountsCount" -ScriptName $ScriptName -LogPath $LogPath

    # ------------------------
    # Step 3: Fetch Platforms
    # ------------------------
    $PlatsExport = @()
    if (Test-Path $platsCacheFile) {
        $PlatsExport = Import-Csv $platsCacheFile
    } else {
        Write-Log -Message "Fetching Active Platforms from API..." -ScriptName $ScriptName -LogPath $LogPath
        $platsUri = "$BaseUrl/PasswordVault/API/Platforms?active=true&limit=500"
        $platsResponse = Invoke-CyberArkApi -Uri $platsUri
        $allPlats = if ($platsResponse.Platforms) { $platsResponse.Platforms } else { @() }

        foreach ($plat in $allPlats) {
            $platId = if ($plat.PlatformID) { $plat.PlatformID } elseif ($plat.platformID) { $plat.platformID } else { $plat.ID }
            $platName = if ($plat.Name) { $plat.Name } elseif ($plat.platformName) { $plat.platformName } else { "Unknown" }
            $isActive = $true # Explicitly filtered in API URL
            
            $isMigPlat = $false
            if ($MigPlatKeywords) {
                foreach ($kw in $MigPlatKeywords) {
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
        $SafesExport = Import-Csv $safesCacheFile
    } else {
        Write-Log -Message "Fetching Safes from API..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 500
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

        foreach ($safe in $allSafes) {
            $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
            $isInbuilt = $false
            foreach ($ib in $InbuiltSafes) { if ($safeName -ieq $ib) { $isInbuilt = $true; break } }
            if ($isInbuilt) { continue }

            $isPersonal = $false
            if ($PersSafeRegex -and $safeName -match $PersSafeRegex) {
                $isPersonal = $true
                $isMigrated = $false
            } else {
                $isMigrated = $false
                if ($MigSafeKeywords) {
                    foreach ($kw in $MigSafeKeywords) { if ($safeName -match "^$kw") { $isMigrated = $true; break } }
                }
            }

            $creationTimeEpoch = if ($safe.creationTime) { $safe.creationTime } else { $safe.CreationDate }
            $creationTimeStr = "Unknown"
            if ($creationTimeEpoch -match "^\d+$") {
                try {
                    $longVal = [long]$creationTimeEpoch
                    if ($longVal -gt 1e11) {
                        $creationTimeStr = [datetimeoffset]::FromUnixTimeMilliseconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss")
                    } else {
                        $creationTimeStr = [datetimeoffset]::FromUnixTimeSeconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                } catch { $creationTimeStr = "Invalid Date ($creationTimeEpoch)" }
            } elseif ($null -ne $creationTimeEpoch) {
                $creationTimeStr = $creationTimeEpoch
            }

            $creator = if ($safe.creator.name) { $safe.creator.name } elseif ($safe.creator) { $safe.creator } else { "Unknown" }

            $SafesExport += [PSCustomObject]@{
                SafeName      = $safeName
                Description   = $safe.description
                CreationTime  = $creationTimeStr
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
    $NotInUseSafesCount = $TotalSafes - $InUseSafesCount



    # ------------------------
    # Export Data
    # ------------------------
    # ExportDir already created at script start
    
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
        NotInUseSafes          = $NotInUseSafesCount
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
