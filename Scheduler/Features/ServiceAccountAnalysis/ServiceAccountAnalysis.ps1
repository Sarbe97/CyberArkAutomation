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
$cfgExclusions      = if ($featureConfig.Exclusions) { $featureConfig.Exclusions } else { [PSCustomObject]@{ Domains=@(); UsernamePatterns=@() } }
$cfgNotif           = $featureConfig.Notifications
$templatesPath      = Join-Path $FeatureRoot "Templates"

Write-Log -Message "Personal Account pattern (to exclude): $($cfgPersonalAccount.Pattern)" -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Domains configured: $($cfgDomains.Count)" -ScriptName $ScriptName -LogPath $LogPath

# ============================================================
# Output file paths
# ============================================================
$analysisFile = Join-Path $ExportDir "SVC_AnalysisReport_$Timestamp.csv"

try {
    # ==========================================================
    # PHASE 1 & 2 — DISCOVERY AND ANALYSIS
    # ==========================================================
    Write-Log -Message "========== PHASE 1 & 2: DATA COLLECTION AND ANALYSIS ==========" -ScriptName $ScriptName -LogPath $LogPath
    $phaseStart = Get-Date

    # Collect service accounts by querying AD and filtering out Personal IDs
    $serviceAccounts = Get-SVCADAccounts `
        -Domains                $cfgDomains `
        -PersonalAccountPattern $cfgPersonalAccount.Pattern `
        -Exclusions             $cfgExclusions `
        -CacheDir               $ExportDir `
        -TodayStr               $TodayStr `
        -ScriptName             $ScriptName `
        -LogPath                $LogPath `
        -GlobalCCPUrl           $config.CCP.Url `
        -ManualLogin            $ManualLogin

    Write-Log -Message "Service accounts collected (after exclusions): $($serviceAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    $analysisReport = [System.Collections.Generic.List[object]]::new()
    foreach ($sa in $serviceAccounts) {
        $analysisReport.Add([PSCustomObject]@{
            Username    = $sa.Username
            Domain      = $sa.DomainFQDN
            ShortDomain = $sa.Domain
            Enabled     = $sa.Enabled
            Mail        = $sa.Mail
            Description = $sa.Description
        })
    }

    $phaseDuration = (Get-Date) - $phaseStart
    Write-Log -Message "Discovery and Analysis completed in $([math]::Round($phaseDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath

    if ($analysisReport.Count -gt 0) {
        $analysisReport | Export-Csv -Path $analysisFile -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Analysis report saved: $analysisFile" -ScriptName $ScriptName -LogPath $LogPath
    } else {
        Write-Log -Message "No service accounts found to report." -ScriptName $ScriptName -LogPath $LogPath
    }

    # ==========================================================
    # PHASE 3 — SUMMARY EMAIL
    # ==========================================================
    if ($effectiveMode -eq "Analysis" -and $cfgNotif.SendSummary) {
        Write-Log -Message "========== PHASE 3: RUN SUMMARY EMAIL ==========" -ScriptName $ScriptName -LogPath $LogPath

        $modeTitle = "Execution Run Complete"

        $summaryTokens = @{
            EffectiveMode        = $effectiveMode
            ModeTitle            = $modeTitle
            TotalServiceAccounts = $serviceAccounts.Count
            GeneratedDate        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        Send-SVCRunSummary `
            -Tokens              $summaryTokens `
            -AnalysisReportFile  $analysisFile `
            -GlobalEmailConfig   $config.Email `
            -AdminTo             $cfgNotif.AdminTo `
            -AdminCC             $cfgNotif.AdminCC `
            -TemplatesPath       $templatesPath `
            -ScriptName          $ScriptName `
            -LogPath             $LogPath `
            -FromOverride        $cfgNotif.AdminFrom
    }

    # ==========================================================
    # PHASE 4: CLEANUP
    # Remove old log files and output directories based on retention config
    # ==========================================================
    $cfgCleanup = $featureConfig.Cleanup
    if ($null -ne $cfgCleanup -and $cfgCleanup.Enabled -and $cfgCleanup.RetentionDays -gt 0) {
        Write-Log -Message "========== PHASE 4: CLEANUP ==========" -ScriptName $ScriptName -LogPath $LogPath
        $cutoffDate = (Get-Date).AddDays(-$cfgCleanup.RetentionDays)
        Write-Log -Message "Cleaning up logs and output older than $($cfgCleanup.RetentionDays) days ($cutoffDate)..." -ScriptName $ScriptName -LogPath $LogPath

        # Cleanup Logs
        if (Test-Path $LogDir) {
            $oldLogs = Get-ChildItem -Path $LogDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
            foreach ($log in $oldLogs) {
                Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-Log -Message "Removed $($oldLogs.Count) old log files." -ScriptName $ScriptName -LogPath $LogPath
        }

        # Cleanup Output
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
    $overallDuration = (Get-Date) - $overallStartTime
    Write-Log -Message "Execution completed in $([math]::Round($overallDuration.TotalSeconds, 2)) seconds." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Execution completed (mode: $effectiveMode)" -ScriptName $ScriptName -LogPath $LogPath
}
