param (
    [switch] $ManualLogin,
    [ValidateSet("Discovery", "Analysis", "Onboarding", "Simulation", "")]
    [string] $Mode = ""
)

# ============================================================
# Script Identity
# ============================================================
$ScriptName    = "SecondaryAccountAnalysis"
$FeatureRoot   = $PSScriptRoot                                         # Scheduler/Features/SecondaryAccountAnalysis/
$SchedulerRoot = Split-Path -Parent (Split-Path -Parent $FeatureRoot)  # Scheduler/
$ConfigPath    = Join-Path $FeatureRoot "config.json"

# ============================================================
# Setup Paths — Logs & Output (follows DashboardReport convention)
# ============================================================
$TodayStr   = Get-Date -Format "yyyyMMdd"
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir     = Join-Path $SchedulerRoot "Logs\SecondaryAccountAnalysis"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath    = Join-Path $LogDir "$ScriptName-$TodayStr.log"

$BaseOutputDir = Join-Path $SchedulerRoot "Output"
$ExportDir     = Join-Path $BaseOutputDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

# ============================================================
# Load Shared Utils + Feature Modules
# ============================================================
. (Join-Path $SchedulerRoot "Utils.ps1")
. (Join-Path $FeatureRoot   "Modules\SAA_DataCollection.ps1")
. (Join-Path $FeatureRoot   "Modules\SAA_SafeOperations.ps1")
. (Join-Path $FeatureRoot   "Modules\SAA_Notifications.ps1")

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath
$overallStartTime = Get-Date

