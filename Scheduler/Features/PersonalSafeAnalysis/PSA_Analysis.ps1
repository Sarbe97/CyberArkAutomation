param (
    [switch] $ManualLogin,
    [ValidateSet("Analysis", "")]
    [string] $Mode = ""
)

# ============================================================
# Script Identity
# ============================================================
$ScriptName    = "PSA_Analysis"
$FeatureRoot   = $PSScriptRoot
$SchedulerRoot = Split-Path -Parent (Split-Path -Parent $FeatureRoot)
$ConfigPath    = Join-Path $FeatureRoot "config.json"

# ============================================================
# Setup Paths — Logs & Output
# ============================================================
$TodayStr   = Get-Date -Format "yyyyMMdd"
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir     = Join-Path $FeatureRoot "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath    = Join-Path $LogDir "$ScriptName-$TodayStr.log"

$BaseOutputDir = Join-Path $FeatureRoot "Output"
$ExportDir     = Join-Path $BaseOutputDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

# ============================================================
# Load Shared Utils + Feature Modules
# ============================================================
. (Join-Path $SchedulerRoot "Utils.ps1")
. (Join-Path $FeatureRoot   "Modules\PSA_DataCollection.ps1")
. (Join-Path $FeatureRoot   "Modules\PSA_Notifications.ps1")

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

$config          = Get-Content $GlobalConfigPath -Raw | ConvertFrom-Json
$featureSettings = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).Features
$config | Add-Member -MemberType NoteProperty -Name "Features" -Value $featureSettings -Force

$BaseUrl       = $config.BaseUrl
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
$cfgSafe          = $featureConfig.PersonalSafe
$cfgPrimary       = $featureConfig.PrimaryAccount
$cfgDomains       = $featureConfig.Domains
$cfgExclusions    = $featureConfig.Exclusions
$cfgNotif         = $featureConfig.Notifications
$templatesPath    = Join-Path $FeatureRoot "Templates"

$cacheSafes = Join-Path $ExportDir "RawCache_PersonalSafes_$TodayStr.csv"
$cacheAccounts = Join-Path $ExportDir "RawCache_AllAccounts_$TodayStr.csv"
$cacheADUsers = Join-Path $ExportDir "RawCache_ADUsers_$TodayStr.csv"
$analysisFile = Join-Path $ExportDir "PSA_AnalysisReport_$Timestamp.csv"

# ============================================================
# Authenticate
# ============================================================
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -Username $config.Username -Password $config.Password `
    -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential `
    -ScriptName $ScriptName -LogPath $LogPath

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

    $safeIndex = 0
    foreach ($safe in $personalSafes) {
        $safeIndex++
        Write-Progress -Id 20 -Activity "Analyzing Personal Safes" -Status "[$safeIndex/$totalSafes] Analyzing safe '$($safe.SafeName)'..." -PercentComplete ([int](($safeIndex / $totalSafes) * 100))
        Write-Log -Message "[$safeIndex/$totalSafes] Analyzing safe '$($safe.SafeName)'..." -ScriptName $ScriptName -LogPath $LogPath
        
        $ownerUid = ""
        if ($safe.SafeName -match $cfgSafe.OwnerExtractionRegex) {
            $ownerUid = $Matches[1]
            [void]$extractedOwners.Add($ownerUid)
        }

        # Check members
        $members = Get-PSASafeMembers -BaseUrl $BaseUrl -SafeName $safe.SafeName -ScriptName $ScriptName -LogPath $LogPath
        $isMember = $false
        if ($ownerUid) {
            foreach ($m in $members) {
                if ($m.MemberName -eq $ownerUid) {
                    $isMember = $true
                    break
                }
            }
        }

        # Account count from local map
        $safeUpper = $safe.SafeName.ToUpper()
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
            } elseif ($ownerStatus -eq "Disabled") {
                $status = "Member_Disabled"
                $cntMember_Disabled++
            } else {
                $status = "Member_NotFound"
                $cntMember_NotFound++
            }
        } else {
            if ($ownerStatus -eq "Enabled") {
                $status = "NotMember_Enabled"
                $cntNotMember_Enabled++
            } elseif ($ownerStatus -eq "Disabled") {
                $status = "NotMember_Disabled"
                $cntNotMember_Disabled++
            } else {
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
    if ($analysisReport.Count -gt 0) {
        $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath
    } else {
        Write-Log -Message "No personal safes matched. Analysis report not generated." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 4 — SUMMARY EMAIL
    # ==========================================================
    Write-Log -Message "========== PHASE 4: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

    $modeTitle = "Analysis Run Complete"
    $modeBanner = "ANALYSIS COMPLETE - Read-only analysis finished."

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
        }

        Send-PSARunSummary `
            -Tokens              $summaryTokens `
            -AnalysisReportFile  $analysisFile `
            -GlobalEmailConfig   $config.Email `
            -AdminTo             $cfgNotif.AdminTo `
            -AdminCC             $cfgNotif.AdminCC `
            -TemplatesPath       $templatesPath `
            -ScriptName          $ScriptName `
            -LogPath             $LogPath `
            -FromOverride        $cfgNotif.AdminFrom

    # ==========================================================
    # PHASE 5: CLEANUP
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
catch {
    Write-Log -Message "PersonalSafeAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
