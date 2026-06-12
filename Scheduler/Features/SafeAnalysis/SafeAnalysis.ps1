param (
    [switch] $ManualLogin,
    [ValidateSet("Discovery", "Analysis", "Remediation", "Simulation", "")]
    [string] $Mode = ""
)

# ============================================================
# Script Identity
# ============================================================
$ScriptName    = "SafeAnalysis"
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
. (Join-Path $FeatureRoot   "Modules\SAFE_DataCollection.ps1")
. (Join-Path $FeatureRoot   "Modules\SAFE_SafeOperations.ps1")
. (Join-Path $FeatureRoot   "Modules\SAFE_Notifications.ps1")

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
$featureConfig = $config.Features.SafeAnalysis

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $featureConfig -or -not $featureConfig.Enabled) {
    Write-Log -Message "SafeAnalysis is disabled in config. Exiting." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# ============================================================
# Resolve Effective Mode
# ============================================================
$effectiveMode = if ($Mode) { $Mode } `
                 elseif ($featureConfig.Mode) { $featureConfig.Mode } `
                 else { "Simulation" }

$SimulationMode = ($effectiveMode -eq "Simulation")
Write-Log -Message "Effective execution mode: $effectiveMode" -ScriptName $ScriptName -LogPath $LogPath
if ($SimulationMode) {
    Write-Log -Message "[SIMULATION] No write operations will be performed." -ScriptName $ScriptName -LogPath $LogPath
}

# ============================================================
# Load Feature Settings
# ============================================================
$cfgCommonMembers = $featureConfig.CommonSafeMembers
$cfgPersonalSafes = $featureConfig.PersonalSafes
$cfgExclusions    = $featureConfig.Exclusions
$cfgNotif         = $featureConfig.Notifications
$templatesPath    = Join-Path $FeatureRoot "Templates"

$cfgPermSets = @{}
foreach ($key in $featureConfig.SafePermissionSets.PSObject.Properties.Name) {
    if ($key -notlike "_*") { $cfgPermSets[$key] = $featureConfig.SafePermissionSets.$key }
}

$cacheSafes = Join-Path $ExportDir "RawCache_AllSafes_$TodayStr.csv"
$analysisFile = Join-Path $ExportDir "SAFE_AnalysisReport_$Timestamp.csv"
$remediationFile = Join-Path $ExportDir "SAFE_RemediationResults_$Timestamp.csv"

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
    # PHASE 1 & 2 — DISCOVERY AND ANALYSIS
    # ==========================================================
    Write-Log -Message "========== PHASE 1 & 2: DATA COLLECTION AND ANALYSIS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phaseStart = Get-Date

    $allSafes = Get-SAFEAllSafes `
        -BaseUrl    $BaseUrl `
        -Exclusions $cfgExclusions `
        -CachePath  $cacheSafes `
        -ScriptName $ScriptName `
        -LogPath    $LogPath

    $analysisReport = [System.Collections.Generic.List[object]]::new()
    $remediationQueue = [System.Collections.Generic.List[object]]::new()

    $cntMissingCommon = 0
    $cntMissingPrimary = 0
    $cntIncorrectPerms = 0
    $cntCompliant = 0
    $cntNonCompliant = 0

    $safeIndex = 0
    $totalSafes = $allSafes.Count

    foreach ($safe in $allSafes) {
        $safeIndex++
        Write-Progress -Id 50 -Activity "Analyzing Safes" -Status "[$safeIndex/$totalSafes] Analyzing safe '$($safe.SafeName)'..." -PercentComplete ([int](($safeIndex / $totalSafes) * 100))
        
        $members = Get-SAFESafeMembers -BaseUrl $BaseUrl -SafeName $safe.SafeName -ScriptName $ScriptName -LogPath $LogPath
        
        # Build member lookup map (lowercase name -> actual object)
        $memberMap = @{}
        foreach ($m in $members) { $memberMap[$m.MemberName.ToLower()] = $m }

        $isPersonalSafe = $safe.SafeName -match $cfgPersonalSafes.Pattern
        $safeCompliant = $true

        # 1. Check Common Members
        foreach ($reqMember in $cfgCommonMembers) {
            $expectedPerms = $cfgPermSets[$reqMember.PermissionSet]
            $memberNameLower = $reqMember.Name.ToLower()

            if (-not $memberMap.ContainsKey($memberNameLower)) {
                $safeCompliant = $false
                $cntMissingCommon++
                $analysisReport.Add([PSCustomObject]@{
                    SafeName       = $safe.SafeName
                    IsPersonalSafe = $isPersonalSafe
                    IssueType      = "MissingCommonMember"
                    MemberName     = $reqMember.Name
                    ExpectedPerms  = $expectedPerms -join ';'
                    ActualPerms    = ""
                })

                $remediationQueue.Add([PSCustomObject]@{
                    SafeName     = $safe.SafeName
                    MemberName   = $reqMember.Name
                    MemberType   = $reqMember.Type
                    MemberSource = $reqMember.MemberSource
                    Permissions  = $expectedPerms
                    IsUpdate     = $false
                })
            } else {
                # Check permissions
                $actualMember = $memberMap[$memberNameLower]
                $actualPermsList = $actualMember.Permissions
                $missingPerms = @()
                foreach ($ep in $expectedPerms) {
                    if ($ep -notin $actualPermsList) { $missingPerms += $ep }
                }

                if ($missingPerms.Count -gt 0) {
                    $safeCompliant = $false
                    $cntIncorrectPerms++
                    $analysisReport.Add([PSCustomObject]@{
                        SafeName       = $safe.SafeName
                        IsPersonalSafe = $isPersonalSafe
                        IssueType      = "IncorrectPermissions"
                        MemberName     = $reqMember.Name
                        ExpectedPerms  = $expectedPerms -join ';'
                        ActualPerms    = $actualPermsList -join ';'
                    })

                    # Combine existing perms with expected perms so we don't lose anything
                    $mergedPerms = @($actualPermsList) + @($missingPerms) | Select-Object -Unique
                    
                    $remediationQueue.Add([PSCustomObject]@{
                        SafeName     = $safe.SafeName
                        MemberName   = $actualMember.MemberName # Use exact original casing
                        MemberType   = $actualMember.MemberType
                        MemberSource = $reqMember.MemberSource
                        Permissions  = $mergedPerms
                        IsUpdate     = $true
                    })
                }
            }
        }

        # 2. Check Primary Owner if Personal Safe
        if ($isPersonalSafe -and $cfgPersonalSafes.OwnerExtractionRegex) {
            if ($safe.SafeName -match $cfgPersonalSafes.OwnerExtractionRegex) {
                $ownerName = $Matches[1]
                $expectedPerms = $cfgPermSets[$cfgPersonalSafes.OwnerPermissionSet]
                $ownerNameLower = $ownerName.ToLower()

                if (-not $memberMap.ContainsKey($ownerNameLower)) {
                    $safeCompliant = $false
                    $cntMissingPrimary++
                    $analysisReport.Add([PSCustomObject]@{
                        SafeName       = $safe.SafeName
                        IsPersonalSafe = $isPersonalSafe
                        IssueType      = "MissingPrimaryOwner"
                        MemberName     = $ownerName
                        ExpectedPerms  = $expectedPerms -join ';'
                        ActualPerms    = ""
                    })

                    $remediationQueue.Add([PSCustomObject]@{
                        SafeName     = $safe.SafeName
                        MemberName   = $ownerName
                        MemberType   = "User"
                        MemberSource = "Domain" # Typical for personal safe owners
                        Permissions  = $expectedPerms
                        IsUpdate     = $false
                    })
                } else {
                    # Check owner permissions
                    $actualOwner = $memberMap[$ownerNameLower]
                    $actualPermsList = $actualOwner.Permissions
                    $missingPerms = @()
                    foreach ($ep in $expectedPerms) {
                        if ($ep -notin $actualPermsList) { $missingPerms += $ep }
                    }

                    if ($missingPerms.Count -gt 0) {
                        $safeCompliant = $false
                        $cntIncorrectPerms++
                        $analysisReport.Add([PSCustomObject]@{
                            SafeName       = $safe.SafeName
                            IsPersonalSafe = $isPersonalSafe
                            IssueType      = "IncorrectPermissions"
                            MemberName     = $ownerName
                            ExpectedPerms  = $expectedPerms -join ';'
                            ActualPerms    = $actualPermsList -join ';'
                        })

                        $mergedPerms = @($actualPermsList) + @($missingPerms) | Select-Object -Unique

                        $remediationQueue.Add([PSCustomObject]@{
                            SafeName     = $safe.SafeName
                            MemberName   = $actualOwner.MemberName
                            MemberType   = $actualOwner.MemberType
                            MemberSource = "Domain"
                            Permissions  = $mergedPerms
                            IsUpdate     = $true
                        })
                    }
                }
            }
        }

        if ($safeCompliant) { $cntCompliant++ } else { $cntNonCompliant++ }
    }

    Write-Progress -Id 50 -Activity "Analyzing Safes" -Completed
    $phaseDuration = (Get-Date) - $phaseStart
    Write-Log -Message "Discovery and Analysis completed in $([math]::Round($phaseDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

    if ($analysisReport.Count -gt 0) {
        $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 3 — REMEDIATION
    # ==========================================================
    $cntRemediations = 0
    if ($effectiveMode -in @("Remediation", "Simulation") -and $remediationQueue.Count -gt 0) {
        Write-Log -Message "========== PHASE 3: REMEDIATION ==========" -ScriptName $ScriptName -LogPath $LogPath

        $remediationResults = [System.Collections.Generic.List[object]]::new()

        foreach ($action in $remediationQueue) {
            $cntRemediations++
            $res = Invoke-SAFEUpdateSafeMember `
                -BaseUrl        $BaseUrl `
                -SafeName       $action.SafeName `
                -MemberName     $action.MemberName `
                -MemberType     $action.MemberType `
                -MemberSource   $action.MemberSource `
                -Permissions    $action.Permissions `
                -IsUpdate       $action.IsUpdate `
                -SimulationMode $SimulationMode `
                -ScriptName     $ScriptName `
                -LogPath        $LogPath

            $remediationResults.Add([PSCustomObject]@{
                SafeName    = $action.SafeName
                MemberName  = $action.MemberName
                ActionType  = if ($action.IsUpdate) { "Update" } else { "Add" }
                Success     = $res.Success
                Error       = $res.Error
            })
        }

        if ($remediationResults.Count -gt 0) {
            $remediationResults | Export-Csv -Path $remediationFile -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Remediation results saved: $remediationFile" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # ==========================================================
    # PHASE 4 — SUMMARY EMAIL
    # ==========================================================
    if ($cfgNotif.SendSimulationSummary -or $effectiveMode -ne "Simulation") {
        Write-Log -Message "========== PHASE 4: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        $modeTitle = if ($SimulationMode) { "Simulation Run Complete" } else { "Execution Run Complete" }
        $modeBanner = if ($SimulationMode) { 'SIMULATION MODE - No changes were made to CyberArk safes.' } else { 'EXECUTION COMPLETE - Remediation actions have been applied.' }

        $summaryTokens = @{
            EffectiveMode         = $effectiveMode
            ModeTitle             = $modeTitle
            ModeBanner            = $modeBanner
            TotalSafes            = $totalSafes
            CompliantSafes        = $cntCompliant
            NonCompliantSafes     = $cntNonCompliant
            MissingCommonMembers  = $cntMissingCommon
            MissingPrimaryOwner   = $cntMissingPrimary
            IncorrectPermissions  = $cntIncorrectPerms
            RemediationActions    = $cntRemediations
            GeneratedDate         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        Send-SAFERunSummary `
            -Tokens                 $summaryTokens `
            -AnalysisReportFile     $analysisFile `
            -RemediationResultsFile $remediationFile `
            -GlobalEmailConfig      $config.Email `
            -AdminTo                $cfgNotif.AdminTo `
            -AdminCC                $cfgNotif.AdminCC `
            -TemplatesPath          $templatesPath `
            -ScriptName             $ScriptName `
            -LogPath                $LogPath `
            -FromOverride           $cfgNotif.AdminFrom
    }

}
catch {
    Write-Log -Message "SafeAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
