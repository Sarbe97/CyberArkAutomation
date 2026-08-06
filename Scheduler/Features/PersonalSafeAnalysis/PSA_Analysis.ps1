param (
    [switch] $ManualLogin,
    [ValidateSet("Analysis", "")]
    [string] $Mode = ""
)

# ============================================================
# Script Identity
# ============================================================
$ScriptName = "PSA_Analysis"
$FeatureRoot = $PSScriptRoot
$SchedulerRoot = Split-Path -Parent (Split-Path -Parent $FeatureRoot)
$ConfigPath = Join-Path $FeatureRoot "config.json"

# ============================================================
# Setup Paths — Logs & Output
# ============================================================
$TodayStr = Get-Date -Format "yyyyMMdd"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir = Join-Path $FeatureRoot "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath = Join-Path $LogDir "$ScriptName-$TodayStr.log"

$BaseOutputDir = Join-Path $FeatureRoot "Output"
$ExportDir = Join-Path $BaseOutputDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

# --- Clear Cache if ForceRefresh ---
if ($FeatureConfig.ForceRefresh) {
    Write-Log -Message "ForceRefresh is enabled in config. Removing existing daily cache files..." -ScriptName $ScriptName -LogPath $LogPath
    Get-ChildItem -Path $ExportDir -Filter "*_$TodayStr.csv" | Where-Object { $_.Name -match "^(RawCache_|Filtered_|SmartIDs_)" } | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Load Shared Utils + Feature Modules
# ============================================================
. (Join-Path $SchedulerRoot "Utils.ps1")
. (Join-Path $SchedulerRoot "SharePointUtils.ps1")
. (Join-Path $FeatureRoot   "Modules\PSA_DataCollection.ps1")
. (Join-Path $FeatureRoot   "Modules\PSA_Notifications.ps1")
. (Join-Path $FeatureRoot   "Modules\PSA_SharePointReport.ps1")

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath
$overallStartTime = Get-Date

# ============================================================
# Load Config
# ============================================================
$GlobalConfigPath = Join-Path $SchedulerRoot "config.json"

if (-not (Test-Path $GlobalConfigPath)) {
    Write-Log -Message "Global config.json not found at: $GlobalConfigPath" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log -Message "Feature config.json not found at: $ConfigPath" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

$config = Get-Content $GlobalConfigPath -Raw | ConvertFrom-Json
$featureSettings = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).Features
$config | Add-Member -MemberType NoteProperty -Name "Features" -Value $featureSettings -Force

$BaseUrl = $config.BaseUrl
$featureConfig = $config.Features.PersonalSafeAnalysis

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $featureConfig -or -not $featureConfig.Enabled) {
    Write-Log -Message "PersonalSafeAnalysis is disabled in config. Exiting." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ============================================================
# Resolve Effective Mode
# ============================================================
$effectiveMode = if ($Mode) { $Mode } `
    elseif ($featureConfig.Mode) { $featureConfig.Mode } `
    else { "Analysis" }

Write-Log -Message "Effective execution mode: $effectiveMode" -ScriptName $ScriptName -LogPath $LogPath

# ============================================================
# Load Feature Settings
# ============================================================
$cfgSafe = $featureConfig.PersonalSafe
$cfgPrimary = $featureConfig.PrimaryAccount
$cfgDomains = $featureConfig.Domains
$cfgExclusions = $featureConfig.Exclusions
$cfgNotif = $featureConfig.Notifications
$templatesPath = Join-Path $FeatureRoot "Templates"

$cacheSafes = Join-Path $ExportDir "RawCache_PersonalSafes_$TodayStr.csv"
$cacheAccounts = Join-Path $ExportDir "RawCache_AllAccounts_$TodayStr.csv"
$cacheMembers = Join-Path $ExportDir "RawCache_SafeMembers_$TodayStr.csv"
$cacheADUsers = Join-Path $ExportDir "RawCache_ADUsers_$TodayStr.csv"
$analysisFile = Join-Path $ExportDir "PSA_AnalysisReport_$Timestamp.csv"
$blankSafesFile = Join-Path $ExportDir "PSA_BlankSafesReport_$Timestamp.csv"

# ============================================================
# Authenticate
# ============================================================
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -Username $config.Username -Password $config.Password `
    -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential `
    -ScriptName $ScriptName -LogPath $LogPath
$cyberArkDisconnected = $false

try {
    # ==========================================================
    # PHASE 1 & 2 — DATA COLLECTION AND ANALYSIS
    # ==========================================================
    Write-Log -Message "========== PHASE 1 & 2: DATA COLLECTION AND ANALYSIS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phaseStart = Get-Date

    # 1. Fetch Personal Safes
    $personalSafes = Get-PSAPersonalSafes `
        -BaseUrl            $BaseUrl `
        -NamingPatternRegex $cfgSafe.NamingPatternRegex `
        -Exclusions         $cfgExclusions `
        -CachePath          $cacheSafes `
        -ScriptName         $ScriptName `
        -LogPath            $LogPath

    $totalSafes = $personalSafes.Count

    # 1b. Fetch All Accounts and Group by Safe
    $allAccounts = Get-PSAAllAccounts -BaseUrl $BaseUrl -CachePath $cacheAccounts -ScriptName $ScriptName -LogPath $LogPath
    $accountCountMap = @{}
    foreach ($acct in $allAccounts) {
        $safeNameUpper = $acct.SafeName.ToUpper()
        if (-not $accountCountMap.ContainsKey($safeNameUpper)) {
            $accountCountMap[$safeNameUpper] = 0
        }
        $accountCountMap[$safeNameUpper]++
    }

    # 2. Extract Owners and check CyberArk Members/Counts
    $extractedOwners = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $safeDataMap = @{}

    $safeMembersMap = @{}
    $membersCacheList = [System.Collections.Generic.List[object]]::new()
    $isMembersCached = Test-Path $cacheMembers

    if ($isMembersCached) {
        Write-Log -Message "Loading safe members from cache: $cacheMembers" -ScriptName $ScriptName -LogPath $LogPath
        $cachedData = Import-Csv $cacheMembers
        if ($null -ne $cachedData) {
            foreach ($row in $cachedData) {
                $sName = $row.SafeName.ToUpper()
                if (-not $safeMembersMap.ContainsKey($sName)) {
                    $safeMembersMap[$sName] = [System.Collections.Generic.List[string]]::new()
                }
                $safeMembersMap[$sName].Add($row.MemberName)
            }
        }
    }

    $safeIndex = 0
    foreach ($safe in $personalSafes) {
        $safeIndex++
        if (-not $isMembersCached) {
            Write-Progress -Id 20 -Activity "Analyzing Personal Safes" -Status "[$safeIndex/$totalSafes] Querying members for '$($safe.SafeName)'..." -PercentComplete ([int](($safeIndex / $totalSafes) * 100))
            Write-Log -Message "[$safeIndex/$totalSafes] Analyzing safe '$($safe.SafeName)'..." -ScriptName $ScriptName -LogPath $LogPath
        }
        
        $ownerUid = ""
        if ($safe.SafeName -match $cfgSafe.OwnerExtractionRegex) {
            $ownerUid = $Matches[1]
            [void]$extractedOwners.Add($ownerUid)
        }

        # Check members
        $isMember = $false
        $safeUpper = $safe.SafeName.ToUpper()
        
        if ($isMembersCached) {
            if ($ownerUid -and $safeMembersMap.ContainsKey($safeUpper)) {
                foreach ($mName in $safeMembersMap[$safeUpper]) {
                    if ($mName -eq $ownerUid) {
                        $isMember = $true
                        break
                    }
                }
            }
        }
        else {
            # Live query
            $members = Get-PSASafeMembers -BaseUrl $BaseUrl -SafeName $safe.SafeName -ScriptName $ScriptName -LogPath $LogPath
            foreach ($m in $members) {
                $membersCacheList.Add([PSCustomObject]@{
                        SafeName   = $safe.SafeName
                        MemberName = $m.MemberName
                        MemberType = $m.MemberType
                    })
                if ($ownerUid -and $m.MemberName -eq $ownerUid) {
                    $isMember = $true
                }
            }
        }

        # Account count from local map
        $acctCount = if ($accountCountMap.ContainsKey($safeUpper)) { $accountCountMap[$safeUpper] } else { 0 }

        $safeDataMap[$safe.SafeName] = @{
            OwnerUid     = $ownerUid
            AccountCount = $acctCount
            IsMember     = $isMember
            Creator      = $safe.Creator
            CreationTime = $safe.CreationTime
            ManagingCPM  = $safe.ManagingCPM
        }
    }
    Write-Progress -Id 20 -Activity "Analyzing Personal Safes" -Completed

    if (-not $isMembersCached -and $membersCacheList.Count -gt 0) {
        $membersCacheList | Export-CsvNoBom -Path $cacheMembers
        Write-Log -Message "Exported all safe members to cache: $cacheMembers" -ScriptName $ScriptName -LogPath $LogPath
    }

    Write-Log -Message "CyberArk data collection complete. Disconnecting early to prevent token expiry during AD queries..." -ScriptName $ScriptName -LogPath $LogPath
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    $cyberArkDisconnected = $true

    # 3. Query AD for Primary Accounts
    $adUsers = Get-PSAADUsers `
        -Domains      $cfgDomains `
        -Pattern      $cfgPrimary.Pattern `
        -CachePath    $cacheADUsers `
        -ScriptName   $ScriptName `
        -LogPath      $LogPath `
        -GlobalCCPUrl $config.CCP.Url `
        -ManualLogin  $ManualLogin

    $adUserMap = @{}
    foreach ($user in $adUsers) {
        $adUserMap[$user.Username.ToUpper()] = $user
    }

    # 4. Build Report
    $analysisReport = [System.Collections.Generic.List[object]]::new()
    $cntMember_Enabled = 0
    $cntMember_Disabled = 0
    $cntMember_NotFound = 0
    $cntNotMember_Enabled = 0
    $cntNotMember_Disabled = 0
    $cntNotMember_NotFound = 0
    $totalAccounts = 0

    foreach ($safe in $personalSafes) {
        $data = $safeDataMap[$safe.SafeName]
        $totalAccounts += $data.AccountCount

        $ownerUid = $data.OwnerUid
        $isMember = $data.IsMember
        $ownerInAD = "No"
        $ownerStatus = "NotFound"
        $fullName = ""
        $email = ""

        if ($ownerUid) {
            $ownerUpper = $ownerUid.ToUpper()
            if ($adUserMap.ContainsKey($ownerUpper)) {
                $adUser = $adUserMap[$ownerUpper]
                $ownerInAD = "Yes"
                $ownerStatus = if ([string]$adUser.Enabled -eq 'True') { "Enabled" } else { "Disabled" }
                $fullName = "$($adUser.GivenName) $($adUser.Surname)".Trim()
                $email = $adUser.Mail
            }
        }

        $status = "Unknown"
        if ($isMember) {
            if ($ownerStatus -eq "Enabled") {
                $status = "Member_Enabled"
                $cntMember_Enabled++
            }
            elseif ($ownerStatus -eq "Disabled") {
                $status = "Member_Disabled"
                $cntMember_Disabled++
            }
            else {
                $status = "Member_NotFound"
                $cntMember_NotFound++
            }
        }
        else {
            if ($ownerStatus -eq "Enabled") {
                $status = "NotMember_Enabled"
                $cntNotMember_Enabled++
            }
            elseif ($ownerStatus -eq "Disabled") {
                $status = "NotMember_Disabled"
                $cntNotMember_Disabled++
            }
            else {
                $status = "NotMember_NotFound"
                $cntNotMember_NotFound++
            }
        }

        $analysisReport.Add([PSCustomObject]@{
                SafeName          = $safe.SafeName
                Creator           = $data.Creator
                CreationDate      = $data.CreationTime
                ManagingCPM       = $data.ManagingCPM
                OwnerUid          = $ownerUid
                OwnerIsSafeMember = if ($isMember) { "Yes" } else { "No" }
                OwnerInAD         = $ownerInAD
                OwnerADStatus     = $ownerStatus
                OwnerFullName     = $fullName
                OwnerEmail        = $email
                AccountCount      = $data.AccountCount
                Status            = $status
            })
    }

    $phaseDuration = (Get-Date) - $phaseStart
    Write-Log -Message "Discovery and Analysis completed in $([math]::Round($phaseDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

    # ==========================================================
    # PHASE 3 — EXPORT REPORTS
    # ==========================================================
    $blankSafesCount = 0
    if ($analysisReport.Count -gt 0) {
        $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath

        $blankSafes = $analysisReport | Where-Object { $_.AccountCount -eq 0 }
        # PHASE 2.5 — MEMBERSHIP & PERMISSION VALIDATION
        # ==========================================================
        Write-Log -Message "========== PHASE 2.5: PERMISSION VALIDATION ==========" -ScriptName $ScriptName -LogPath $LogPath
        $permissionReport = [System.Collections.Generic.List[object]]::new()
        $permReportFileCsv = Join-Path $ExportDir "PSA_PermissionAnalysisReport_$Timestamp.csv"
        $permReportFileHtml = Join-Path $ExportDir "PSA_PermissionAnalysisReport_$Timestamp.html"
    
        $ignoredMembersSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($cfgSafe.IgnoredMembers) {
            foreach ($ign in $cfgSafe.IgnoredMembers) {
                [void]$ignoredMembersSet.Add($ign)
            }
        }
    
        foreach ($safe in $personalSafes) {
            $data = $safeDataMap[$safe.SafeName]
            $ownerUid = $data.OwnerUid
            $safeUpper = $safe.SafeName.ToUpper()
        
            $actualMembers = if ($safeMembersMap.ContainsKey($safeUpper)) { @($safeMembersMap[$safeUpper]) } else { @() }
        
            $expectedMembersMap = @{}
            if ($cfgSafe.Members) {
                foreach ($cfgMember in $cfgSafe.Members) {
                    $expectedName = $cfgMember.Name -replace '\{PrimaryAccount\}', $ownerUid
                    if (-not [string]::IsNullOrWhiteSpace($expectedName)) {
                        $expectedMembersMap[$expectedName] = $cfgMember
                    }
                }
            }
        
            $foundExpectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        
            foreach ($actualMem in $actualMembers) {
                $mName = $actualMem.MemberName
            
                if ($expectedMembersMap.ContainsKey($mName)) {
                    [void]$foundExpectedSet.Add($mName)
                    $cfgMember = $expectedMembersMap[$mName]
                    $permSetKey = $cfgMember.PermissionSet
                
                    $expectedPermsList = if ($featureConfig.SafePermissionSets.$permSetKey) { $featureConfig.SafePermissionSets.$permSetKey } else { @() }
                    $expectedPerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($p in $expectedPermsList) { [void]$expectedPerms.Add($p) }
                
                    $actualPermsList = [System.Collections.Generic.List[string]]::new()
                    if ($actualMem.Permissions -and $actualMem.Permissions -ne "{}") {
                        try {
                            $pObj = $actualMem.Permissions | ConvertFrom-Json
                            foreach ($prop in $pObj.psobject.properties) {
                                if ($prop.Value -eq $true) {
                                    $actualPermsList.Add($prop.Name)
                                }
                            }
                        }
                        catch {}
                    }
                
                    $missing = [System.Collections.Generic.List[string]]::new()
                    foreach ($ep in $expectedPermsList) {
                        $found = $false
                        foreach ($ap in $actualPermsList) {
                            if ($ap -ieq $ep) { $found = $true; break }
                        }
                        if (-not $found) { $missing.Add($ep) }
                    }
                
                    $extra = [System.Collections.Generic.List[string]]::new()
                    foreach ($ap in $actualPermsList) {
                        if (-not $expectedPerms.Contains($ap)) {
                            $extra.Add($ap)
                        }
                    }
                
                    $status = if ($missing.Count -eq 0 -and $extra.Count -eq 0) { "Matched" } else { "Not Matched" }
                
                    $permissionReport.Add([PSCustomObject]@{
                            SafeName           = $safe.SafeName
                            MemberName         = $mName
                            Status             = $status
                            MemberState        = "Expected"
                            ExpectedSet        = $permSetKey
                            MissingPermissions = ($missing -join ", ")
                            ExtraPermissions   = ($extra -join ", ")
                        })
                
                }
                else {
                    if (-not $ignoredMembersSet.Contains($mName)) {
                        $permissionReport.Add([PSCustomObject]@{
                                SafeName           = $safe.SafeName
                                MemberName         = $mName
                                Status             = "Not Matched"
                                MemberState        = "Extra Unexpected"
                                ExpectedSet        = "None"
                                MissingPermissions = ""
                                ExtraPermissions   = "ALL"
                            })
                    }
                }
            }
        
            foreach ($eName in $expectedMembersMap.Keys) {
                if (-not $foundExpectedSet.Contains($eName)) {
                    $permissionReport.Add([PSCustomObject]@{
                            SafeName           = $safe.SafeName
                            MemberName         = $eName
                            Status             = "Not Matched"
                            MemberState        = "Absent"
                            ExpectedSet        = $expectedMembersMap[$eName].PermissionSet
                            MissingPermissions = "ALL"
                            ExtraPermissions   = ""
                        })
                }
            }
        }

        if ($permissionReport.Count -gt 0) {
            $permissionReport | Export-Csv -Path $permReportFileCsv -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Permission Analysis CSV report saved: $permReportFileCsv" -ScriptName $ScriptName -LogPath $LogPath
        
            $html = "<html><head><style>
        body { font-family: Arial, sans-serif; font-size: 14px; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .matched { color: green; font-weight: bold; }
        .not-matched { color: red; font-weight: bold; }
        .extra-mem { color: #d9534f; font-weight: bold; }
        .absent-mem { color: #d9534f; font-weight: bold; }
        .missing-perm { color: #d9534f; }
        .extra-perm { color: #f0ad4e; }
        </style></head><body><h2>Personal Safe Member & Permission Analysis</h2><table>"
        
            $html += "<tr><th>Safe Name</th><th>Member Name</th><th>Status</th><th>Member State</th><th>Expected Set</th><th>Missing Permissions</th><th>Extra Permissions</th></tr>"
        
            foreach ($row in $permissionReport) {
                $statusClass = if ($row.Status -eq "Matched") { "matched" } else { "not-matched" }
                $stateClass = if ($row.MemberState -eq "Extra Unexpected") { "extra-mem" } elseif ($row.MemberState -eq "Absent") { "absent-mem" } else { "" }
            
                $html += "<tr>"
                $html += "<td>$($row.SafeName)</td>"
                $html += "<td>$($row.MemberName)</td>"
                $html += "<td class='$statusClass'>$($row.Status)</td>"
                $html += "<td class='$stateClass'>$($row.MemberState)</td>"
                $html += "<td>$($row.ExpectedSet)</td>"
                $html += "<td class='missing-perm'>$($row.MissingPermissions)</td>"
                $html += "<td class='extra-perm'>$($row.ExtraPermissions)</td>"
                $html += "</tr>"
            }
            $html += "</table></body></html>"
        
            $html | Out-File -FilePath $permReportFileHtml -Encoding UTF8
            Write-Log -Message "Permission Analysis HTML report saved: $permReportFileHtml" -ScriptName $ScriptName -LogPath $LogPath
        }

        # ==========================================================
        # PHASE 3 — EXPORT REPORTS
        # ==========================================================
        $blankSafesCount = 0
        if ($analysisReport.Count -gt 0) {
            $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath

            $blankSafes = $analysisReport | Where-Object { $_.AccountCount -eq 0 }
            $blankSafesCount = if ($null -eq $blankSafes) { 0 } elseif ($blankSafes -is [array]) { $blankSafes.Count } else { 1 }
        
            if ($blankSafesCount -gt 0) {
                $blankSafes | Export-Csv -Path $blankSafesFile -NoTypeInformation -Encoding UTF8
                Write-Log -Message "Blank safes report saved: $blankSafesFile" -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        else {
            Write-Log -Message "No personal safes matched. Analysis report not generated." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }

        # ==========================================================
        # PHASE 4 — SUMMARY EMAIL
        # ==========================================================
        Write-Log -Message "========== PHASE 4: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        $modeTitle = "Analysis Run Complete"
        $modeBanner = "ANALYSIS COMPLETE - Read-only analysis finished."

        $attachedHtml = "<p style=`"margin:2px 0; font-size:12px; color:#555555;`">&#8250; PSA_AnalysisReport.csv</p>"
        if ($blankSafesCount -gt 0) {
            $attachedHtml += "`n<p style=`"margin:2px 0; font-size:12px; color:#555555;`">&#8250; PSA_BlankSafesReport.csv</p>"
        }
        if ($permissionReport.Count -gt 0) {
            $attachedHtml += "`n<p style=`"margin:2px 0; font-size:12px; color:#555555;`">&#8250; PSA_PermissionAnalysisReport_$Timestamp.csv</p>"
            $attachedHtml += "`n<p style=`"margin:2px 0; font-size:12px; color:#555555;`">&#8250; PSA_PermissionAnalysisReport_$Timestamp.html</p>"
        }

        $summaryTokens = @{
            EffectiveMode           = $effectiveMode
            ModeTitle               = $modeTitle
            ModeBanner              = $modeBanner
            TotalSafes              = $totalSafes
            TotalAccounts           = $totalAccounts
            CountMember_Total       = ($cntMember_Enabled + $cntMember_Disabled + $cntMember_NotFound)
            CountMember_Enabled     = $cntMember_Enabled
            CountMember_Disabled    = $cntMember_Disabled
            CountMember_NotFound    = $cntMember_NotFound
            CountNotMember_Total    = ($cntNotMember_Enabled + $cntNotMember_Disabled + $cntNotMember_NotFound)
            CountNotMember_Enabled  = $cntNotMember_Enabled
            CountNotMember_Disabled = $cntNotMember_Disabled
            CountNotMember_NotFound = $cntNotMember_NotFound
            GeneratedDate           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            AttachedReportsHtml     = $attachedHtml
        }

        $additionalAtt = @()
        if ($permissionReport.Count -gt 0) {
            $additionalAtt += $permReportFileCsv
            $additionalAtt += $permReportFileHtml
        }

        Send-PSARunSummary `
            -Tokens              $summaryTokens `
            -AnalysisReportFile  $analysisFile `
            -BlankSafesReportFile $blankSafesFile `
            -AdditionalAttachments $additionalAtt `
            # ==========================================================
            # PHASE 5: SHAREPOINT UPLOAD
        # ==========================================================
        $cfgSP = $featureConfig.SharePoint
        if ($null -ne $cfgSP -and $cfgSP.Enabled -and $null -ne $config.SharePoint) {
            Write-Log -Message "========== PHASE 5: SHAREPOINT UPLOAD ==========" -ScriptName $ScriptName -LogPath $LogPath
        
            $metricsHash = @{
                TotalSafes        = $totalSafes
                TotalAccounts     = $totalAccounts
                BlankSafesCount   = $blankSafesCount
                MemberEnabled     = $cntMember_Enabled
                MemberDisabled    = $cntMember_Disabled
                MemberNotFound    = $cntMember_NotFound
                NotMemberEnabled  = $cntNotMember_Enabled
                NotMemberDisabled = $cntNotMember_Disabled
                NotMemberNotFound = $cntNotMember_NotFound
            }

            Publish-PSASharePointReport `
                -GlobalConfig            $config `
                -SharePointFeatureConfig $cfgSP `
                -Metrics                 $metricsHash `
                -ExportDir               $ExportDir `
                -ScriptName              $ScriptName `
                -LogPath                 $LogPath
        }

        # ==========================================================
        # PHASE 6: CLEANUP
        # ==========================================================
        $cfgCleanup = $featureConfig.Cleanup
        if ($null -ne $cfgCleanup -and $cfgCleanup.Enabled -and $cfgCleanup.RetentionDays -gt 0) {
            Write-Log -Message "========== PHASE 5: CLEANUP ==========" -ScriptName $ScriptName -LogPath $LogPath
            $cutoffDate = (Get-Date).AddDays(-$cfgCleanup.RetentionDays)
            Write-Log -Message "Cleaning up logs and output older than $($cfgCleanup.RetentionDays) days ($cutoffDate)..." -ScriptName $ScriptName -LogPath $LogPath

            if (Test-Path $LogDir) {
                $oldLogs = Get-ChildItem -Path $LogDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
                foreach ($log in $oldLogs) {
                    Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
                }
                Write-Log -Message "Removed $($oldLogs.Count) old log files." -ScriptName $ScriptName -LogPath $LogPath
            }

            if (Test-Path $BaseOutputDir) {
                $oldOutputs = Get-ChildItem -Path $BaseOutputDir -Directory | Where-Object { $_.LastWriteTime -lt $cutoffDate }
                foreach ($dir in $oldOutputs) {
                    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-Log -Message "Removed $($oldOutputs.Count) old output directories." -ScriptName $ScriptName -LogPath $LogPath
            }
        }

    }
}
catch {
    Write-Log -Message "PersonalSafeAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    if (-not $cyberArkDisconnected) {
        Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    }
    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
