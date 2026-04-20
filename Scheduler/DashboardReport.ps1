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
    $pendingDiscFile = Join-Path $ExportDir "DashboardDiscoveryPendingDetails_$timestamp.csv"
    $summaryFile = Join-Path $ExportDir "DashboardCounts_$timestamp.csv"
    $discFile    = Join-Path $ExportDir "DashboardDiscoveryOnboardedDetails_$timestamp.csv"

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
    # Helper: Get Previous Day Counts
    # ------------------------
    function Get-PreviousDayCounts {
        param($BaseOutputDir, $TodayStr)
        
        $prevDirs = Get-ChildItem -Path $BaseOutputDir -Directory | Where-Object { $_.Name -lt $TodayStr } | Sort-Object Name -Descending
        if (-not $prevDirs) { return $null }
        
        # Get the first match (most recent previous day)
        $prevDir = $prevDirs[0].FullName
        $prevSummaryFile = Get-ChildItem -Path $prevDir -Filter "DashboardCounts_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        
        if (-not $prevSummaryFile) { return $null }
        
        $counts = @{}
        $csv = Import-Csv $prevSummaryFile.FullName
        foreach ($row in $csv) {
            $counts[$row.Metric] = $row.Value
        }
        return $counts
    }

    # ------------------------
    # Helper: Export Colored HTML-as-XLS
    # ------------------------
    function Export-FormattedXls {
        param(
            [Parameter(Mandatory=$true)]
            [PSCustomObject[]]$Data,
            [Parameter(Mandatory=$true)]
            [string]$Path,
            [string]$Title = "Report"
        )
        
        $html = "<html><head><meta charset='UTF-8'><style>
            table { border-collapse: collapse; font-family: Calibri, sans-serif; }
            th { background-color: #34495e; color: white; padding: 10px; border: 1px solid #2c3e50; }
            td { padding: 8px; border: 1px solid #bdc3c7; }
            .fixed { background-color: #d4edda; color: #155724; font-weight: bold; }
            .new { background-color: #f8d7da; color: #721c24; font-weight: bold; }
            .existing { background-color: #fff3cd; color: #856404; }
            .header { background-color: #3498db; color: white; font-size: 1.2em; text-align: center; }
        </style></head><body>"
        
        $html += "<table><thead>"
        $html += "<tr><th colspan='7' class='header'>$Title</th></tr>"
        $html += "<tr>"
        $props = $Data[0].PSObject.Properties.Name
        foreach ($p in $props) { $html += "<th>$p</th>" }
        $html += "</tr></thead><tbody>"

        foreach ($row in $Data) {
            $class = switch ($row.Status) {
                "Fixed"    { "fixed" }
                "New"      { "new" }
                "Existing" { "existing" }
                Default    { "" }
            }
            $html += "<tr>"
            foreach ($p in $props) {
                $val = $row.$p
                if ($p -eq "Status") { $html += "<td class='$class'>$val</td>" }
                else { $html += "<td>$val</td>" }
            }
            $html += "</tr>"
        }
        $html += "</tbody></table></body></html>"
        $html | Set-Content -Path $Path -Force
    }

    # ------------------------
    # Helper: Get Previous Day File
    # ------------------------
    function Get-PreviousDayFile {
        param($BaseOutputDir, $TodayStr, $FilePattern)
        
        $prevDirs = Get-ChildItem -Path $BaseOutputDir -Directory | Where-Object { $_.Name -lt $TodayStr } | Sort-Object Name -Descending
        if (-not $prevDirs) { return $null }
        
        foreach ($dir in $prevDirs) {
            $prevFile = Get-ChildItem -Path $dir.FullName -Filter $FilePattern | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($prevFile) { return $prevFile.FullName }
        }
        return $null
    }

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

    # Processor 1.1: Discovery Pending Filtered
    Write-Log -Message "Processing Discovery_Accounts_Pending filter logic..." -ScriptName $ScriptName -LogPath $LogPath
    $DiscoveryPendingExport = @()
    
    foreach ($acc in $RawPendingDiscovered) {
        $isMatch = $false
        
        # Match ONLY by config filter names (case-insensitive) - UUID pattern is NOT for pending list
        if ($PendingDiscNames.Count -gt 0) {
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

            $DiscoveryPendingExport += [PSCustomObject]@{
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
    $DiscoveryPendingCount = $DiscoveryPendingExport.Count
    $DiscoveryPendingExport | Export-Csv -Path $pendingDiscFile -NoTypeInformation
    Write-Log -Message "Discovery_Accounts_Pending: Total: $($RawPendingDiscovered.Count), Filtered: $DiscoveryPendingCount" -ScriptName $ScriptName -LogPath $LogPath

    # Processor 1: Inventory Analytics
    Write-Log -Message "Processing Inventory analytics from raw accounts..." -ScriptName $ScriptName -LogPath $LogPath
    $InventoryExport = @()
    $InUsePlatformIds = @{}
    $InUseSafeNames = @{}
    $CpmDisabledCount = 0
    $DomainAccountsCount = 0
    $NonDomainAccountsCount = 0
    $DiscoveryOnboardedCount = 0
    $DiscoveryOnboardedExport = @()

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

        # Discovery_Accounts_Onboarded Identification (already in inventory)
        $safeName = $acc.safeName
        $accName = $acc.name
        if ($AutoOnboardedSafes -and ($safeName -in $AutoOnboardedSafes)) {
            if ($AutoOnboardedPattern -and $accName -match $AutoOnboardedPattern) {
                $DiscoveryOnboardedCount++
                $DiscoveryOnboardedExport += [PSCustomObject]@{
                    AccountName     = $accName
                    Address         = $acc.address
                    UserName        = $acc.userName
                    PlatformID      = $acc.platformId
                    SafeName        = $safeName
                    CreationDate    = $accCreationDate
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
    $DiscoveryOnboardedExport | Export-Csv -Path $discFile -NoTypeInformation
    $InUsePlatformsCount = $InUsePlatformIds.Keys.Count
    $InUseSafesCount = $InUseSafeNames.Keys.Count
    Write-Log -Message "Inventory Analytics: Total: $($InventoryExport.Count), Domain: $DomainAccountsCount, CPM Disabled: $CpmDisabledCount, Discovery_Accounts_Onboarded: $DiscoveryOnboardedCount" -ScriptName $ScriptName -LogPath $LogPath
    
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
    # Comparison Logic for Failed Accounts
    # ------------------------
    Write-Log -Message "Performing failure comparison with previous report..." -ScriptName $ScriptName -LogPath $LogPath
    $comparisonFile = Join-Path $ExportDir "DashboardFailedComparison_$timestamp.csv"
    $prevFailFile = Get-PreviousDayFile -BaseOutputDir $BaseOutputDir -TodayStr $TodayStr -FilePattern "DashboardFailedAccountsDetails_*.csv"
    
    $ComparisonExport = @()
    $FixedCount = 0
    $NewCount = 0
    $ExistingCount = 0

    if ($prevFailFile) {
        Write-Log -Message "Found previous failure report: $prevFailFile" -ScriptName $ScriptName -LogPath $LogPath
        $prevFailures = Import-Csv $prevFailFile
        
        $currentIds = $filteredFailedAccounts | ForEach-Object { $_.id }
        $prevIds = $prevFailures | ForEach-Object { $_.id }

        # 1. Fixed (Present in prev, not in current)
        foreach ($prev in $prevFailures) {
            if ($prev.id -notin $currentIds) {
                $FixedCount++
                $ComparisonExport += [PSCustomObject]@{
                    Status     = "Fixed"
                    AccountID  = $prev.id
                    AccountName = $prev.name
                    Address    = $prev.address
                    UserName   = $prev.userName
                    PlatformID = $prev.platformId
                    SafeName   = $prev.safeName
                }
            }
        }

        # 2. Existing & New
        foreach ($curr in $filteredFailedAccounts) {
            $status = "New"
            if ($curr.id -in $prevIds) {
                $status = "Existing"
                $ExistingCount++
            } else {
                $NewCount++
            }
            
            $ComparisonExport += [PSCustomObject]@{
                Status     = $status
                AccountID  = $curr.id
                AccountName = $curr.name
                Address    = $curr.address
                UserName   = $curr.userName
                PlatformID = $curr.platformId
                SafeName   = $curr.safeName
            }
        }
    } else {
        Write-Log -Message "No previous failure report found. Marking all as New." -ScriptName $ScriptName -LogPath $LogPath
        foreach ($curr in $filteredFailedAccounts) {
            $NewCount++
            $ComparisonExport += [PSCustomObject]@{
                Status     = "New"
                AccountID  = $curr.id
                AccountName = $curr.name
                Address    = $curr.address
                UserName   = $curr.userName
                PlatformID = $curr.platformId
                SafeName   = $curr.safeName
            }
        }
    }
    $failCompXls = Join-Path $ExportDir "DashboardFailedComparison_$timestamp.xls"
    Export-FormattedXls -Data $ComparisonExport -Path $failCompXls -Title "Failure Comparison Report ($TodayStr)"
    
    $ComparisonExport | Export-Csv -Path $comparisonFile -NoTypeInformation
    Write-Log -Message "Failure Comparison: Fixed: $FixedCount, New: $NewCount, Existing: $ExistingCount" -ScriptName $ScriptName -LogPath $LogPath

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
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Discovery_Accounts_Onboarded"; Value = $DiscoveryOnboardedCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Discovery_Accounts_Pending"; Value = $DiscoveryPendingCount }
    
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "TotalSafes"; Value = $TotalSafes }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "PersonalSafes"; Value = $PersonalSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "SharedSafes"; Value = $SharedSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "MigratedSharedSafes"; Value = $MigratedSharedSafes }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "InUseSafes"; Value = $InUseSafesCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Safe Metrics"; Metric = "NotInUseSafes"; Value = $NotInUseSafesCount }

    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "ActivePlatforms"; Value = $ActivePlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "MigratedPlatforms"; Value = $MigratedPlatformsCount }
    $SummaryRows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "InUsePlatforms"; Value = $InUsePlatformsCount }

    $SummaryRows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "Fixed_Resolved"; Value = "-$FixedCount" }
    $SummaryRows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "New_Added"; Value = "+$NewCount" }
    $SummaryRows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "Existing_Pending"; Value = $ExistingCount }

    # Add Tracked Account Failures
    if ($TrackedFailures.Count -gt 0) {
        foreach ($accName in $TrackedFailures.Keys) {
            $SummaryRows += [PSCustomObject]@{ Category = "Tracked Account Metrics"; Metric = $accName; Value = $TrackedFailures[$accName] }
        }
    }
    
    $SummaryRows += [PSCustomObject]@{ Category = "Metadata"; Metric = "Timestamp"; Value = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

    $SummaryRows | Export-Csv -Path $summaryFile -NoTypeInformation

    # ------------------------
    # Step 5.1: SharePoint Automation (Excel Update)
    # ------------------------
    $SummaryRows | Export-Csv -Path $summaryFile -NoTypeInformation

    # ------------------------
    # Step 6: Automated Email Notification
    # ------------------------
    $sendEmail = -not $ManualLogin
    if ($ManualLogin) {
        Write-Log -Message "ManualLogin detected. Prompting for email notification..." -ScriptName $ScriptName -LogPath $LogPath
        $choice = Read-Host "Do you want to send the dashboard report via email? (Y/N)"
        if ($choice -ieq "Y" -or $choice -ieq "Yes") {
            $sendEmail = $true
        }
    }

    if ($sendEmail) {
        if ($config.Email -and $config.Email.SmtpServer -and $config.Email.To) {
            Write-Log -Message "Preparing email notification..." -ScriptName $ScriptName -LogPath $LogPath
            
            try {
                $zipFile = Join-Path $ExportDir "DashboardReports_$timestamp.zip"
                $filesToZip = @($invFile, $safesFile, $platsFile, $failFile, $comparisonFile, $failCompXls, $summaryFile, $discFile, $pendingDiscFile)
                
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
                    $compRows = ""
                    
                    $prevCounts = Get-PreviousDayCounts -BaseOutputDir $BaseOutputDir -TodayStr $TodayStr

                    foreach ($row in $SummaryRows) {
                        if ($row.Metric -eq "Timestamp") { continue }
                        
                        $todayVal = [int]$row.Value
                        $prevValStr = if ($prevCounts -and $prevCounts.ContainsKey($row.Metric)) { $prevCounts[$row.Metric] } else { "N/A" }
                        $prevVal = if ($prevValStr -ne "N/A") { [int]$prevValStr } else { $null }
                        
                        $changeText = "---"
                        $changeClass = ""
                        
                        if ($null -ne $prevVal) {
                            $diff = $todayVal - $prevVal
                            if ($diff -gt 0) {
                                $changeText = "+$diff"
                                $changeClass = "trend-up"
                                if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { $changeClass = "trend-bad" }
                            }
                            elseif ($diff -lt 0) {
                                $changeText = "$diff"
                                $changeClass = "trend-down"
                                if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { $changeClass = "trend-good" }
                            }
                            else {
                                $changeText = "0"
                            }
                        }

                        $valClass = "metric"
                        if ($row.Metric -like "*Failed*" -or $row.Metric -like "*Pending*") { $valClass = "priority-failed" }
                        if ($row.Category -eq "Tracked Account Metrics" -and $row.Value -gt 0) { $valClass = "priority-failed" }
                        
                        $html = "<tr>
                            <td>$($row.Metric)</td>
                            <td class='metric'>$prevValStr</td>
                            <td class='$valClass'>$todayVal</td>
                            <td class='$changeClass'>$changeText</td>
                        </tr>"
                        
                        if ($row.Category -eq "Account Metrics") { $accRows += $html }
                        elseif ($row.Category -eq "Safe Metrics") { $safeRows += $html }
                        elseif ($row.Category -eq "Platform Metrics") { $platRows += $html }
                        elseif ($row.Category -eq "Tracked Account Metrics") { $trackedRows += $html }
                        elseif ($row.Category -eq "Failure Comparison") { $compRows += $html }
                    }

                    $Body = $templateContent.Replace("{{AccountTable}}", $accRows)
                    $Body = $Body.Replace("{{SafeTable}}", $safeRows)
                    $Body = $Body.Replace("{{PlatformTable}}", $platRows)
                    $Body = $Body.Replace("{{TrackedTable}}", $trackedRows)
                    $Body = $Body.Replace("{{ComparisonTable}}", $compRows)
                    $Body = $Body.Replace("{{Timestamp}}", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
                }

                $SmtpServer = $config.Email.SmtpServer
                $From = $config.Email.From
                $To = $config.Email.To -join ","

                Write-Log -Message "Sending email to $To via $SmtpServer..." -ScriptName $ScriptName -LogPath $LogPath
                # Attach both the ZIP and the simplified XLS report separately
                $attachments = @($zipFile, $failCompXls)
                Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To -Subject $Subject -Body $Body -BodyAsHtml -Attachments $attachments
                Write-Log -Message "Email sent successfully (Reports zipped + Comparison XLS attached separately)." -ScriptName $ScriptName -LogPath $LogPath
            }
            catch {
                Write-Log -Message "Failed to send email notification: $_" -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        else {
            Write-Log -Message "Email configuration missing or incomplete in config.json. Skipping notification." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
}
catch {
    Write-Log -Message "Dashboard Report failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed" -ScriptName $ScriptName -LogPath $LogPath
}
