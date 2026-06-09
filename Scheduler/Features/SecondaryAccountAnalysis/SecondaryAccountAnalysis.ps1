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
$requiredGroup     = $featureConfig.RequiredCyberArkGroup
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
$cacheOnboarded    = Join-Path $ExportDir "RawCache_OnboardedAccounts_$TodayStr.csv"
$cacheGroupMembers = Join-Path $ExportDir "RawCache_GroupMembers_$TodayStr.csv"

# Output file paths (timestamped)
$analysisFile    = Join-Path $ExportDir "SAA_AnalysisReport_$Timestamp.csv"
$plannedFile     = Join-Path $ExportDir "SAA_PlannedActions_$Timestamp.csv"
$onboardingFile  = Join-Path $ExportDir "SAA_OnboardingResults_$Timestamp.csv"

# ============================================================
# Authenticate — CCP or manual (same pattern as all features)
# ============================================================
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -ManualLogin:$ManualLogin `
    -ScriptName $ScriptName -LogPath $LogPath

Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential `
    -ScriptName $ScriptName -LogPath $LogPath

try {

    # ==========================================================
    # PHASE 1 — DISCOVERY (all modes)
    # Collect raw data from AD (all 13 domains) and CyberArk API.
    # Each dataset is cached per date — re-running on the same day
    # loads from disk and skips live queries.
    # ==========================================================
    Write-Log -Message "========== PHASE 1: DISCOVERY ==========" -ScriptName $ScriptName -LogPath $LogPath

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
        -EmpNbrCapture  $cfgSecondary.EmployeeNumberCapture `
        -Exclusions     $cfgExclusions `
        -CacheDir       $ExportDir `
        -TodayStr       $TodayStr `
        -ScriptName     $ScriptName `
        -LogPath        $LogPath `
        -GlobalCCPUrl   $config.CCP.Url `
        -ManualLogin    $ManualLogin

    Write-Log -Message "Secondary AD accounts collected: $($secondaryADAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    # 1c. CyberArk LDAP users (for access verification)
    $cyberArkUsers = Get-SAACyberArkUsers `
        -BaseUrl    $BaseUrl `
        -CachePath  $cacheUsers `
        -ScriptName $ScriptName `
        -LogPath    $LogPath

    Write-Log -Message "CyberArk LDAP users collected: $($cyberArkUsers.Count)" -ScriptName $ScriptName -LogPath $LogPath

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
        -ScriptName         $ScriptName `
        -LogPath            $LogPath

    Write-Log -Message "Onboarded accounts in personal safes: $($onboardedAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    # 1f. CyberArk group members (required group for onboarding eligibility)
    $groupMemberSet = Get-SAAGroupMemberSet `
        -BaseUrl    $BaseUrl `
        -GroupName  $requiredGroup `
        -CachePath  $cacheGroupMembers `
        -ScriptName $ScriptName `
        -LogPath    $LogPath

    Write-Log -Message "Group '$requiredGroup' members collected: $($groupMemberSet.Count)" -ScriptName $ScriptName -LogPath $LogPath

    if ($effectiveMode -eq "Discovery") {
        Write-Log -Message "Mode=Discovery. Raw data collected and cached. Exiting after Phase 1." -ScriptName $ScriptName -LogPath $LogPath
        Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
        Write-Log -Message "Execution completed (Discovery mode)" -ScriptName $ScriptName -LogPath $LogPath
        exit 0
    }

    # ==========================================================
    # PHASE 2 — ANALYSIS
    # Build lookup structures and correlate secondary accounts
    # with their primary accounts, CyberArk access, safe status,
    # and onboarding status.
    # ==========================================================
    Write-Log -Message "========== PHASE 2: ANALYSIS ==========" -ScriptName $ScriptName -LogPath $LogPath

    # Build: EmpNbr → Primary AD user {Username, Mail, Enabled}
    $primaryUserMap = @{}
    foreach ($u in $primaryADUsers) {
        if ($u.EmployeeNbr -and -not $primaryUserMap.ContainsKey($u.EmployeeNbr)) {
            $primaryUserMap[$u.EmployeeNbr] = $u
        }
    }
    Write-Log -Message "Primary user map built: $($primaryUserMap.Count) unique employee numbers" -ScriptName $ScriptName -LogPath $LogPath

    # Build: CyberArk username set (case-insensitive) for access check
    $cyberArkUserSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($u in $cyberArkUsers) { [void]$cyberArkUserSet.Add($u.Username) }
    Write-Log -Message "CyberArk user set: $($cyberArkUserSet.Count) usernames" -ScriptName $ScriptName -LogPath $LogPath

    # Build: group member set (already fetched and cached in Phase 1)

    # Build: existing safe name set (case-insensitive)
    $safeSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($s in $personalSafes) { [void]$safeSet.Add($s.SafeName) }

    # Build: onboarded account lookup "USERNAME|DOMAIN" → SafeName
    $onboardedMap = @{}
    foreach ($acc in $onboardedAccounts) {
        if ($acc.Username -and $acc.Address) {
            $key = "$($acc.Username.ToUpper())|$($acc.Address.ToUpper())"
            $onboardedMap[$key] = $acc.SafeName
        }
    }
    Write-Log -Message "Onboarded account lookup map: $($onboardedMap.Count) entries" -ScriptName $ScriptName -LogPath $LogPath

    # ── Analysis loop ──
    $analysisReport  = [System.Collections.Generic.List[object]]::new()
    $plannedActions  = [System.Collections.Generic.List[object]]::new()
    $onboardingPlan  = [System.Collections.Generic.List[object]]::new()  # for Phase 3

    $seq = 0

    # Status counters for simulation summary email
    $countManaged         = 0
    $countNeedsAll        = 0
    $countNeedsOnboarding = 0
    $countMissingGroup    = 0
    $countMissingCyberArk = 0
    $countMissingPrimary  = 0

    $totalSecondary = $secondaryADAccounts.Count
    $processed      = 0

    foreach ($secondary in $secondaryADAccounts) {
        $processed++
        if ($processed % 100 -eq 0) {
            Write-Log -Message "Analysing accounts: $processed / $totalSecondary..." -ScriptName $ScriptName -LogPath $LogPath
        }

        $empNbr = $secondary.EmployeeNbr

        # Resolve primary account (U-prefix, NA domain only)
        $primaryADUser   = if ($empNbr) { $primaryUserMap[$empNbr] } else { $null }
        $primaryUsername = if ($primaryADUser) { $primaryADUser.Username } else { "" }
        $primaryEmail    = if ($primaryADUser) { $primaryADUser.Mail     } else { "" }

        # Fallback email construction if AD mail attribute is empty
        if ([string]::IsNullOrWhiteSpace($primaryEmail) -and $primaryUsername -and $cfgNotif.UserEmailFallbackDomain) {
            $primaryEmail = "$primaryUsername@$($cfgNotif.UserEmailFallbackDomain)"
        }

        $hasPrimary         = $null -ne $primaryADUser
        $primaryInCyberArk  = $hasPrimary -and $cyberArkUserSet.Contains($primaryUsername)
        $primaryInGroup     = $primaryInCyberArk -and $groupMemberSet.Contains($primaryUsername)

        # Resolve expected safe name for this user
        $tokenMap = @{
            PrimaryAccount   = $primaryUsername
            SecondaryAccount = $secondary.Username
            EmployeeNumber   = $empNbr
            Domain           = $secondary.DomainFQDN
            GeneratedDate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            RequiredGroup    = $requiredGroup
            SafeName         = ""
        }
        $expectedSafe = if ($hasPrimary -and $empNbr) {
            Resolve-SAAToken -Template $cfgSafe.NamingPattern -Tokens $tokenMap
        } else { "" }
        $tokenMap["SafeName"] = $expectedSafe

        $safeExists  = $expectedSafe -and $safeSet.Contains($expectedSafe)
        $onboardKey  = "$($secondary.Username.ToUpper())|$($secondary.Domain.ToUpper())"
        $isOnboarded = $onboardedMap.ContainsKey($onboardKey)
        $onboardedIn = if ($isOnboarded) { $onboardedMap[$onboardKey] } else { "" }

        # ── Determine status ──
        $status = switch ($true) {
            { -not $hasPrimary        } { "MissingPrimary";       break }
            { -not $primaryInCyberArk } { "MissingCyberArkAccess"; break }
            { -not $primaryInGroup    } { "MissingGroupAccess";    break }
            { $isOnboarded            } { "Managed";               break }
            { $safeExists             } { "NeedsOnboarding";       break }
            default                     { "NeedsAll" }
        }

        # Update counters
        switch ($status) {
            "Managed"              { $countManaged++ }
            "NeedsAll"             { $countNeedsAll++ }
            "NeedsOnboarding"      { $countNeedsOnboarding++ }
            "MissingGroupAccess"   { $countMissingGroup++ }
            "MissingCyberArkAccess"{ $countMissingCyberArk++ }
            "MissingPrimary"       { $countMissingPrimary++ }
        }

        # Analysis report row
        $analysisReport.Add([PSCustomObject]@{
            PrimaryAccount      = $primaryUsername
            SecondaryAccount    = $secondary.Username
            Domain              = $secondary.DomainFQDN
            EmployeeNumber      = $empNbr
            ADEnabled           = $secondary.Enabled
            PrimaryInCyberArk   = $primaryInCyberArk
            PrimaryInGroup      = $primaryInGroup
            PersonalSafeExists  = $safeExists
            AccountOnboarded    = $isOnboarded
            OnboardedInSafe     = $onboardedIn
            ExpectedSafe        = $expectedSafe
            PlatformId          = $secondary.PlatformId
            PrimaryEmail        = $primaryEmail
            Status              = $status
        })

        # ── Build planned actions for Simulation / Onboarding modes ──
        if ($status -in @("NeedsAll", "NeedsOnboarding", "MissingGroupAccess")) {

            if ($status -eq "MissingGroupAccess") {
                $seq++
                $plannedActions.Add([PSCustomObject]@{
                    Sequence        = $seq
                    Action          = "SendAdminAlert_MissingAccess"
                    Detail          = "Primary '$primaryUsername' not in group '$requiredGroup'"
                    PrimaryAccount  = $primaryUsername
                    SecondaryAccount= $secondary.Username
                    Domain          = $secondary.DomainFQDN
                    Status          = "Planned"
                    Notes           = "No onboarding possible until access is granted"
                })
            }

            if ($status -eq "NeedsAll") {
                $seq++
                $plannedActions.Add([PSCustomObject]@{
                    Sequence        = $seq
                    Action          = "CreateSafe"
                    Detail          = $expectedSafe
                    PrimaryAccount  = $primaryUsername
                    SecondaryAccount= $secondary.Username
                    Domain          = $secondary.DomainFQDN
                    Status          = "Planned"
                    Notes           = "Safe does not exist"
                })

                foreach ($member in $cfgSafe.Members) {
                    $resolvedMember = Resolve-SAAToken -Template $member.Name -Tokens $tokenMap
                    $seq++
                    $plannedActions.Add([PSCustomObject]@{
                        Sequence        = $seq
                        Action          = "AddMember"
                        Detail          = "$resolvedMember ($($member.Type)) → $($member.PermissionSet)"
                        PrimaryAccount  = $primaryUsername
                        SecondaryAccount= $secondary.Username
                        Domain          = $secondary.DomainFQDN
                        Status          = "Planned"
                        Notes           = "Safe: $expectedSafe"
                    })
                }

                $seq++
                $plannedActions.Add([PSCustomObject]@{
                    Sequence        = $seq
                    Action          = "SendAdminAlert_SafeCreated"
                    Detail          = "Notify admins of safe creation: $expectedSafe"
                    PrimaryAccount  = $primaryUsername
                    SecondaryAccount= $secondary.Username
                    Domain          = $secondary.DomainFQDN
                    Status          = "Planned"
                    Notes           = ""
                })
            }

            if ($status -in @("NeedsAll", "NeedsOnboarding")) {
                $seq++
                $plannedActions.Add([PSCustomObject]@{
                    Sequence        = $seq
                    Action          = "OnboardAccount"
                    Detail          = "$($secondary.Username) @ $($secondary.DomainFQDN) → $expectedSafe"
                    PrimaryAccount  = $primaryUsername
                    SecondaryAccount= $secondary.Username
                    Domain          = $secondary.DomainFQDN
                    Status          = "Planned"
                    Notes           = "Platform: $($secondary.PlatformId)"
                })

                $seq++
                $plannedActions.Add([PSCustomObject]@{
                    Sequence        = $seq
                    Action          = "SendUserNotification_Success"
                    Detail          = "Notify $primaryEmail"
                    PrimaryAccount  = $primaryUsername
                    SecondaryAccount= $secondary.Username
                    Domain          = $secondary.DomainFQDN
                    Status          = "Planned"
                    Notes           = "User email: $primaryEmail"
                })

                # Add to onboarding plan for Phase 3 execution
                $onboardingPlan.Add([PSCustomObject]@{
                    PrimaryAccount   = $primaryUsername
                    SecondaryAccount = $secondary.Username
                    EmployeeNumber   = $empNbr
                    Domain           = $secondary.DomainFQDN
                    PlatformId       = $secondary.PlatformId
                    ExpectedSafe     = $expectedSafe
                    SafeExists       = $safeExists
                    PrimaryEmail     = $primaryEmail
                    Tokens           = $tokenMap
                })
            }
        }
    }

    Write-Log -Message "Analysis complete. Managed=$countManaged, NeedsAll=$countNeedsAll, NeedsOnboarding=$countNeedsOnboarding, MissingGroup=$countMissingGroup, MissingCyberArk=$countMissingCyberArk, MissingPrimary=$countMissingPrimary" `
        -ScriptName $ScriptName -LogPath $LogPath

    # Export analysis report (all modes)
    $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath

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
    # PHASE 3 — ONBOARDING (Onboarding mode only)
    # Execute the onboarding plan. Simulation mode passes
    # SimulationMode=$true to all write functions — they log
    # without touching CyberArk.
    # ==========================================================
    Write-Log -Message "========== PHASE 3: ONBOARDING ==========" -ScriptName $ScriptName -LogPath $LogPath

    $onboardingResults = [System.Collections.Generic.List[object]]::new()

    foreach ($plan in $onboardingPlan) {
        $tokens = $plan.Tokens

        $provResult     = $null
        $onboardResult  = $null
        $overallSuccess = $true
        $errorMsg       = ""

        # Step A: Provision safe (create + add members) if needed
        if (-not $plan.SafeExists) {
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

                # Send failure alert
                $tokens["FailedOperation"] = "SafeProvisioning"
                $tokens["ErrorMessage"]    = $errorMsg
                Send-SAAFailureAlert -Tokens $tokens -GlobalEmailConfig $config.Email `
                    -AdminTo $cfgNotif.AdminTo -AdminCC $cfgNotif.AdminCC `
                    -TemplatesPath $templatesPath -ScriptName $ScriptName -LogPath $LogPath `
                    -SimulationMode $SimulationMode
            }
            elseif ($provResult.SafeCreated -and -not $SimulationMode) {
                # Safe was newly created — notify admins
                $tokens["MembersAdded"] = $provResult.MembersAdded
                Send-SAASafeCreatedAlert -Tokens $tokens -GlobalEmailConfig $config.Email `
                    -AdminTo $cfgNotif.AdminTo -AdminCC $cfgNotif.AdminCC `
                    -TemplatesPath $templatesPath -ScriptName $ScriptName -LogPath $LogPath `
                    -SimulationMode $SimulationMode
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

                $tokens["FailedOperation"] = "AccountOnboarding"
                $tokens["ErrorMessage"]    = $errorMsg
                Send-SAAFailureAlert -Tokens $tokens -GlobalEmailConfig $config.Email `
                    -AdminTo $cfgNotif.AdminTo -AdminCC $cfgNotif.AdminCC `
                    -TemplatesPath $templatesPath -ScriptName $ScriptName -LogPath $LogPath `
                    -SimulationMode $SimulationMode
            }
        }

        # Step C: Send user success notification if everything succeeded
        if ($overallSuccess -and $cfgNotif.UseADMailAttribute) {
            Send-SAAUserSuccessNotification `
                -Tokens           $tokens `
                -UserEmail        $plan.PrimaryEmail `
                -GlobalEmailConfig $config.Email `
                -TemplatesPath    $templatesPath `
                -ScriptName       $ScriptName `
                -LogPath          $LogPath `
                -SimulationMode   $SimulationMode
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

    # Send missing-access admin alerts
    Write-Log -Message "========== PHASE 4: MISSING ACCESS ALERTS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $missingAccessRows = $analysisReport | Where-Object { $_.Status -eq "MissingGroupAccess" }
    Write-Log -Message "Missing access alerts to send: $($missingAccessRows.Count)" -ScriptName $ScriptName -LogPath $LogPath
    foreach ($row in $missingAccessRows) {
        $alertTokens = @{
            PrimaryAccount   = $row.PrimaryAccount
            SecondaryAccount = $row.SecondaryAccount
            Domain           = $row.Domain
            RequiredGroup    = $requiredGroup
            GeneratedDate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        Send-SAAAdminMissingAccessAlert `
            -Tokens        $alertTokens `
            -GlobalEmailConfig $config.Email `
            -AdminTo       $cfgNotif.AdminTo `
            -AdminCC       $cfgNotif.AdminCC `
            -TemplatesPath $templatesPath `
            -ScriptName    $ScriptName `
            -LogPath       $LogPath `
            -SimulationMode $SimulationMode
    }

    # ==========================================================
    # PHASE 5 — SIMULATION SUMMARY EMAIL
    # Sent only in Simulation mode (if enabled in config).
    # ==========================================================
    if ($SimulationMode -and $cfgNotif.SendSimulationSummary) {
        Write-Log -Message "========== PHASE 5: SIMULATION SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        $plannedSafes    = ($plannedActions | Where-Object { $_.Action -eq "CreateSafe"           }).Count
        $plannedOnboards = ($plannedActions | Where-Object { $_.Action -eq "OnboardAccount"        }).Count
        $plannedAdmin    = ($plannedActions | Where-Object { $_.Action -like "SendAdminAlert*"      }).Count
        $plannedUser     = ($plannedActions | Where-Object { $_.Action -eq "SendUserNotification_Success" }).Count

        $summaryTokens = @{
            TotalScanned          = $totalSecondary
            PlannedSafes          = $plannedSafes
            PlannedOnboards       = $plannedOnboards
            PlannedAdminAlerts    = $plannedAdmin
            PlannedUserAlerts     = $plannedUser
            MissingPrimary        = $countMissingPrimary
            CountManaged          = $countManaged
            CountNeedsAll         = $countNeedsAll
            CountNeedsOnboarding  = $countNeedsOnboarding
            CountMissingGroup     = $countMissingGroup
            CountMissingCyberArk  = $countMissingCyberArk
            GeneratedDate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        Send-SAASimulationSummary `
            -Tokens             $summaryTokens `
            -PlannedActionsFile $plannedFile `
            -AnalysisReportFile $analysisFile `
            -GlobalEmailConfig  $config.Email `
            -AdminTo            $cfgNotif.AdminTo `
            -AdminCC            $cfgNotif.AdminCC `
            -TemplatesPath      $templatesPath `
            -ScriptName         $ScriptName `
            -LogPath            $LogPath
    }

}
catch {
    Write-Log -Message "SecondaryAccountAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
