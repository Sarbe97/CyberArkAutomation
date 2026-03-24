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
    # Step 1: Fetch Accounts (Inventory) & Analytics
    # ------------------------
    Write-Log -Message "Fetching Accounts for Inventory and analytics. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
    $limit = 1000
    $offset = 0
    $hasMore = $true

    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $TotalAccountsFound = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0
    $InventoryExport = @()

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
                # Track in-use platform and safe
                $platId = $acc.platformId
                if ($platId) { $InUsePlatformIds[$platId] = $true }
                
                $safeName = $acc.safeName
                if ($safeName) { $InUseSafeNames[$safeName] = $true }

                # Domain vs Non-Domain
                $isDomain = $false
                if ($acc.address) {
                    foreach ($d in $CfgDomains) {
                        if ($acc.address -ieq $d -or $acc.address -ilike "*.$d") {
                            $isDomain = $true
                            break
                        }
                    }
                }
                if ($isDomain) { $DomainAccountsCount++ } else { $NonDomainAccountsCount++ }

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
                    IsDomain     = $isDomain
                }
            }
            $offset += $limit
            Write-Log -Message "Fetched $TotalAccountsFound accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    Write-Log -Message "Inventory collection complete. Total Accounts: $TotalAccountsFound" -ScriptName $ScriptName -LogPath $LogPath
    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count
    $InUseSafesCount = $InUseSafeNames.Keys.Count

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
    Write-Log -Message "Fetching Platforms stats..." -ScriptName $ScriptName -LogPath $LogPath
    # Get the total count and list of platforms
    $platsUri = "$BaseUrl/PasswordVault/API/Platforms?limit=1000"
    $platsResponse = Invoke-CyberArkApi -Uri $platsUri
    
    $allPlats = if ($platsResponse.Platforms) { $platsResponse.Platforms } else { @() }
    
    $MigplatsKeywords = $FeatureConfig.MigratedPlatformKeywords
    $MigratedPlatformsCount = 0
    $ActivePlatformsCount = 0
    $PlatsExport = @()

    foreach ($plat in $allPlats) {
        $platId = if ($plat.PlatformID) { $plat.PlatformID } else { $plat.platformID }
        $platName = $plat.Name
        $isActive = ($plat.Active -eq $true)
        
        if ($isActive) { $ActivePlatformsCount++ }

        $isMigPlat = $false
        if ($MigplatsKeywords) {
            foreach ($kw in $MigplatsKeywords) {
                if ($platName -match "^$kw") { $isMigPlat = $true; break }
            }
        }
        if ($isMigPlat) { $MigratedPlatformsCount++ }

        $PlatsExport += [PSCustomObject]@{
            PlatformID   = $platId
            Name         = $platName
            Active       = $isActive
            IsMigrated   = $isMigPlat
            IsInUse      = $InUsePlatformIds.ContainsKey($platId)
        }
    }
    Write-Log -Message "Platforms - Total: $($allPlats.Count), Active: $ActivePlatformsCount, Migrated: $MigratedPlatformsCount" -ScriptName $ScriptName -LogPath $LogPath


    # ------------------------
    # Step 4: Fetch Safes
    # ------------------------
    Write-Log -Message "Fetching Safes stats..." -ScriptName $ScriptName -LogPath $LogPath
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

    $TotalSafes = 0
    $MigratedSharedSafes = 0
    $PersonalSafesCount = 0
    $SharedSafesCount = 0
    $SafesExport = @()

    foreach ($safe in $allSafes) {
        $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
        
        # Exclude Inbuilt Safes
        $isInbuilt = $false
        foreach ($ib in $InbuiltSafes) {
            if ($safeName -ieq $ib) { $isInbuilt = $true; break }
        }
        if ($isInbuilt) { continue }

        $TotalSafes++

        # Check Personal
        $isPersonal = $false
        if ($PersRegex -and $safeName -match $PersRegex) {
            $isPersonal = $true
            $PersonalSafesCount++
        } else {
            $SharedSafesCount++
            # Check Migrated for Shared Safes
            $isMigrated = $false
            if ($MigKeywords) {
                foreach ($kw in $MigKeywords) {
                    if ($safeName -match "^$kw") { $isMigrated = $true; break }
                }
            }
            if ($isMigrated) { $MigratedSharedSafes++ }
        }

        # Creator and CreationTime
        $creationTime = if ($safe.creationTime) { $safe.creationTime } else { $safe.CreationDate }
        $creator = if ($safe.creator.name) { $safe.creator.name } elseif ($safe.creator) { $safe.creator } else { "Unknown" }

        $SafesExport += [PSCustomObject]@{
            SafeName      = $safeName
            Description   = $safe.description
            CreationTime  = $creationTime
            Creator       = $creator
            IsPersonal    = $isPersonal
            IsMigrated    = $isMigrated # Only relevant for shared safes per logic
        }
    }
    Write-Log -Message "Total non-inbuilt safes: $TotalSafes. Personal: $PersonalSafesCount, Shared: $SharedSafesCount (Migrated: $MigratedSharedSafes)" -ScriptName $ScriptName -LogPath $LogPath


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
        TotalPlatforms         = $allPlats.Count
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
