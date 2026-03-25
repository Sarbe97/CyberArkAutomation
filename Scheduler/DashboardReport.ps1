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
Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ------------------------
    # Setup Cache Paths
    # ------------------------
    $TodayStr = Get-Date -Format "yyyyMMdd"
    # ExportDir already created at script start (Output\yyyyMMdd)
    
    $rawAccsCache  = Join-Path $ExportDir "RawCache_Accounts_$TodayStr.csv"
    $rawPlatsCache = Join-Path $ExportDir "RawCache_Platforms_$TodayStr.csv"
    $rawSafesCache = Join-Path $ExportDir "RawCache_Safes_$TodayStr.csv"
    
    # Final Processed Report Filenames (Timestamped)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $invFile     = Join-Path $ExportDir "DashboardInventoryDetails_$timestamp.csv"
    $safesFile   = Join-Path $ExportDir "DashboardSafesDetails_$timestamp.csv"
    $platsFile   = Join-Path $ExportDir "DashboardPlatformsDetails_$timestamp.csv"
    $summaryFile = Join-Path $ExportDir "DashboardCounts_$timestamp.csv"

    # Load shared feature config
    $CfgDomains = if ($FeatureConfig.Domains) { $FeatureConfig.Domains } else { @() }
    $InbuiltSafes = if ($FeatureConfig.InbuiltSafes) { $FeatureConfig.InbuiltSafes } else { @() }
    $MigSafeKeywords = if ($FeatureConfig.MigratedSafeKeywords) { $FeatureConfig.MigratedSafeKeywords } else { @() }
    $PersSafeRegex = $FeatureConfig.PersonalSafePattern
    $MigPlatKeywords = if ($FeatureConfig.MigratedPlatformKeywords) { $FeatureConfig.MigratedPlatformKeywords } else { @() }
    $ExcludeFailedPlatforms = if ($FeatureConfig.FailedAccountExcludePlatforms) { $FeatureConfig.FailedAccountExcludePlatforms } else { @() }

    # ------------------------
    # Step 1: Fetch Raw Accounts
    # ------------------------
    $RawAccounts = @()
    if (Test-Path $rawAccsCache) {
        $RawAccounts = Import-Csv $rawAccsCache
    } else {
        Write-Log -Message "Fetching raw accounts from API. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
        $limit = 1000
        $offset = 0
        $hasMore = $true

        while ($hasMore) {
            $accUri = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset&Fields=name,address,userName,platformId,safeName,secretType,secretManagement"
            $accResp = Invoke-CyberArkApi -Uri $accUri
            $batch = if ($accResp.value) { $accResp.value } else { @() }
            
            if ($batch.Count -gt 0) {
                # Add batch to RawAccounts
                foreach ($acc in $batch) {
                    $RawAccounts += [PSCustomObject]@{
                        name       = $acc.name
                        address    = $acc.address
                        userName   = $acc.userName
                        platformId = $acc.platformId
                        safeName   = $acc.safeName
                        secretType = $acc.secretType
                        automaticManagementEnabled = $acc.secretManagement.automaticManagementEnabled
                        manualManagementReason     = $acc.secretManagement.manualManagementReason
                    }
                }
                $offset += $limit
                if ($batch.Count -lt $limit) { $hasMore = $false }
                Write-Log -Message "Fetched $($RawAccounts.Count) raw accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
            } else { $hasMore = $false }
        }
        $RawAccounts | Export-Csv -Path $rawAccsCache -NoTypeInformation
    }

    # Processor 1: Inventory Analytics
    Write-Log -Message "Processing Inventory analytics from raw accounts..." -ScriptName $ScriptName -LogPath $LogPath
    $InventoryExport = @()
    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0

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
        # Normalize CSV string booleans
        $autoMgmt = $acc.automaticManagementEnabled
        if ($null -ne $autoMgmt -and ($autoMgmt -eq $false -or $autoMgmt -eq "False")) { $cpmDisabled = $true }
        if ($null -ne $acc.manualManagementReason -and $acc.manualManagementReason -ne "") { $cpmDisabled = $true }
        if ($cpmDisabled) { $CpmDisabledCount++ }

        # Usage tracking
        if ($acc.platformId) { $InUsePlatformIds[$acc.platformId] = $true }
        if ($acc.safeName) {
            $isIB = $false
            foreach ($ib in $InbuiltSafes) { if ($acc.safeName -ieq $ib) { $isIB = $true; break } }
            if (-not $isIB) { $InUseSafeNames[$acc.safeName] = $true }
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
    $InventoryExport | Export-Csv -Path $invFile -NoTypeInformation
    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count
    $InUseSafesCount = $InUseSafeNames.Keys.Count
    Write-Log -Message "Inventory Analytics: Total: $($InventoryExport.Count), Domain: $DomainAccountsCount, CPM Disabled: $CpmDisabledCount" -ScriptName $ScriptName -LogPath $LogPath
    
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
    # Step 3: Fetch Raw Platforms
    # ------------------------
    $RawPlatforms = @()
    if (Test-Path $rawPlatsCache) {
        $RawPlatforms = Import-Csv $rawPlatsCache
    } else {
        Write-Log -Message "Fetching raw platforms from API..." -ScriptName $ScriptName -LogPath $LogPath
        $platsUri = "$BaseUrl/PasswordVault/API/Platforms?active=true&limit=500"
        $platsResponse = Invoke-CyberArkApi -Uri $platsUri
        $batch = if ($platsResponse.Platforms) { $platsResponse.Platforms } else { @() }
        
        foreach ($p in $batch) {
            $RawPlatforms += [PSCustomObject]@{
                id     = if ($p.general.id) { $p.general.id } else { $p.platformId }
                name   = if ($p.general.name) { $p.general.name } else { $p.name }
                active = if ($null -ne $p.general.active) { $p.general.active } else { $p.active }
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
            PlatformID   = $platId
            Name         = $platName
            Active       = $isActive
            IsMigrated   = $isMigPlat
            IsInUse      = ($null -ne $platId -and $InUsePlatformIds.ContainsKey($platId))
        }
    }
    $PlatsExport | Export-Csv -Path $platsFile -NoTypeInformation

    # ------------------------
    # Step 4: Fetch Raw Safes
    # ------------------------
    $RawSafes = @()
    if (Test-Path $rawSafesCache) {
        $RawSafes = Import-Csv $rawSafesCache
    } else {
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
            } else { $hasMore = $false }
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
        } else {
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
            } catch { $creationTimeStr = "Invalid Date ($creationTimeEpoch)" }
        } elseif ($null -ne $creationTimeEpoch) { $creationTimeStr = $creationTimeEpoch }

        $SafesExport += [PSCustomObject]@{
            SafeName      = $safeName
            Description   = $s.description
            CreationTime  = $creationTimeStr
            Creator       = $s.creator
            IsPersonal    = $isPersonal
            IsMigrated    = ($isPersonal -eq $false -and $isMig -eq $true)
        }
    }
    $SafesExport | Export-Csv -Path $safesFile -NoTypeInformation
    $NotInUseSafesCount = $TotalSafes - $InUseSafesCount



    # Processor 5: Export Final Details (Already done in Processor blocks)
    # ------------------------
    # Step 5: Final Reports Summary
    # ------------------------

    $SummaryRows = @()
    $SummaryRows += [PSCustomObject]@{ Metric = "TotalAccounts"; Value = $InventoryExport.Count }
    $SummaryRows += [PSCustomObject]@{ Metric = "DomainAccounts"; Value = $DomainAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "NonDomainAccounts"; Value = $NonDomainAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "FailedAccounts"; Value = $FailedAccountsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "CPMDisabledAccounts"; Value = $CpmDisabledCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "TotalSafes"; Value = $TotalSafes }
    $SummaryRows += [PSCustomObject]@{ Metric = "PersonalSafes"; Value = $PersonalSafesCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "SharedSafes"; Value = $SharedSafesCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "MigratedSharedSafes"; Value = $MigratedSharedSafes }
    $SummaryRows += [PSCustomObject]@{ Metric = "InUseSafes"; Value = $InUseSafesCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "NotInUseSafes"; Value = $NotInUseSafesCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "TotalPlatforms"; Value = $PlatsExport.Count }
    $SummaryRows += [PSCustomObject]@{ Metric = "ActivePlatforms"; Value = $ActivePlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "MigratedPlatforms"; Value = $MigratedPlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "InUsePlatforms"; Value = $InUsePlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Metric = "Timestamp"; Value = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

    $SummaryRows | Export-Csv -Path $summaryFile -NoTypeInformation

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
