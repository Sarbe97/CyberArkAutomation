# =============================================================================
# DR_Analytics.ps1
# Processes raw CyberArk data into counts and export collections.
# Exposes: Invoke-InventoryAnalytics, Invoke-FailedAccountsAnalytics,
#          Invoke-PlatformsAnalytics, Invoke-SafesAnalytics,
#          Invoke-FailureComparison
# Also contains internal helpers: ConvertFrom-EpochDate, Export-FormattedXls,
#          Get-PreviousDayFile, Get-PreviousDayCounts
# =============================================================================

# ---- Shared date helper ----
function ConvertFrom-EpochDate {
    param([string]$EpochValue)
    if ($EpochValue -match "^\d+$") {
        try {
            $longVal = [long]$EpochValue
            if ($longVal -gt 1e11) { return [datetimeoffset]::FromUnixTimeMilliseconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
            else                   { return [datetimeoffset]::FromUnixTimeSeconds($longVal).DateTime.ToString("yyyy-MM-dd HH:mm:ss") }
        }
        catch { return "Invalid Date ($EpochValue)" }
    }
    elseif ($null -ne $EpochValue -and $EpochValue -ne "") { return $EpochValue }
    return "Unknown"
}

# ---- Helper: Export color-coded HTML-as-XLS for failure comparison ----
function Export-FormattedXls {
    param(
        [Parameter(Mandatory=$true)][PSCustomObject[]]$Data,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Title = "Report"
    )

    $html  = "<html><head><meta charset='UTF-8'><style>
        table { border-collapse: collapse; font-family: Calibri, sans-serif; }
        th { background-color: #34495e; color: white; padding: 6px 10px; border: 1px solid #2c3e50; text-align: left; font-size: 11pt; }
        td { padding: 4px 8px; border: 1px solid #bdc3c7; font-size: 10.5pt; white-space: nowrap; }
        .fixed    { background-color: #e2f3e5; color: #155724; }
        .new      { background-color: #fce8e9; color: #721c24; }
        .existing { background-color: #fff9e6; color: #856404; }
    </style></head><body>"
    $html += "<table><thead><tr>"
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
        foreach ($p in $props) { $html += "<td class='$class'>$($row.$p)</td>" }
        $html += "</tr>"
    }
    $html += "</tbody></table></body></html>"
    $html | Set-Content -Path $Path -Force
}

# ---- Helper: Get previous day output file ----
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

# ---- Helper: Load previous day summary CSV as a metric hashtable ----
function Get-PreviousDayCounts {
    param($BaseOutputDir, $TodayStr)
    $prevDirs = Get-ChildItem -Path $BaseOutputDir -Directory | Where-Object { $_.Name -lt $TodayStr } | Sort-Object Name -Descending
    if (-not $prevDirs) { return $null }
    $prevSummaryFile = Get-ChildItem -Path $prevDirs[0].FullName -Filter "DashboardCounts_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $prevSummaryFile) { return $null }
    $counts = @{}
    foreach ($row in (Import-Csv $prevSummaryFile.FullName)) { $counts[$row.Metric] = $row.Value }
    return $counts
}

# =============================================================================

function Invoke-InventoryAnalytics {
    param(
        [array]$RawAccounts,
        [array]$CfgDomains,
        [array]$InbuiltSafes,
        [array]$AutoOnboardedSafes,
        [string]$AutoOnboardedPattern,
        [string]$InvFile,
        [string]$DiscFile,
        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Processing Inventory analytics from raw accounts..." -ScriptName $ScriptName -LogPath $LogPath

    $InventoryExport       = @()
    $DiscoveryOnboardedExp = @()
    $InUsePlatformIds      = @{}
    $InUseSafeNames        = @{}
    $CpmDisabledCount      = 0
    $DomainAccountsCount   = 0
    $NonDomainAccountsCount= 0
    $DiscoveryOnboardedCount = 0

    foreach ($acc in $RawAccounts) {
        # Domain vs Non-Domain
        $isDomain = $false
        if ($acc.address) {
            $firstPart = ($acc.address -split '\.')[0]
            foreach ($d in $CfgDomains) { if ($firstPart -ieq $d) { $isDomain = $true; break } }
        }
        if ($isDomain) { $DomainAccountsCount++ } else { $NonDomainAccountsCount++ }

        # CPM Disabled
        $cpmDisabled = $false
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

        $accCreationDate = ConvertFrom-EpochDate -EpochValue $acc.creationTime

        # Discovery Onboarded
        if ($AutoOnboardedSafes -and ($acc.safeName -in $AutoOnboardedSafes)) {
            if ($AutoOnboardedPattern -and $acc.name -match $AutoOnboardedPattern) {
                $DiscoveryOnboardedCount++
                $DiscoveryOnboardedExp += [PSCustomObject]@{
                    AccountName  = $acc.name
                    Address      = $acc.address
                    UserName     = $acc.userName
                    PlatformID   = $acc.platformId
                    SafeName     = $acc.safeName
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

    $InventoryExport       | Export-Csv -Path $InvFile  -NoTypeInformation
    $DiscoveryOnboardedExp | Export-Csv -Path $DiscFile -NoTypeInformation
    Write-Log -Message "Inventory Analytics: Total=$($InventoryExport.Count), Domain=$DomainAccountsCount, CPMDisabled=$CpmDisabledCount, DiscoveryOnboarded=$DiscoveryOnboardedCount" -ScriptName $ScriptName -LogPath $LogPath

    return @{
        InventoryExport          = $InventoryExport
        DiscoveryOnboardedExport = $DiscoveryOnboardedExp
        InUsePlatformIds         = $InUsePlatformIds
        InUseSafeNames           = $InUseSafeNames
        CpmDisabledCount         = $CpmDisabledCount
        DomainAccountsCount      = $DomainAccountsCount
        NonDomainAccountsCount   = $NonDomainAccountsCount
        DiscoveryOnboardedCount  = $DiscoveryOnboardedCount
    }
}

# =============================================================================

function Invoke-FailedAccountsAnalytics {
    param(
        [string]$BaseUrl,
        [array]$ExcludeFailedPlatforms,
        [array]$TrackedFailedAccounts,
        [string]$FailFile,
        [string]$ScriptName,
        [string]$LogPath
    )

    $failedAccUri   = "$BaseUrl/PasswordVault/API/Accounts?savedFilter=PolicyFailures&limit=1000"
    $failedAccResp  = Invoke-CyberArkApi -Uri $failedAccUri
    $failedAccounts = if ($failedAccResp.value) { $failedAccResp.value } else { @() }
    Write-Log -Message "Filtering $($failedAccounts.Count) failed accounts using ExcludePlatforms: $($ExcludeFailedPlatforms -join ', ')" -ScriptName $ScriptName -LogPath $LogPath

    $filteredFailed = $failedAccounts | Where-Object {
        $pltId = $_.platformId
        $isExcluded = $false
        foreach ($ep in $ExcludeFailedPlatforms) {
            if ($pltId -like "*$ep*") {
                Write-Log -Message "Excluding account $($_.userName) on platform $pltId (keyword: $ep)" -ScriptName $ScriptName -LogPath $LogPath
                $isExcluded = $true; break
            }
        }
        -not $isExcluded
    }

    $FailedAccountsCount = $filteredFailed.Count
    Write-Log -Message "Failed Accounts Count (filtered): $FailedAccountsCount" -ScriptName $ScriptName -LogPath $LogPath

    $TrackedFailures = @{}
    foreach ($name in $TrackedFailedAccounts) {
        $cnt = ($filteredFailed | Where-Object { $_.userName -ieq $name }).Count
        $TrackedFailures[$name] = $cnt
        Write-Log -Message "Tracked account failure check: $name ($cnt)" -ScriptName $ScriptName -LogPath $LogPath
    }

    $filteredFailed | Export-Csv -Path $FailFile -NoTypeInformation

    return @{
        FilteredFailedAccounts = $filteredFailed
        FailedAccountsCount    = $FailedAccountsCount
        TrackedFailures        = $TrackedFailures
    }
}

# =============================================================================

function Invoke-FailureComparison {
    param(
        [array]$FilteredFailedAccounts,
        [string]$BaseOutputDir,
        [string]$TodayStr,
        [string]$ComparisonFile,
        [string]$FailCompXls,
        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Performing failure comparison with previous report..." -ScriptName $ScriptName -LogPath $LogPath
    $prevFailFile   = Get-PreviousDayFile -BaseOutputDir $BaseOutputDir -TodayStr $TodayStr -FilePattern "DashboardFailedAccountsDetails_*.csv"
    $ComparisonExport = @()
    $FixedCount = 0; $NewCount = 0; $ExistingCount = 0

    if ($prevFailFile) {
        Write-Log -Message "Found previous failure report: $prevFailFile" -ScriptName $ScriptName -LogPath $LogPath
        $prevFailures = Import-Csv $prevFailFile
        $currentIds   = $FilteredFailedAccounts | ForEach-Object { $_.id }
        $prevIds      = $prevFailures | ForEach-Object { $_.id }

        foreach ($prev in $prevFailures) {
            if ($prev.id -notin $currentIds) {
                $FixedCount++
                $ComparisonExport += [PSCustomObject]@{ Status="Fixed"; AccountID=$prev.id; AccountName=$prev.name; Address=$prev.address; UserName=$prev.userName; PlatformID=$prev.platformId; SafeName=$prev.safeName }
            }
        }
        foreach ($curr in $FilteredFailedAccounts) {
            $status = if ($curr.id -in $prevIds) { $ExistingCount++; "Existing" } else { $NewCount++; "New" }
            $ComparisonExport += [PSCustomObject]@{ Status=$status; AccountID=$curr.id; AccountName=$curr.name; Address=$curr.address; UserName=$curr.userName; PlatformID=$curr.platformId; SafeName=$curr.safeName }
        }
    }
    else {
        Write-Log -Message "No previous failure report found. Marking all as New." -ScriptName $ScriptName -LogPath $LogPath
        foreach ($curr in $FilteredFailedAccounts) {
            $NewCount++
            $ComparisonExport += [PSCustomObject]@{ Status="New"; AccountID=$curr.id; AccountName=$curr.name; Address=$curr.address; UserName=$curr.userName; PlatformID=$curr.platformId; SafeName=$curr.safeName }
        }
    }

    Export-FormattedXls -Data $ComparisonExport -Path $FailCompXls -Title "Failure Comparison Report ($TodayStr)"
    $ComparisonExport | Export-Csv -Path $ComparisonFile -NoTypeInformation
    Write-Log -Message "Failure Comparison: Fixed=$FixedCount, New=$NewCount, Existing=$ExistingCount" -ScriptName $ScriptName -LogPath $LogPath

    return @{
        ComparisonExport = $ComparisonExport
        FixedCount       = $FixedCount
        NewCount         = $NewCount
        ExistingCount    = $ExistingCount
    }
}

# =============================================================================

function Invoke-PlatformsAnalytics {
    param(
        [array]$RawPlatforms,
        [array]$MigPlatKeywords,
        [hashtable]$InUsePlatformIds,
        [string]$PlatsFile,
        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Processing Platforms analytics..." -ScriptName $ScriptName -LogPath $LogPath
    $PlatsExport            = @()
    $ActivePlatformsCount   = 0
    $MigratedPlatformsCount = 0

    foreach ($p in $RawPlatforms) {
        $isActive = ($p.active -eq $true -or $p.active -eq "True")
        if ($isActive) { $ActivePlatformsCount++ }

        $isMigPlat = $false
        foreach ($kw in $MigPlatKeywords) { if ($p.name -match "^$kw") { $isMigPlat = $true; break } }
        if ($isMigPlat) { $MigratedPlatformsCount++ }

        $PlatsExport += [PSCustomObject]@{
            PlatformID            = $p.id
            Name                  = $p.name
            Active                = $isActive
            SystemType            = $p.systemType
            PlatformBaseID        = $p.platformBaseID
            LinkedAccounts        = $p.linkedAccounts
            PerformPeriodicChange = $p.performPeriodicChange
            PrivilegedWorkflows   = $p.privilegedAccessWorkflows
            IsMigrated            = $isMigPlat
            IsInUse               = ($null -ne $p.id -and $InUsePlatformIds.ContainsKey($p.id))
        }
    }

    $PlatsExport | Export-Csv -Path $PlatsFile -NoTypeInformation

    return @{
        PlatsExport             = $PlatsExport
        ActivePlatformsCount    = $ActivePlatformsCount
        MigratedPlatformsCount  = $MigratedPlatformsCount
    }
}

# =============================================================================

function Invoke-SafesAnalytics {
    param(
        [array]$RawSafes,
        [array]$InbuiltSafes,
        [array]$MigSafeKeywords,
        [string]$PersSafeRegex,
        [hashtable]$InUseSafeNames,
        [string]$SafesFile,
        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Processing Safes analytics..." -ScriptName $ScriptName -LogPath $LogPath
    $SafesExport        = @()
    $TotalSafes         = 0
    $MigratedSharedSafes= 0
    $PersonalSafesCount = 0
    $SharedSafesCount   = 0

    foreach ($s in $RawSafes) {
        $safeName  = $s.safeName
        $isInbuilt = $false
        foreach ($ib in $InbuiltSafes) { if ($safeName -ieq $ib) { $isInbuilt = $true; break } }
        if ($isInbuilt) { continue }

        $TotalSafes++
        $isPersonal = $false
        $isMig      = $false

        if ($PersSafeRegex -and $safeName -match $PersSafeRegex) {
            $isPersonal = $true
            $PersonalSafesCount++
        }
        else {
            $SharedSafesCount++
            foreach ($kw in $MigSafeKeywords) { if ($safeName -match "^$kw") { $isMig = $true; break } }
            if ($isMig) { $MigratedSharedSafes++ }
        }

        $SafesExport += [PSCustomObject]@{
            SafeName     = $safeName
            Description  = $s.description
            CreationTime = ConvertFrom-EpochDate -EpochValue $s.creationTime
            Creator      = $s.creator
            IsPersonal   = $isPersonal
            IsMigrated   = (-not $isPersonal -and $isMig)
        }
    }

    $SafesExport | Export-Csv -Path $SafesFile -NoTypeInformation
    $InUseSafesCount    = $InUseSafeNames.Keys.Count
    $NotInUseSafesCount = $TotalSafes - $InUseSafesCount

    return @{
        SafesExport          = $SafesExport
        TotalSafes           = $TotalSafes
        SharedSafesCount     = $SharedSafesCount
        PersonalSafesCount   = $PersonalSafesCount
        MigratedSharedSafes  = $MigratedSharedSafes
        InUseSafesCount      = $InUseSafesCount
        NotInUseSafesCount   = $NotInUseSafesCount
    }
}

# =============================================================================

function Invoke-DiscoveryPendingAnalytics {
    param(
        [array]$RawPendingDiscovered,
        [array]$PendingDiscNames,
        [string]$PendingDiscFile,
        [string]$ScriptName,
        [string]$LogPath
    )

    Write-Log -Message "Processing Discovery_Accounts_Pending filter logic..." -ScriptName $ScriptName -LogPath $LogPath
    $DiscoveryPendingExport = @()

    foreach ($acc in $RawPendingDiscovered) {
        $isMatch = $false
        if ($PendingDiscNames.Count -gt 0) {
            foreach ($n in $PendingDiscNames) {
                if ($acc.UserName -match [regex]::Escape($n)) { $isMatch = $true; break }
            }
        }

        if ($isMatch) {
            $DiscoveryPendingExport += [PSCustomObject]@{
                Id            = $acc.Id
                Name          = $acc.Name
                UserName      = $acc.UserName
                Address       = $acc.Address
                PlatformType  = $acc.PlatformType
                OSFamily      = $acc.OSFamily
                DiscoveryDate = ConvertFrom-EpochDate -EpochValue $acc.DiscoveryDate
            }
        }
    }

    $DiscoveryPendingExport | Export-Csv -Path $PendingDiscFile -NoTypeInformation
    Write-Log -Message "Discovery_Accounts_Pending: Total=$($RawPendingDiscovered.Count), Filtered=$($DiscoveryPendingExport.Count)" -ScriptName $ScriptName -LogPath $LogPath

    return @{
        DiscoveryPendingExport = $DiscoveryPendingExport
        DiscoveryPendingCount  = $DiscoveryPendingExport.Count
    }
}
