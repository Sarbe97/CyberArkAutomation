param (
    [switch] $ManualLogin,
    [ValidateSet("Discovery", "Analysis", "")]
    [string] $Mode = ""
)

# ============================================================
# Script Identity
# ============================================================
$ScriptName    = "ServiceAccountAnalysis"
$FeatureRoot   = $PSScriptRoot
$SchedulerRoot = Split-Path -Parent (Split-Path -Parent $FeatureRoot)
$ConfigPath    = Join-Path $FeatureRoot "config.json"

# ============================================================
# Setup Paths - Logs & Output
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
. (Join-Path $FeatureRoot   "Modules\SVC_DataCollection.ps1")
. (Join-Path $FeatureRoot   "Modules\SVC_Notifications.ps1")

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
$featureConfig = $config.Features.ServiceAccountAnalysis

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $featureConfig -or -not $featureConfig.Enabled) {
    Write-Log -Message "ServiceAccountAnalysis is disabled in config. Exiting." -ScriptName $ScriptName -LogPath $LogPath
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
$cfgPersonalAccount = $featureConfig.PersonalAccount
$cfgDomains         = $featureConfig.Domains
$cfgNotif           = $featureConfig.Notifications
$templatesPath      = Join-Path $FeatureRoot "Templates"

# Personal safe regex - read from this feature's own config.
# Accounts whose SafeName matches this pattern are excluded from the
# CyberArk service-account count and the AD cross-reference.
$cfgPersonalSafeRegex = if ($featureConfig.PersonalSafe -and $featureConfig.PersonalSafe.NamingPatternRegex) {
    $featureConfig.PersonalSafe.NamingPatternRegex
} else { "" }

if ($cfgPersonalSafeRegex) {
    Write-Log -Message "Personal safe regex: $cfgPersonalSafeRegex" -ScriptName $ScriptName -LogPath $LogPath
} else {
    Write-Log -Message "No PersonalSafe.NamingPatternRegex configured - personal safe filter will be skipped." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
}

Write-Log -Message "Personal Account pattern (to exclude from AD): $($cfgPersonalAccount.Pattern)" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Domains configured: $($cfgDomains.Count)" -ScriptName $ScriptName -LogPath $LogPath

# ============================================================
# Output file paths
# ============================================================
$analysisFile = Join-Path $ExportDir "SVC_AnalysisReport_$Timestamp.csv"

# ============================================================
# Main Execution Block
# CyberArk auth is attempted first (nested try/catch so a failed
# auth is non-fatal - script continues in AD-only mode).
# ============================================================
$cyberArkToken         = $null
$cyberArkAuthAvailable = $false

try {

    # ----------------------------------------------------------
    # CYBERARK AUTHENTICATION
    # Uses global config credentials: direct if both Username +
    # Password are non-blank, otherwise falls through to CCP.
    # ----------------------------------------------------------
    Write-Log -Message "========== CYBERARK AUTHENTICATION ==========" -ScriptName $ScriptName -LogPath $LogPath

    try {
        $globalUsername = if ($config.Username) { $config.Username } else { "" }
        $globalPassword = if ($config.Password) { $config.Password } else { "" }

        $cyberArkCred = Get-SchedulerCredential `
            -CCPConfig   $config.CCP `
            -ManualLogin:$ManualLogin `
            -Username    $globalUsername `
            -Password    $globalPassword `
            -ScriptName  $ScriptName `
            -LogPath     $LogPath

        Write-Log -Message "Credential resolved for CyberArk (Username: $($cyberArkCred.Username)). Connecting..." -ScriptName $ScriptName -LogPath $LogPath

        $cyberArkToken = Connect-CyberArkApi `
            -BaseUrl    $BaseUrl `
            -Credential $cyberArkCred `
            -ScriptName $ScriptName `
            -LogPath    $LogPath

        $cyberArkAuthAvailable = $true
        Write-Log -Message "CyberArk authentication successful." -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "CyberArk authentication failed: $($_.Exception.Message). Continuing with AD-only analysis (InCyberArk will be Unknown)." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 1 - AD DATA COLLECTION
    # ==========================================================
    Write-Log -Message "========== PHASE 1: AD DATA COLLECTION ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phaseStart = Get-Date

    $serviceAccounts = Get-SVCADAccounts `
        -Domains                $cfgDomains `
        -PersonalAccountPattern $cfgPersonalAccount.Pattern `
        -CacheDir               $ExportDir `
        -TodayStr               $TodayStr `
        -ScriptName             $ScriptName `
        -LogPath                $LogPath `
        -GlobalCCPUrl           $config.CCP.Url `
        -ManualLogin            $ManualLogin

    Write-Log -Message "AD service accounts collected: $($serviceAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    $phaseDuration = (Get-Date) - $phaseStart
    Write-Log -Message "AD Data Collection completed in $([math]::Round($phaseDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

    # ==========================================================
    # PHASE 2 - CYBERARK FETCH + ONBOARDING ANALYSIS
    # ==========================================================
    Write-Log -Message "========== PHASE 2: CYBERARK FETCH & ANALYSIS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phaseStart = Get-Date

    $cyberArkAccounts = @()
    $analysisReport   = [System.Collections.Generic.List[object]]::new()

    if ($cyberArkAuthAvailable -and $cyberArkToken) {
        $cyberArkAccounts = Get-SVCCyberArkAccounts `
            -BaseUrl           $BaseUrl `
            -Token             $cyberArkToken `
            -CacheDir          $ExportDir `
            -TodayStr          $TodayStr `
            -ScriptName        $ScriptName `
            -LogPath           $LogPath `
            -PersonalSafeRegex $cfgPersonalSafeRegex `
            -Domains           $cfgDomains

        $enrichedAccounts = Resolve-SVCCyberArkOnboarding `
            -ADAccounts       $serviceAccounts `
            -CyberArkAccounts $cyberArkAccounts `
            -ScriptName       $ScriptName `
            -LogPath          $LogPath

        foreach ($acct in $enrichedAccounts) {
            $analysisReport.Add($acct)
        }
    }
    else {
        Write-Log -Message "Skipping CyberArk cross-reference (no auth). Marking all accounts as InCyberArk=Unknown." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        foreach ($sa in $serviceAccounts) {
            $analysisReport.Add([PSCustomObject]@{
                Username             = $sa.Username
                Domain               = $sa.Domain
                DomainFQDN           = $sa.DomainFQDN
                DistinguishedName    = $sa.DistinguishedName
                OU                   = $sa.OU
                Enabled              = $sa.Enabled
                PasswordExpired      = $sa.PasswordExpired
                PasswordLastSet      = $sa.PasswordLastSet
                PasswordNeverExpires = $sa.PasswordNeverExpires
                LastLogonDate        = $sa.LastLogonDate
                Mail                 = $sa.Mail
                Description          = $sa.Description
                wwwHomePage          = $sa.wwwHomePage
                Manager              = $sa.Manager
                Info                 = $sa.Info
                InCyberArk           = "Unknown"
                CyberArkSafe         = ""
                CyberArkPlatform     = ""
            })
        }
    }

    $phaseDuration = (Get-Date) - $phaseStart
    Write-Log -Message "CyberArk Fetch & Analysis completed in $([math]::Round($phaseDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

    if ($analysisReport.Count -gt 0) {
        $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath
    }
    else {
        Write-Log -Message "No service accounts found to report." -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 3 - SUMMARY EMAIL
    # ==========================================================
    if ($effectiveMode -eq "Analysis" -and $cfgNotif.SendSummary) {
        Write-Log -Message "========== PHASE 3: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        # --- Compute breakdown metrics ---
        # If 'Enabled' is missing or anything other than explicitly False, treat it as True
        $disabledAccounts = @($analysisReport | Where-Object { $_.Enabled -eq $false -or $_.Enabled -eq "False" })
        $enabledAccounts  = @($analysisReport | Where-Object { $_.Enabled -ne $false -and $_.Enabled -ne "False" })

        # If 'InCyberArk' is anything other than explicitly True (including False or Unknown), count as Not in CyberArk
        $enabledInCyberArk    = @($enabledAccounts  | Where-Object { $_.InCyberArk -eq $true  -or $_.InCyberArk -eq "True"  })
        $enabledNotInCyberArk = @($enabledAccounts  | Where-Object { $_.InCyberArk -ne $true  -and $_.InCyberArk -ne "True" })
        
        $disabledInCyberArk   = @($disabledAccounts | Where-Object { $_.InCyberArk -eq $true  -or $_.InCyberArk -eq "True"  })
        $disabledNotCyberArk  = @($disabledAccounts | Where-Object { $_.InCyberArk -ne $true  -and $_.InCyberArk -ne "True" })

        $summaryTokens = @{
            EffectiveMode           = $effectiveMode
            ModeTitle               = "Execution Run Complete"
            GeneratedDate           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            TotalServiceAccounts    = $analysisReport.Count
            TotalCyberArkAccounts   = $cyberArkAccounts.Count
            EnabledInAD             = $enabledAccounts.Count
            DisabledInAD            = $disabledAccounts.Count
            EnabledInCyberArk       = $enabledInCyberArk.Count
            EnabledNotInCyberArk    = $enabledNotInCyberArk.Count
            DisabledInCyberArk      = $disabledInCyberArk.Count
            DisabledNotInCyberArk   = $disabledNotCyberArk.Count
            CyberArkAuthStatus      = if ($cyberArkAuthAvailable) { "Connected" } else { "Unavailable" }
            CyberArkAuthStatusColor = if ($cyberArkAuthAvailable) { "4caf7d" } else { "e05252" }
        }

        Send-SVCRunSummary `
            -Tokens             $summaryTokens `
            -AnalysisReportFile $analysisFile `
            -GlobalEmailConfig  $config.Email `
            -AdminTo            $cfgNotif.AdminTo `
            -AdminCC            $cfgNotif.AdminCC `
            -TemplatesPath      $templatesPath `
            -ScriptName         $ScriptName `
            -LogPath            $LogPath `
            -FromOverride       $cfgNotif.AdminFrom
    }

    # ==========================================================
    # PHASE 4: CLEANUP
    # ==========================================================
    $cfgCleanup = $featureConfig.Cleanup
    if ($null -ne $cfgCleanup -and $cfgCleanup.Enabled -and $cfgCleanup.RetentionDays -gt 0) {
        Write-Log -Message "========== PHASE 4: CLEANUP ==========" -ScriptName $ScriptName -LogPath $LogPath
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
    Write-Log -Message "ServiceAccountAnalysis failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
}
finally {
    if ($cyberArkAuthAvailable) {
        Disconnect-CyberArkApi -ScriptName $ScriptName -LogPath $LogPath
    }

    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
