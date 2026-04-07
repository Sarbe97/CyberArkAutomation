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
# Setup Paths (Logs & Output)
# ------------------------
$TodayStr = Get-Date -Format "yyyyMMdd"
$LogDir = Join-Path $RootPath "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath = Join-Path $LogDir "$ScriptName-$TodayStr.log"

$BaseOutputDir = Join-Path $RootPath "Output"
$ExportDir = Join-Path $BaseOutputDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

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
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ------------------------
    # Setup Cache Paths
    # ------------------------
    $TodayStr = Get-Date -Format "yyyyMMdd"
    # ExportDir already created at script start (Output\yyyyMMdd)
    
    $rawAccsCache = Join-Path $ExportDir "RawCache_Accounts_$TodayStr.csv"
    $rawPlatsCache = Join-Path $ExportDir "RawCache_Platforms_$TodayStr.csv"
    $rawSafesCache = Join-Path $ExportDir "RawCache_Safes_$TodayStr.csv"
    $rawPendingDiscCache = Join-Path $ExportDir "RawCache_PendingDiscovered_$TodayStr.csv"
    
    # Final Processed Report Filenames (Timestamped)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $invFile     = Join-Path $ExportDir "DashboardInventoryDetails_$timestamp.csv"
    $safesFile   = Join-Path $ExportDir "DashboardSafesDetails_$timestamp.csv"
    $platsFile   = Join-Path $ExportDir "DashboardPlatformsDetails_$timestamp.csv"
    $failFile    = Join-Path $ExportDir "DashboardFailedAccountsDetails_$timestamp.csv"
    $pendingDiscFile = Join-Path $ExportDir "DashboardPendingDiscoveredAccountsDetails_$timestamp.csv"
    $summaryFile = Join-Path $ExportDir "DashboardCounts_$timestamp.csv"
    $discFile    = Join-Path $ExportDir "DashboardDiscoveredAccountsDetails_$timestamp.csv"

    # Load shared feature config
    $CfgDomains = if ($FeatureConfig.Domains) { $FeatureConfig.Domains } else { @() }
    $InbuiltSafes = if ($FeatureConfig.InbuiltSafes) { $FeatureConfig.InbuiltSafes } else { @() }
    $MigSafeKeywords = if ($FeatureConfig.MigratedSafeKeywords) { $FeatureConfig.MigratedSafeKeywords } else { @() }
    $PersSafeRegex = $FeatureConfig.PersonalSafePattern
    $MigPlatKeywords = if ($FeatureConfig.MigratedPlatformKeywords) { $FeatureConfig.MigratedPlatformKeywords } else { @() }
    $ExcludeFailedPlatforms = if ($FeatureConfig.FailedAccountExcludePlatforms) { $FeatureConfig.FailedAccountExcludePlatforms } else { @() }
    $AutoOnboardedSafes = if ($FeatureConfig.AutoOnboardedSafes) { $FeatureConfig.AutoOnboardedSafes } else { @() }
    $AutoOnboardedPattern = if ($FeatureConfig.AutoOnboardedPattern) { $FeatureConfig.AutoOnboardedPattern } else { "" }
    $PendingDiscNames = if ($FeatureConfig.PendingDiscoveredFilterNames) { $FeatureConfig.PendingDiscoveredFilterNames } else { @() }

    # ------------------------
    # Step 1: Fetch Raw Accounts
    # ------------------------
    $RawAccounts = @()
    if (Test-Path $rawAccsCache) {
        $RawAccounts = Import-Csv $rawAccsCache
    }
    else {
        Write-Log -Message "Fetching raw accounts from API. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true

        while ($hasMore) {
            $accUri = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset"
            $accResp = Invoke-CyberArkApi -Uri $accUri
            $batch = if ($accResp.value) { $accResp.value } else { @() }
            
            if ($batch.Count -gt 0) {
                # Add batch to RawAccounts
                foreach ($acc in $batch) {
                    $RawAccounts += [PSCustomObject]@{
                        name                       = $acc.name
                        address                    = $acc.address
                        userName                   = $acc.userName
                        platformId                 = $acc.platformId
                        safeName                   = $acc.safeName
                        secretType                 = $acc.secretType
                        automaticManagementEnabled = $acc.secretManagement.automaticManagementEnabled
                        manualManagementReason     = $acc.secretManagement.manualManagementReason
                        creationTime               = $acc.creationTime
                    }
                }
                $offset += $limit
                if ($batch.Count -lt $limit) { $hasMore = $false }
                Write-Log -Message "Fetched $($RawAccounts.Count) raw accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
            }
            else { $hasMore = $false }
        }
        $RawAccounts | Export-Csv -Path $rawAccsCache -NoTypeInformation
    }

    # ------------------------
    # Step 1.1: Fetch Pending Discovered Accounts
    # ------------------------
    $RawPendingDiscovered = @()
    if (Test-Path $rawPendingDiscCache) {
        $RawPendingDiscovered = Import-Csv $rawPendingDiscCache
    }
    else {
        Write-Log -Message "Fetching raw pending discovered accounts from API..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true

        while ($hasMore) {
            $pAccUri = "$BaseUrl/PasswordVault/API/DiscoveredAccounts/?limit=$limit&offset=$offset"
            $pAccResp = Invoke-CyberArkApi -Uri $pAccUri
            $batch = if ($pAccResp.value) { $pAccResp.value } else { @() }
            
            if ($batch.Count -gt 0) {
                # Add batch to RawPendingDiscovered
                foreach ($acc in $batch) {
                    $RawPendingDiscovered += [PSCustomObject]@{
                        Id                      = $acc.id
                        Name                    = $acc.name
                        UserName                = $acc.userName
                        Address                 = $acc.address
                        PlatformType            = $acc.platformType
                        OSFamily                = $acc.osFamily
                        DiscoveryDate           = if ($acc.discoveryDate) { $acc.discoveryDate } else { $acc.lastLogonDateTime }
                    }
                }
                $offset += $limit
                if ($batch.Count -lt $limit) { $hasMore = $false }
                Write-Log -Message "Fetched $($RawPendingDiscovered.Count) pending discovered accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
            }
            else { $hasMore = $false }
        }
        $RawPendingDiscovered | Export-Csv -Path $rawPendingDiscCache -NoTypeInformation
    }

    # Processor 1.1: Pending Discovered Filtered
    Write-Log -Message "Processing Pending Discovered accounts filtering..." -ScriptName $ScriptName -LogPath $LogPath
    $PendingDiscoveredExport = @()
    
    foreach ($acc in $RawPendingDiscovered) {
        $isMatch = $false
        
        # Match by name/regex pattern if defined
        if ($AutoOnboardedPattern -and $acc.Name -match $AutoOnboardedPattern) {
            $isMatch = $true
        }
        
        # Match by config filter names if not already matched
        if (-not $isMatch -and $PendingDiscNames.Count -gt 0) {
            foreach ($n in $PendingDiscNames) {
                if ($acc.UserName -match [regex]::Escape($n)) { 
                    $isMatch = $true
                    break 
                }
            }
        }
        
        if ($isMatch) {
            # Date formatting for DiscoveryDate
            $discTimeEpoch = $acc.DiscoveryDate
            $discDateStr = "Unknown"
            if ($discTimeEpoch -match "^\d+$") {
                try {
                    $longVal = [long]$discTimeEpoch
                    if ($longVal -gt 1e11) { $discDateStr = [datetimeoffset]::FromUnixTimeMilliseconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
                    else { $discDateStr = [datetimeoffset]::FromUnixTimeSeconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
                }
                catch { $discDateStr = "Invalid Date ($discTimeEpoch)" }
            }
            elseif ($null -ne $discTimeEpoch) { $discDateStr = $discTimeEpoch }

            $PendingDiscoveredExport += [PSCustomObject]@{
                Id                      = $acc.Id
                Name                    = $acc.Name
                UserName                = $acc.UserName
                Address                 = $acc.Address
                PlatformType            = $acc.PlatformType
                OSFamily                = $acc.OSFamily
                DiscoveryDate           = $discDateStr
            }
        }
    }
    $PendingDiscoveredFilteredCount = $PendingDiscoveredExport.Count
    $PendingDiscoveredExport | Export-Csv -Path $pendingDiscFile -NoTypeInformation
    Write-Log -Message "Pending Discovered: Total: $($RawPendingDiscovered.Count), Filtered: $PendingDiscoveredFilteredCount" -ScriptName $ScriptName -LogPath $LogPath

    # Processor 1: Inventory Analytics
    Write-Log -Message "Processing Inventory analytics from raw accounts..." -ScriptName $ScriptName -LogPath $LogPath
    $InventoryExport = @()
    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0
    $AutoOnboardedCount = 0
    $DiscoveredAccountsExport = @()

    foreach ($acc in $RawAccounts) {
        # Domain vs Non-Domain
        $isDomain = $false
        if ($acc.address) {
            $firstPart = ($acc.address -split '\.')[0]
            foreach ($d in $CfgDomains) {
                if ($firstPart -ieq $d) { $isDomain = $true; break }
            }
        }
        if ($isDomain) { $DomainAccountsCount++ } else { $NonDomainAccountsCount++ }

        # CPM Disabled
        $cpmDisabled = $false
        # Normalize CSV string booleans - Fix: Use more robust check to avoid PowerShell casting bug
        $autoMgmt = $acc.automaticManagementEnabled
        if ($null -ne $autoMgmt -and ($autoMgmt -match 'False' -or $autoMgmt -eq $false)) { $cpmDisabled = $true }
        if ($null -ne $acc.manualManagementReason -and $acc.manualManagementReason -ne "") { $cpmDisabled = $true }
        if ($cpmDisabled) { $CpmDisabledCount++ }

        # Usage tracking
        if ($acc.platformId) { $InUsePlatformIds[$acc.platformId] = $true }
        if ($acc.safeName) {
            $isIB = $false
            foreach ($ib in $InbuiltSafes) { if ($acc.safeName -ieq $ib) { $isIB = $true; break } }
            if (-not $isIB) { $InUseSafeNames[$acc.safeName] = $true }
        }

        # Date formatting for Account Creation Date
        $accCreationTimeEpoch = $acc.creationTime
        $accCreationDate = "Unknown"
        if ($accCreationTimeEpoch -match "^\d+$") {
            try {
                $longVal = [long]$accCreationTimeEpoch
                if ($longVal -gt 1e11) { $accCreationDate = [datetimeoffset]::FromUnixTimeMilliseconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
                else { $accCreationDate = [datetimeoffset]::FromUnixTimeSeconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
            }
            catch { $accCreationDate = "Invalid Date ($accCreationTimeEpoch)" }
        }
        elseif ($null -ne $accCreationTimeEpoch) { $accCreationDate = $accCreationTimeEpoch }

        # Auto-onboarded account discovery logic
        if ($AutoOnboardedPattern -and $acc.safeName) {
            $isAutoSafe = $false
            foreach ($as in $AutoOnboardedSafes) {
                if ($acc.safeName -ieq $as) { $isAutoSafe = $true; break }
            }
            if ($isAutoSafe -and $acc.name -match $AutoOnboardedPattern) {
                $AutoOnboardedCount++
                $DiscoveredAccountsExport += [PSCustomObject]@{
                    AccountName = $acc.name
                    Address     = $acc.address
                    UserName    = $acc.userName
                    PlatformID  = $acc.platformId
                    SafeName    = $acc.safeName
                    CreationDate = $accCreationDate
                }
            }
        }

        $InventoryExport += [PSCustomObject]@{
            AccountName  = $acc.name
            Address      = $acc.address
            UserName     = $acc.userName
            PlatformID   = $acc.platformId
            SafeName     = $acc.safeName
            SecretType   = $acc.secretType
            CreationDate = $accCreationDate
            CPMDisabled  = $cpmDisabled
            IsDomain     = $isDomain
        }
    }
    $InventoryExport | Export-Csv -Path $invFile -NoTypeInformation
    $DiscoveredAccountsExport | Export-Csv -Path $discFile -NoTypeInformation
    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count
    $InUseSafesCount = $InUseSafeNames.Keys.Count
    Write-Log -Message "Inventory Analytics: Total: $($InventoryExport.Count), Domain: $DomainAccountsCount, CPM Disabled: $CpmDisabledCount, Discovered: $AutoOnboardedCount" -ScriptName $ScriptName -LogPath $LogPath
    
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

    # Filter tracked accounts failures from config
    $TrackedFailures = @{}
    if ($featureConfig.TrackedFailedAccounts) {
        foreach ($name in $featureConfig.TrackedFailedAccounts) {
            $count = ($filteredFailedAccounts | Where-Object { $_.userName -ieq $name }).Count
            $TrackedFailures[$name] = $count
            Write-Log -Message "Tracked account failure check: $name ($count)" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # Export filtered failed accounts
    $filteredFailedAccounts | Export-Csv -Path $failFile -NoTypeInformation

    # ------------------------
    # Step 3: Fetch Raw Platforms
    # ------------------------
    $RawPlatforms = @()
    if (Test-Path $rawPlatsCache) {
        $RawPlatforms = Import-Csv $rawPlatsCache
    }
    else {
        Write-Log -Message "Fetching raw platforms from API..." -ScriptName $ScriptName -LogPath $LogPath
        $platsUri = "$BaseUrl/PasswordVault/API/Platforms?active=true&limit=500"
        $platsResponse = Invoke-CyberArkApi -Uri $platsUri
        $batch = if ($platsResponse.Platforms) { $platsResponse.Platforms } else { @() }
        
        foreach ($p in $batch) {
            $RawPlatforms += [PSCustomObject]@{
                id                         = if ($p.general.id) { $p.general.id } else { $p.platformId }
                name                       = if ($p.general.name) { $p.general.name } else { $p.name }
                active                     = if ($null -ne $p.general.active) { $p.general.active } else { $p.active }
                systemType                 = $p.general.systemType
                platformBaseID             = $p.platformBaseID
                linkedAccounts             = $p.linkedAccounts | ConvertTo-Json -Compress -Depth 5
                performPeriodicChange      = $p.automaticPasswordManagement.performPeriodicChange
                privilegedAccessWorkflows   = $p.privilegedAccessWorkflows | ConvertTo-Json -Compress -Depth 5
            }
        }
        $RawPlatforms | Export-Csv -Path $rawPlatsCache -NoTypeInformation
    }

    # Processor 3: Platforms Analytics
    Write-Log -Message "Processing Platforms analytics..." -ScriptName $ScriptName -LogPath $LogPath
    $PlatsExport = @()
    $ActivePlatformsCount = 0
    $MigratedPlatformsCount = 0

    foreach ($p in $RawPlatforms) {
        $platId = $p.id
        $platName = $p.name
        $isActive = ($p.active -eq $true -or $p.active -eq "True")
        
        if ($isActive) { $ActivePlatformsCount++ }

        $isMigPlat = $false
        if ($MigPlatKeywords) {
            foreach ($kw in $MigPlatKeywords) {
                if ($platName -match "^$kw") { $isMigPlat = $true; break }
            }
        }
        if ($isMigPlat) { $MigratedPlatformsCount++ }

        $PlatsExport += [PSCustomObject]@{
            PlatformID             = $platId
            Name                   = $platName
            Active                 = $isActive
            SystemType             = $p.systemType
            PlatformBaseID         = $p.platformBaseID
            LinkedAccounts         = $p.linkedAccounts
            PerformPeriodicChange  = $p.performPeriodicChange
            PrivilegedWorkflows    = $p.privilegedAccessWorkflows
            IsMigrated             = $isMigPlat
            IsInUse                = ($null -ne $platId -and $InUsePlatformIds.ContainsKey($platId))
        }
    }
    $PlatsExport | Export-Csv -Path $platsFile -NoTypeInformation

    # ------------------------
    # Step 4: Fetch Raw Safes
    # ------------------------
    $RawSafes = @()
    if (Test-Path $rawSafesCache) {
        $RawSafes = Import-Csv $rawSafesCache
    }
    else {
        Write-Log -Message "Fetching raw safes from API..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 500
        $offset = 0
        $hasMore = $true
        $seenSafes = @{}

        while ($hasMore) {
            $safesUri = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
            $safesResponse = Invoke-CyberArkApi -Uri $safesUri
            $batch = if ($safesResponse.value) { $safesResponse.value } elseif ($safesResponse.Safes) { $safesResponse.Safes } else { @() }

            if ($batch.Count -gt 0) {
                foreach ($s in $batch) {
                    $sName = if ($s.safeName) { $s.safeName } else { $s.SafeName }
                    if (-not $sName -or $seenSafes.ContainsKey($sName)) { continue }
                    $seenSafes[$sName] = $true
                    
                    $RawSafes += [PSCustomObject]@{
                        safeName     = $sName
                        description  = $s.description
                        creationTime = if ($s.creationTime) { $s.creationTime } else { $s.CreationDate }
                        creator      = if ($s.creator.name) { $s.creator.name } elseif ($s.creator) { $s.creator } else { "Unknown" }
                    }
                }
                if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
            }
            else { $hasMore = $false }
        }
        $RawSafes | Export-Csv -Path $rawSafesCache -NoTypeInformation
    }

    # Processor 4: Safes Analytics
    Write-Log -Message "Processing Safes analytics..." -ScriptName $ScriptName -LogPath $LogPath
    $SafesExport = @()
    $TotalSafes = 0
    $MigratedSharedSafes = 0
    $PersonalSafesCount = 0
    $SharedSafesCount = 0

    foreach ($s in $RawSafes) {
        $safeName = $s.safeName
        # Exclude inbuilt safes from ALL reporting
        $isInbuilt = $false
        foreach ($ib in $InbuiltSafes) { if ($safeName -ieq $ib) { $isInbuilt = $true; break } }
        if ($isInbuilt) { continue }

        $TotalSafes++

        $isPersonal = $false
        if ($PersSafeRegex -and $safeName -match $PersSafeRegex) {
            $isPersonal = $true
            $PersonalSafesCount++
        }
        else {
            $SharedSafesCount++
            $isMig = $false
            if ($MigSafeKeywords) {
                foreach ($kw in $MigSafeKeywords) { if ($safeName -match "^$kw") { $isMig = $true; break } }
            }
            if ($isMig) { $MigratedSharedSafes++ }
        }

        # Date formatting
        $creationTimeEpoch = $s.creationTime
        $creationTimeStr = "Unknown"
        if ($creationTimeEpoch -match "^\d+$") {
            try {
                $longVal = [long]$creationTimeEpoch
                if ($longVal -gt 1e11) { $creationTimeStr = [datetimeoffset]::FromUnixTimeMilliseconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
                else { $creationTimeStr = [datetimeoffset]::FromUnixTimeSeconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
            }
            catch { $creationTimeStr = "Invalid Date ($creationTimeEpoch)" }
        }
        elseif ($null -ne $creationTimeEpoch) { $creationTimeStr = $creationTimeEpoch }

        $SafesExport += [PSCustomObject]@{
            SafeName     = $safeName
            Description  = $s.description
            CreationTime = $creationTimeStr
            Creator      = $s.creator
            IsPersonal   = $isPersonal
            IsMigrated   = ($isPersonal -eq $false -and $isMig -eq $true)
        }
    }
    $SafesExport | Export-Csv -Path $safesFile -NoTypeInformation
    $NotInUseSafesCount = $TotalSafes - $InUseSafesCount



    # Processor 5: Export Final Details (Already done in Processor blocks)
    # ------------------------
    # Step 5: Final Reports Summary
    # ------------------------

    $SummaryRows = @()
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "TotalAccounts"; Value = $InventoryExport.Count }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "DomainAccounts"; Value = $DomainAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "NonDomainAccounts"; Value = $NonDomainAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "FailedAccounts"; Value = $FailedAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "CPMDisabledAccounts"; Value = $CpmDisabledCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "DiscoveredAccounts"; Value = $AutoOnboardedCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "PendingDiscoveredAccounts"; Value = $PendingDiscoveredFilteredCount }
    
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "TotalSafes"; Value = $TotalSafes }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "PersonalSafes"; Value = $PersonalSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "SharedSafes"; Value = $SharedSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "MigratedSharedSafes"; Value = $MigratedSharedSafes }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "InUseSafes"; Value = $InUseSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "NotInUseSafes"; Value = $NotInUseSafesCount }

    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "ActivePlatforms"; Value = $ActivePlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "MigratedPlatforms"; Value = $MigratedPlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "InUsePlatforms"; Value = $InUsePlatformsCount }

    # Add Tracked Account Failures
    if ($TrackedFailures.Count -gt 0) {
        foreach ($accName in $TrackedFailures.Keys) {
            $SummaryRows += [PSCustomObject]@{ Category = "Tracked Account Metrics"; Metric = $accName; Value = $TrackedFailures[$accName] }
        }
    }
    
    $SummaryRows += [PSCustomObject]@{ Category = "Metadata"; Metric = "Timestamp"; Value = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

    $SummaryRows | Export-Csv -Path $summaryFile -NoTypeInformation

    Write-Log -Message "Reports generated successfully:" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Inventory: $invFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Safes: $safesFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Platforms: $platsFile" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "  - Summary: $summaryFile" -ScriptName $ScriptName -LogPath $LogPath

    # ------------------------
    # Step 6: Automated Email Notification
    # ------------------------
    if (-not $ManualLogin) {
        if ($config.Email -and $config.Email.SmtpServer -and $config.Email.To) {
            Write-Log -Message "ManualLogin not detected. Preparing automated email notification..." -ScriptName $ScriptName -LogPath $LogPath
            
            try {
                $zipFile = Join-Path $ExportDir "DashboardReports_$timestamp.zip"
                $filesToZip = @($invFile, $safesFile, $platsFile, $failFile, $summaryFile, $discFile, $pendingDiscFile)
                
                Write-Log -Message "Zipping reports to $zipFile..." -ScriptName $ScriptName -LogPath $LogPath
                Compress-Archive -Path $filesToZip -DestinationPath $zipFile -Force
                
                $Subject = "CyberArk Dashboard Report - $TodayStr"

                # Load external HTML template
                $templatePath = Join-Path $RootPath "Templates\DashboardReport.html"
                if (-not (Test-Path $templatePath)) {
                    Write-Log -Message "Email template not found at $templatePath. Falling back to plain text summary." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
                    $Body = "Dashboard Report completed successfully.`n"
                    foreach ($row in $SummaryRows) { $Body += "$($row.Metric): $($row.Value)`n" }
                }
                else {
                    $templateContent = Get-Content $templatePath -Raw
                    
                    $accRows = ""
                    $safeRows = ""
                    $platRows = ""
                    $trackedRows = ""
                    
                    foreach ($row in $SummaryRows) {
                        if ($row.Metric -eq "Timestamp") { continue }
                        $valClass = "metric"
                        if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { $valClass = "priority-failed" }
                        # Also mark non-zero tracked failures as priority
                        if ($row.Category -eq "Tracked Account Metrics" -and $row.Value -gt 0) { $valClass = "priority-failed" }
                        
                        $html = "<tr><td>$($row.Metric)</td><td class='$valClass'>$($row.Value)</td></tr>"
                        
                        if ($row.Category -eq "Account Metrics") { $accRows += $html }
                        elseif ($row.Category -eq "Safe Metrics") { $safeRows += $html }
                        elseif ($row.Category -eq "Platform Metrics") { $platRows += $html }
                        elseif ($row.Category -eq "Tracked Account Metrics") { $trackedRows += $html }
                    }

                    $Body = $templateContent.Replace("{{AccountTable}}", $accRows)
                    $Body = $Body.Replace("{{SafeTable}}", $safeRows)
                    $Body = $Body.Replace("{{PlatformTable}}", $platRows)
                    $Body = $Body.Replace("{{TrackedTable}}", $trackedRows)
                    $Body = $Body.Replace("{{Timestamp}}", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
                }

                $SmtpServer = $config.Email.SmtpServer
                $From = $config.Email.From
                $To = $config.Email.To -join ","

                Write-Log -Message "Sending email to $To via $SmtpServer..." -ScriptName $ScriptName -LogPath $LogPath
                Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml -Attachments @($zipFile)
                Write-Log -Message "Email sent successfully." -ScriptName $ScriptName -LogPath $LogPath
            }
            catch {
                Write-Log -Message "Failed to send email notification: $_" -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        else {
            Write-Log -Message "Email configuration missing or incomplete in config.json. Skipping notification." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    else {
        Write-Log -Message "ManualLogin detected. Skipping automated email notification." -ScriptName $ScriptName -LogPath $LogPath
    }
}
catch {
    Write-Log -Message "Dashboard Report failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
}