# ============================================================
# Load Config — global settings (BaseUrl, CCP, Email) from root;
# feature-specific settings from this feature's own config.json.
# (Same merge pattern used by DashboardReport and LDAPUserAnalysis)
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
$featureConfig = $config.Features.SecondaryAccountAnalysis

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $featureConfig -or -not $featureConfig.Enabled) {
    Write-Log -Message "SecondaryAccountAnalysis is disabled in config. Exiting." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ============================================================
# Resolve Effective Mode
# Runtime parameter overrides config value.
# Default (if neither is set) = Simulation for safety.
# ============================================================
$effectiveMode = if ($Mode) { $Mode } `
                 elseif ($featureConfig.Mode) { $featureConfig.Mode } `
                 else { "Simulation" }

$SimulationMode = ($effectiveMode -eq "Simulation")

Write-Log -Message "Effective execution mode: $effectiveMode" -ScriptName $ScriptName -LogPath $LogPath
if ($SimulationMode) {
    Write-Log -Message "[SIMULATION] No write operations will be performed. All planned actions will be recorded in PlannedActions.csv." `
        -ScriptName $ScriptName -LogPath $LogPath
}

# ============================================================
# Load Feature Settings
# ============================================================
$cfgPrimary        = $featureConfig.PrimaryAccount
$cfgSecondary      = $featureConfig.SecondaryAccount
$cfgDomains        = $featureConfig.Domains
$cfgExclusions     = if ($featureConfig.Exclusions) { $featureConfig.Exclusions } else { [PSCustomObject]@{ Domains=@(); UsernamePatterns=@() } }
$cfgSafe           = $featureConfig.PersonalSafe
$cfgPermSets       = @{}
foreach ($key in $featureConfig.SafePermissionSets.PSObject.Properties.Name) {
    if ($key -notlike "_*") { $cfgPermSets[$key] = $featureConfig.SafePermissionSets.$key }
}
$cfgNotif          = $featureConfig.Notifications
$requiredGroup     = $featureConfig.RequiredADGroup
$templatesPath     = Join-Path $FeatureRoot "Templates"

Write-Log -Message "Primary pattern: $($cfgPrimary.Pattern) | Domain: $($($cfgDomains | Where-Object IsPrimary).Name)" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Secondary prefixes: $($cfgSecondary.Prefixes -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Required CyberArk group: $requiredGroup" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Domains configured: $($cfgDomains.Count)" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Safe naming pattern: $($cfgSafe.NamingPattern)" -ScriptName $ScriptName -LogPath $LogPath

# ============================================================
# Cache file paths (daily, in ExportDir)
# ============================================================
$cacheUsers        = Join-Path $ExportDir "RawCache_CyberArkUsers_$TodayStr.csv"
$cacheAllSafes     = Join-Path $ExportDir "RawCache_AllSafes_$TodayStr.csv"
$cacheSafes        = Join-Path $ExportDir "RawCache_PersonalSafes_$TodayStr.csv"
$cacheAllAccounts  = Join-Path $ExportDir "RawCache_AllAccounts_$TodayStr.csv"
$cacheOnboarded    = Join-Path $ExportDir "RawCache_OnboardedAccounts_$TodayStr.csv"
$cacheGroupMembers = Join-Path $ExportDir "RawCache_GroupMembers_$TodayStr.csv"

# Output file paths (timestamped)
$analysisFile        = Join-Path $ExportDir "SAA_AnalysisReport_$Timestamp.csv"
$plannedFile         = Join-Path $ExportDir "SAA_PlannedActions_$Timestamp.csv"
$onboardingFile      = Join-Path $ExportDir "SAA_OnboardingResults_$Timestamp.csv"
$skippedAccountsFile = Join-Path $ExportDir "SAA_SkippedAccounts_$Timestamp.csv"
$missingGroupFile    = Join-Path $ExportDir "SAA_MissingGroupAccess_$Timestamp.csv"

# ============================================================
# Authenticate — CCP or manual (same pattern as all features)
# ============================================================
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -ManualLogin:$ManualLogin `
    -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential `
    -ScriptName $ScriptName -LogPath $LogPath

try {

    $skipPhases1and2 = $false
    if ($effectiveMode -eq "Onboarding" -and (Test-Path $analysisFile)) {
        Write-Log -Message "Onboarding mode active and AnalysisReport ($analysisFile) exists. Skipping Phase 1 and Phase 2 to use the manually editable report." -ScriptName $ScriptName -LogPath $LogPath
        $skipPhases1and2 = $true
    }

    if (-not $skipPhases1and2) {
        # ==========================================================
        # PHASE 1 — DISCOVERY (all modes)
        # ==========================================================
        Write-Log -Message "========== PHASE 1: DATA COLLECTION & DOMAIN SCAN ==========" -ScriptName $ScriptName -LogPath $LogPath
        $phase1Start = Get-Date

        # 1a. Primary AD users (NA domain, U-prefix, + mail attribute)
        $primaryADUsers = Get-SAAPrimaryADUsers `
            -Domains          $cfgDomains `
            -PrimaryPattern   $cfgPrimary.Pattern `
            -EmpNbrCapture    $cfgPrimary.EmployeeNumberCapture `
            -CacheDir         $ExportDir `
            -TodayStr         $TodayStr `
            -ScriptName       $ScriptName `
            -LogPath          $LogPath `
            -GlobalCCPUrl     $config.CCP.Url `
            -ManualLogin      $ManualLogin

        Write-Log -Message "Primary AD users collected: $($primaryADUsers.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # 1b. Secondary AD accounts (all configured domains, secondary prefixes)
        $secondaryADAccounts = Get-SAASecondaryADAccounts `
            -Domains        $cfgDomains `
            -Prefixes       $cfgSecondary.Prefixes `
            -Pattern        $cfgSecondary.Pattern `
            -EmpNbrCapture  $cfgSecondary.EmployeeNumberCapture `
            -Exclusions     $cfgExclusions `
            -CacheDir       $ExportDir `
            -TodayStr       $TodayStr `
            -ScriptName       $ScriptName `
            -LogPath          $LogPath `
            -GlobalCCPUrl     $config.CCP.Url `
            -ManualLogin      $ManualLogin

        Write-Log -Message "Secondary AD accounts collected: $($secondaryADAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # 1c. CyberArk LDAP users (for access verification)
        $cyberArkUsers = Get-SAACyberArkUsers `
            -BaseUrl    $BaseUrl `
            -CachePath  $cacheUsers `
            -ScriptName $ScriptName `
            -LogPath    $LogPath

        Write-Log -Message "CyberArk LDAP users collected: $($cyberArkUsers.Count)" -ScriptName $ScriptName -LogPath $LogPath

        $epvUserSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($u in $cyberArkUsers) {
            if ($u.Username) { [void]$epvUserSet.Add($u.Username) }
        }

        # 1d. Existing personal safes (matching naming pattern)
        $personalSafes = Get-SAAPersonalSafes `
            -BaseUrl            $BaseUrl `
            -NamingPatternRegex $cfgSafe.NamingPatternRegex `
            -CachePath          $cacheSafes `
            -RawCachePath       $cacheAllSafes `
            -ScriptName         $ScriptName `
            -LogPath            $LogPath

        Write-Log -Message "Personal safes in CyberArk: $($personalSafes.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # 1e. Accounts already onboarded in personal safes
        $onboardedAccounts = Get-SAAOnboardedAccounts `
            -BaseUrl            $BaseUrl `
            -NamingPatternRegex $cfgSafe.NamingPatternRegex `
            -CachePath          $cacheOnboarded `
            -RawCachePath       $cacheAllAccounts `
            -ScriptName         $ScriptName `
            -LogPath            $LogPath

        Write-Log -Message "Onboarded accounts in personal safes: $($onboardedAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # 1f. Active Directory group members (required group for onboarding eligibility)
        $groupMemberSet = Get-SAAGroupMemberSet `
            -Domains      $cfgDomains `
            -GroupName    $requiredGroup `
            -CachePath    $cacheGroupMembers `
            -ScriptName   $ScriptName `
            -LogPath      $LogPath `
            -GlobalCCPUrl $config.CCP.Url `
            -ManualLogin  $ManualLogin

        Write-Log -Message "Group '$requiredGroup' members collected: $($groupMemberSet.Count)" -ScriptName $ScriptName -LogPath $LogPath

        $phase1Duration = (Get-Date) - $phase1Start
        Write-Log -Message "Phase 1 (Discovery) completed in $([math]::Round($phase1Duration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

        if ($effectiveMode -eq "Discovery") {
            Write-Log -Message "Mode=Discovery. Raw data collected and cached. Exiting after Phase 1." -ScriptName $ScriptName -LogPath $LogPath
            Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
            Write-Log -Message "Execution completed (Discovery mode)" -ScriptName $ScriptName -LogPath $LogPath
            exit 0
        }

        # ==========================================================
        # PHASE 2 — ANALYSIS
        # ==========================================================
        Write-Log -Message "========== PHASE 2: ANALYSIS & REPORTING ==========" -ScriptName $ScriptName -LogPath $LogPath
        $phase2Start = Get-Date

        $primaryUserMap = @{}
        $primaryInfoMap = @{}
        foreach ($p in $primaryADUsers) {
            if ($p.EmployeeNbr) {
                $primaryUserMap[$p.EmployeeNbr] = $p.SamAccountName
                $primaryInfoMap[$p.EmployeeNbr] = $p
            }
        }
        Write-Log -Message "Primary user map built: $($primaryUserMap.Count) unique employee numbers" -ScriptName $ScriptName -LogPath $LogPath

        $safeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($s in $personalSafes) { [void]$safeSet.Add($s.SafeName) }

        $onboardedMap = @{}
        foreach ($acc in $onboardedAccounts) {
            if ($acc.Username -and $acc.Address) {
                $key = "$($acc.Username.ToUpper())|$($acc.Address.ToUpper())"
                $onboardedMap[$key] = $acc.SafeName
            }
        }

        $analysisReport        = [System.Collections.Generic.List[object]]::new()
        $plannedActions        = [System.Collections.Generic.List[object]]::new()
        $skippedAccountsList   = [System.Collections.Generic.List[object]]::new()
        $missingGroupList      = [System.Collections.Generic.List[object]]::new()
        $seq = 0

        $countManaged         = 0
        $countNeedsAll        = 0
        $countNeedsOnboarding = 0
        $countMissingGroup    = 0
        $countPrimaryDisabled = 0
        $countSecondaryDisabled = 0
        $countMissingPrimary  = 0

        foreach ($secondary in $secondaryADAccounts) {
            $emp = $secondary.EmployeeNbr
            $primaryUsername = $primaryUserMap[$emp]
            $primaryInfo = $primaryInfoMap[$emp]
            $primaryEmail = if ($primaryInfo) { $primaryInfo.Mail } else { "" }
            
            $hasPrimary = $null -ne $primaryInfo
            $primaryEnabled = $hasPrimary -and ([string]$primaryInfo.Enabled -eq 'True')
            $secondaryEnabled = [string]$secondary.Enabled -eq 'True'
            $primaryInGroup = $hasPrimary -and $groupMemberSet.Contains($primaryUsername)

            $expectedSafe = if ($hasPrimary) { Resolve-SAAToken -Template $cfgSafe.NamingPattern -Tokens @{ "PrimaryAccount" = $primaryUsername; "EmployeeNumber" = $emp } } else { "" }
            $safeExists = $expectedSafe -and $safeSet.Contains($expectedSafe)
            
            $onboardKeyShort = "$($secondary.Username.ToUpper())|$($secondary.Domain.ToUpper())"
            $onboardKeyFQDN  = "$($secondary.Username.ToUpper())|$($secondary.DomainFQDN.ToUpper())"
            $isOnboarded = $onboardedMap.ContainsKey($onboardKeyShort) -or $onboardedMap.ContainsKey($onboardKeyFQDN)
            
            $status = switch ($true) {
                { -not $hasPrimary        } { "MissingPrimary";       break }
                { -not $primaryEnabled    } { "PrimaryDisabled";      break }
                { -not $secondaryEnabled  } { "SecondaryDisabled";    break }
                { $isOnboarded            } { "Managed";              break }
                { -not $primaryInGroup    } { "MissingGroupAccess";   break }
                { $safeExists             } { "NeedsOnboarding";      break }
                default                     { "NeedsAll" }
            }

            switch ($status) {
                "Managed"              { $countManaged++ }
                "NeedsAll"             { $countNeedsAll++ }
                "NeedsOnboarding"      { $countNeedsOnboarding++ }
                "MissingGroupAccess"   { $countMissingGroup++ }
                "PrimaryDisabled"      { $countPrimaryDisabled++ }
                "SecondaryDisabled"    { $countSecondaryDisabled++ }
                "MissingPrimary"       { $countMissingPrimary++ }
            }

            $reportRow = [PSCustomObject]@{
                EmployeeNumber      = $emp
                PrimaryAccount      = $primaryUsername
                PrimaryEmail        = $primaryEmail
                SecondaryAccount    = $secondary.Username
                Domain              = $secondary.DomainFQDN
                PlatformId          = $secondary.PlatformId
                Status              = $status
                ExpectedSafe        = $expectedSafe
                SafeExists          = $safeExists
                Onboarded           = $isOnboarded
            }
            $analysisReport.Add($reportRow)

            if ($status -in @("MissingPrimary", "PrimaryDisabled", "SecondaryDisabled")) { $skippedAccountsList.Add($reportRow) }
            if ($status -eq "MissingGroupAccess") { $missingGroupList.Add($reportRow) }
        }

        Write-Log -Message "Analysis complete. Managed=$countManaged, NeedsAll=$countNeedsAll, NeedsOnboarding=$countNeedsOnboarding, MissingGroup=$countMissingGroup, PrimaryDisabled=$countPrimaryDisabled, MissingPrimary=$countMissingPrimary" -ScriptName $ScriptName -LogPath $LogPath

        $phase2Duration = (Get-Date) - $phase2Start
        Write-Log -Message "Phase 2 (Analysis) completed in $([math]::Round($phase2Duration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    }

        # Export reports
        $analysisReport | Export-CsvNoBom -Path $analysisFile
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath

        $skippedAccountsList | Export-CsvNoBom -Path $skippedAccountsFile
        Write-Log -Message "Skipped accounts report saved: $skippedAccountsFile" -ScriptName $ScriptName -LogPath $LogPath

        $missingGroupList | Export-CsvNoBom -Path $missingGroupFile
        Write-Log -Message "Missing group access report saved: $missingGroupFile" -ScriptName $ScriptName -LogPath $LogPath

        # Export planned actions (Simulation and Onboarding modes)
        if ($plannedActions.Count -gt 0 -and $effectiveMode -in @("Simulation", "Onboarding")) {
            $plannedActions | Export-Csv -Path $plannedFile -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Planned actions saved: $plannedFile ($($plannedActions.Count) actions)" -ScriptName $ScriptName -LogPath $LogPath
        }

        if ($effectiveMode -eq "Analysis") {
            Write-Log -Message "Mode=Analysis. Reports exported. No onboarding or notifications." -ScriptName $ScriptName -LogPath $LogPath
            Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
            Write-Log -Message "Execution completed (Analysis mode)" -ScriptName $ScriptName -LogPath $LogPath
            exit 0
        }

    # ==========================================================
    # PHASE 3 — ONBOARDING & API CALLS
    # Execute the onboarding plan based on AnalysisReport.csv.
    # Simulation mode passes SimulationMode=$true to all write 
    # functions — they log without touching CyberArk.
    # ==========================================================
    Write-Log -Message "========== PHASE 3: ONBOARDING & API CALLS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phase3Start = Get-Date

    if (-not (Test-Path $analysisFile)) {
        throw "Cannot proceed to Phase 3: $analysisFile does not exist."
    }

    $csvPlan = Import-Csv -Path $analysisFile | Where-Object { $_.Status -in @("NeedsAll", "NeedsOnboarding") }
    $onboardingResults = [System.Collections.Generic.List[object]]::new()

    foreach ($plan in $csvPlan) {
        $tokens = @{
            PrimaryAccount   = $plan.PrimaryAccount
            SecondaryAccount = $plan.SecondaryAccount
            EmployeeNumber   = $plan.EmployeeNumber
            Domain           = $plan.Domain
            SafeName         = $plan.ExpectedSafe
        }

        $provResult     = $null
        $onboardResult  = $null
        $overallSuccess = $true
        $errorMsg       = ""

        # Step A: Provision safe (create + add members) if needed
        $safeExistsBool = [System.Convert]::ToBoolean($plan.SafeExists)
        if (-not $safeExistsBool) {
            $provResult = Invoke-SAASafeProvisioning `
                -Tokens            $tokens `
                -PersonalSafeConfig $cfgSafe `
                -SafePermissionSets $cfgPermSets `
                -BaseUrl           $BaseUrl `
                -ScriptName        $ScriptName `
                -LogPath           $LogPath `
                -SimulationMode    $SimulationMode

            if ($provResult.Errors.Count -gt 0) {
                $overallSuccess = $false
                $errorMsg       = $provResult.Errors -join "; "
                Write-Log -Message "Safe provisioning failed for '$($plan.ExpectedSafe)': $errorMsg" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
        }

        # Step B: Onboard the secondary account (skip if safe provisioning failed)
        if ($overallSuccess) {
            $onboardResult = Invoke-SAAAccountOnboard `
                -Username       $plan.SecondaryAccount `
                -Address        $plan.Domain `
                -SafeName       $plan.ExpectedSafe `
                -PlatformId     $plan.PlatformId `
                -BaseUrl        $BaseUrl `
                -ScriptName     $ScriptName `
                -LogPath        $LogPath `
                -SimulationMode $SimulationMode

            if (-not $onboardResult.Success) {
                $overallSuccess = $false
                $errorMsg       = $onboardResult.Error
                Write-Log -Message "Account onboarding failed for '$($plan.SecondaryAccount)': $errorMsg" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            }
        }



        # Record result
        $onboardingResults.Add([PSCustomObject]@{
            PrimaryAccount   = $plan.PrimaryAccount
            SecondaryAccount = $plan.SecondaryAccount
            Domain           = $plan.Domain
            SafeName         = $plan.ExpectedSafe
            Simulated        = $SimulationMode
            Success          = $overallSuccess
            ErrorMessage     = $errorMsg
        })
    }

    # Export onboarding results
    if ($onboardingResults.Count -gt 0) {
        $onboardingResults | Export-Csv -Path $onboardingFile -NoTypeInformation -Encoding UTF8
        $succeeded = ($onboardingResults | Where-Object { $_.Success }).Count
        $failed    = ($onboardingResults | Where-Object { -not $_.Success }).Count
        Write-Log -Message "Onboarding results saved: $onboardingFile (Success: $succeeded, Failed: $failed)" -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 3B — USER SUCCESS NOTIFICATIONS
    # Group successful onboardings by primary user and send one email per user
    # ==========================================================
    if ($cfgNotif.UseADMailAttribute) {
        Write-Log -Message "========== PHASE 3B: USER SUCCESS NOTIFICATIONS ==========" -ScriptName $ScriptName -LogPath $LogPath
        
        $successfulOnboards = $onboardingResults | Where-Object { $_.Success }
        $groupedByUser = $successfulOnboards | Group-Object -Property PrimaryAccount
        
        Write-Log -Message "Found $($groupedByUser.Count) users who had accounts successfully provisioned." -ScriptName $ScriptName -LogPath $LogPath
        
        foreach ($group in $groupedByUser) {
            $primaryAccount = $group.Name
            $accounts = $group.Group
            
            # The safe is the same for all accounts of a primary user
            $safeName = $accounts[0].SafeName
            $domain = $accounts[0].Domain
            
            # Find the primary email from the original plan
            $planMatch = $csvPlan | Where-Object { $_.PrimaryAccount -eq $primaryAccount } | Select-Object -First 1
            $primaryEmail = if ($planMatch) { $planMatch.PrimaryEmail } else { "" }
            
            # Generate the HTML list of onboarded accounts
            $accountListHtml = "<ul style='margin: 0; padding-left: 20px;'>"
            foreach ($acc in $accounts) {
                $accountListHtml += "<li>$($acc.SecondaryAccount)</li>"
            }
            $accountListHtml += "</ul>"
            
            $tokens = @{
                PrimaryAccount        = $primaryAccount
                Domain                = $domain
                SafeName              = $safeName
                OnboardedAccountsList = $accountListHtml
                GeneratedDate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                SecondaryAccount      = "Multiple" # Fallback log message token
            }
            
            Send-SAAUserSuccessNotification `
                -Tokens           $tokens `
                -UserEmail        $primaryEmail `
                -GlobalEmailConfig $config.Email `
                -TemplatesPath    $templatesPath `
                -ScriptName       $ScriptName `
                -LogPath          $LogPath `
                -SimulationMode   $SimulationMode
        }
    }

    # ==========================================================
    # PHASE 4 — RUN SUMMARY EMAIL
    # Sent in Simulation or Onboarding mode.
    # ==========================================================
    if ($effectiveMode -in @("Simulation", "Onboarding") -and $cfgNotif.SendSimulationSummary) {
        Write-Log -Message "========== PHASE 4: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        $plannedSafes    = ($plannedActions | Where-Object { $_.Action -eq "CreateSafe"           }).Count
        $plannedOnboards = ($plannedActions | Where-Object { $_.Action -eq "OnboardAccount"        }).Count
        $plannedUser     = ($plannedActions | Where-Object { $_.Action -eq "SendUserNotification_Success" }).Count

        $actualSafes     = ($onboardingResults | Where-Object { $_.Success }).Count # Rough estimate if we tracked safes specifically, but usually 1:1 or less
        $actualOnboards  = ($onboardingResults | Where-Object { $_.Success }).Count

        $isSim = $effectiveMode -eq "Simulation"

        $modeTitle        = if ($isSim) { "Simulation Run Complete" } else { "Execution Run Complete" }
        $modeBanner       = if ($isSim) { 'SIMULATION MODE - No safes were created. No accounts were onboarded. No operational emails were sent.' } else { 'EXECUTION COMPLETE - Safes and accounts have been provisioned in CyberArk.' }
        $safesLabel       = if ($isSim) { "Safes Would Be Created" } else { "Safes Created" }
        $onboardsLabel    = if ($isSim) { "Accounts Would Be Onboarded" } else { "Accounts Onboarded" }
        $adminAlertsLabel = if ($isSim) { "Admin Alerts Would Be Sent" } else { "Admin Alerts Sent" }
        $userAlertsLabel  = if ($isSim) { "User Notifications Would Be Sent" } else { "User Notifications Sent" }
        
        $plannedSafesCnt   = if ($isSim) { $plannedSafes } else { $actualSafes }
        $plannedOnbrdsCnt  = if ($isSim) { $plannedOnboards } else { $actualOnboards }
        $plannedUsrAlrtCnt = if ($isSim) { $plannedUser } else { $actualOnboards }

        $summaryTokens = @{
            EffectiveMode         = $effectiveMode
            ModeTitle             = $modeTitle
            ModeBanner            = $modeBanner
            SafesLabel            = $safesLabel
            OnboardsLabel         = $onboardsLabel
            AdminAlertsLabel      = $adminAlertsLabel
            UserAlertsLabel       = $userAlertsLabel
            
            TotalScanned          = $totalSecondary
            PlannedSafes          = $plannedSafesCnt
            PlannedOnboards       = $plannedOnbrdsCnt
            PlannedAdminAlerts    = 1
            PlannedUserAlerts     = $plannedUsrAlrtCnt
            MissingPrimary        = $countMissingPrimary
            CountManaged          = $countManaged
            CountNeedsAll         = $countNeedsAll
            CountNeedsOnboarding  = $countNeedsOnboarding
            CountMissingGroup     = $countMissingGroup
            CountPrimaryDisabled  = $countPrimaryDisabled
            CountSecondaryDisabled = $countSecondaryDisabled
            TotalEPVUsers         = $cyberArkUsers.Count
            NewEPVUsersConsumed   = $newEpvUsersConsumed.Count
            GeneratedDate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        Write-Log -Message "Summary Email Context prepared. Mode: $effectiveMode. Preparing to send to Admins: $($cfgNotif.AdminTo -join ', ')" -ScriptName $ScriptName -LogPath $LogPath

        Send-SAARunSummary `
            -Tokens              $summaryTokens `
            -PlannedActionsFile  $plannedFile `
            -AnalysisReportFile  $analysisFile `
            -OnboardingResultsFile $onboardingFile `
            -SkippedAccountsFile $skippedAccountsFile `
            -MissingGroupFile    $missingGroupFile `
            -GlobalEmailConfig   $config.Email `
            -AdminTo             $cfgNotif.AdminTo `
            -AdminCC             $cfgNotif.AdminCC `
            -TemplatesPath       $templatesPath `
            -ScriptName          $ScriptName `
            -LogPath             $LogPath
    }

    $phase3Duration = (Get-Date) - $phase3Start
    Write-Log -Message "Phase 3 (Onboarding & Notifications) completed in $([math]::Round($phase3Duration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
}
catch {
    Write-Log -Message "SecondaryAccountAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
