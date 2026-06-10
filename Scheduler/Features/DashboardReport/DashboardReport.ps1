param (
    [switch]$ManualLogin
)

# ------------------------
# Script Identity
# ------------------------
$ScriptName    = "DashboardReport"
$FeatureRoot   = $PSScriptRoot                                              # Scheduler/Features/DashboardReport/
$SchedulerRoot = Split-Path -Parent (Split-Path -Parent $FeatureRoot)       # Scheduler/
$ConfigPath    = Join-Path $FeatureRoot "config.json"

# ------------------------
# Setup Paths (Logs & Output)
# ------------------------
$TodayStr      = Get-Date -Format "yyyyMMdd"
$LogDir        = Join-Path $FeatureRoot "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath       = Join-Path $LogDir "$ScriptName-$TodayStr.log"

$BaseOutputDir = Join-Path $FeatureRoot "Output"
$ExportDir     = Join-Path $BaseOutputDir $TodayStr
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

# ------------------------
# Load Shared Utils + Modules
# ------------------------
. (Join-Path $SchedulerRoot "Utils.ps1")
. (Join-Path $FeatureRoot "Modules\DR_DataCollection.ps1")
. (Join-Path $FeatureRoot "Modules\DR_Analytics.ps1")
. (Join-Path $FeatureRoot "Modules\DR_Summary.ps1")
. (Join-Path $FeatureRoot "Modules\DR_SharePoint.ps1")
. (Join-Path $FeatureRoot "Modules\DR_Email.ps1")

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Load Config
# Global settings (BaseUrl, CCP, Email) come from the root Scheduler config.
# Feature-specific settings come from this feature's own config.json.
# ------------------------
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
$FeatureConfig = $config.Features.DashboardReport

Write-Log -Message "Config loaded. BaseUrl: $BaseUrl" -ScriptName $ScriptName -LogPath $LogPath

if ($null -eq $FeatureConfig -or -not $FeatureConfig.Enabled) {
    Write-Log -Message "DashboardReport feature disabled in config. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}
Write-Log -Message "DashboardReport feature enabled. Starting data collection." -ScriptName $ScriptName -LogPath $LogPath

# Load shared feature config values
$CfgDomains             = if ($FeatureConfig.Domains)                    { $FeatureConfig.Domains }                    else { @() }
$InbuiltSafes           = if ($FeatureConfig.InbuiltSafes)               { $FeatureConfig.InbuiltSafes }               else { @() }
$MigSafeKeywords        = if ($FeatureConfig.MigratedSafeKeywords)       { $FeatureConfig.MigratedSafeKeywords }       else { @() }
$PersSafeRegex          = $FeatureConfig.PersonalSafePattern
$MigPlatKeywords        = if ($FeatureConfig.MigratedPlatformKeywords)   { $FeatureConfig.MigratedPlatformKeywords }   else { @() }
$ExcludeFailedPlatforms = if ($FeatureConfig.FailedAccountExcludePlatforms) { $FeatureConfig.FailedAccountExcludePlatforms } else { @() }
$AutoOnboardedSafes     = if ($FeatureConfig.AutoOnboardedSafes)         { $FeatureConfig.AutoOnboardedSafes }         else { @() }
$AutoOnboardedPattern   = if ($FeatureConfig.AutoOnboardedPattern)       { $FeatureConfig.AutoOnboardedPattern }       else { "" }
$PendingDiscNames       = if ($FeatureConfig.PendingDiscoveredFilterNames) { $FeatureConfig.PendingDiscoveredFilterNames } else { @() }
$TrackedFailedAccounts  = if ($FeatureConfig.TrackedFailedAccounts)      { $FeatureConfig.TrackedFailedAccounts }      else { @() }

# ------------------------
# Login
# ------------------------
$Credential = Get-SchedulerCredential -CCPConfig $config.CCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
Write-Log -Message "Connecting to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
$null = Connect-CyberArkApi -BaseUrl $BaseUrl -Credential $Credential -ScriptName $ScriptName -LogPath $LogPath

try {
    # ---- Cache & output file paths ----
    $TodayStr           = Get-Date -Format "yyyyMMdd"
    $timestamp          = Get-Date -Format "yyyyMMdd_HHmmss"
    $rawAccsCache       = Join-Path $ExportDir "RawCache_Accounts_$TodayStr.csv"
    $rawPlatsCache      = Join-Path $ExportDir "RawCache_Platforms_$TodayStr.csv"
    $rawSafesCache      = Join-Path $ExportDir "RawCache_Safes_$TodayStr.csv"
    $rawPendingDiscCache= Join-Path $ExportDir "RawCache_PendingDiscovered_$TodayStr.csv"

    $invFile        = Join-Path $ExportDir "DashboardInventoryDetails_$timestamp.csv"
    $safesFile      = Join-Path $ExportDir "DashboardSafesDetails_$timestamp.csv"
    $platsFile      = Join-Path $ExportDir "DashboardPlatformsDetails_$timestamp.csv"
    $failFile       = Join-Path $ExportDir "DashboardFailedAccountsDetails_$timestamp.csv"
    $pendingDiscFile= Join-Path $ExportDir "DashboardDiscoveryPendingDetails_$timestamp.csv"
    $summaryFile    = Join-Path $ExportDir "DashboardCounts_$timestamp.csv"
    $discFile       = Join-Path $ExportDir "DashboardDiscoveryOnboardedDetails_$timestamp.csv"
    $comparisonFile = Join-Path $ExportDir "DashboardFailedComparison_$timestamp.csv"
    $failCompXls    = Join-Path $ExportDir "DashboardFailedComparison_$timestamp.xls"

    # ================================================================
    # Step 1: Fetch Raw Data
    # ================================================================
    $RawAccounts         = Get-RawAccounts          -BaseUrl $BaseUrl -CachePath $rawAccsCache       -ScriptName $ScriptName -LogPath $LogPath
    $RawPendingDiscovered= Get-RawPendingDiscovered  -BaseUrl $BaseUrl -CachePath $rawPendingDiscCache -ScriptName $ScriptName -LogPath $LogPath
    $RawPlatforms        = Get-RawPlatforms          -BaseUrl $BaseUrl -CachePath $rawPlatsCache      -ScriptName $ScriptName -LogPath $LogPath
    $RawSafes            = Get-RawSafes              -BaseUrl $BaseUrl -CachePath $rawSafesCache      -ScriptName $ScriptName -LogPath $LogPath

    # ================================================================
    # Step 2: Analytics
    # ================================================================
    $invResult = Invoke-InventoryAnalytics `
        -RawAccounts          $RawAccounts `
        -CfgDomains           $CfgDomains `
        -InbuiltSafes         $InbuiltSafes `
        -AutoOnboardedSafes   $AutoOnboardedSafes `
        -AutoOnboardedPattern $AutoOnboardedPattern `
        -InvFile              $invFile `
        -DiscFile             $discFile `
        -ScriptName           $ScriptName -LogPath $LogPath

    $pendResult = Invoke-DiscoveryPendingAnalytics `
        -RawPendingDiscovered $RawPendingDiscovered `
        -PendingDiscNames     $PendingDiscNames `
        -PendingDiscFile      $pendingDiscFile `
        -ScriptName           $ScriptName -LogPath $LogPath

    $failResult = Invoke-FailedAccountsAnalytics `
        -BaseUrl                $BaseUrl `
        -ExcludeFailedPlatforms $ExcludeFailedPlatforms `
        -TrackedFailedAccounts  $TrackedFailedAccounts `
        -FailFile               $failFile `
        -ScriptName             $ScriptName -LogPath $LogPath

    $compResult = Invoke-FailureComparison `
        -FilteredFailedAccounts $failResult.FilteredFailedAccounts `
        -BaseOutputDir          $BaseOutputDir `
        -TodayStr               $TodayStr `
        -ComparisonFile         $comparisonFile `
        -FailCompXls            $failCompXls `
        -ScriptName             $ScriptName -LogPath $LogPath

    $platResult = Invoke-PlatformsAnalytics `
        -RawPlatforms      $RawPlatforms `
        -MigPlatKeywords   $MigPlatKeywords `
        -InUsePlatformIds  $invResult.InUsePlatformIds `
        -PlatsFile         $platsFile `
        -ScriptName        $ScriptName -LogPath $LogPath

    $safeResult = Invoke-SafesAnalytics `
        -RawSafes        $RawSafes `
        -InbuiltSafes    $InbuiltSafes `
        -MigSafeKeywords $MigSafeKeywords `
        -PersSafeRegex   $PersSafeRegex `
        -InUseSafeNames  $invResult.InUseSafeNames `
        -SafesFile       $safesFile `
        -ScriptName      $ScriptName -LogPath $LogPath

    # ================================================================
    # Step 3: Build Summary
    # ================================================================
    $SummaryRows = Build-SummaryRows `
        -TotalAccounts           $invResult.InventoryExport.Count `
        -DomainAccountsCount     $invResult.DomainAccountsCount `
        -FailedAccountsCount     $failResult.FailedAccountsCount `
        -DiscoveryOnboardedCount $invResult.DiscoveryOnboardedCount `
        -DiscoveryPendingCount   $pendResult.DiscoveryPendingCount `
        -TrackedFailures         $failResult.TrackedFailures `
        -SharedSafesCount        $safeResult.SharedSafesCount `
        -PersonalSafesCount      $safeResult.PersonalSafesCount `
        -MigratedSharedSafes     $safeResult.MigratedSharedSafes `
        -ActivePlatformsCount    $platResult.ActivePlatformsCount `
        -MigratedPlatformsCount  $platResult.MigratedPlatformsCount `
        -InUsePlatformsCount     $invResult.InUsePlatformIds.Keys.Count `
        -FixedCount              $compResult.FixedCount `
        -NewCount                $compResult.NewCount `
        -ExistingCount           $compResult.ExistingCount

    $SummaryRows | Export-Csv -Path $summaryFile -NoTypeInformation

    # ================================================================
    # Step 4: SharePoint Excel Update
    # ================================================================
    $SpConfig = $FeatureConfig.SharePoint
    if ($null -ne $SpConfig -and $SpConfig.EnableSharePointUpload) {
        try {
            Update-SharePointDashboard `
                -SharePointConfig    $SpConfig `
                -SummaryRows         $SummaryRows `
                -ExportDir           $ExportDir `
                -FallbackCredential  $Credential `
                -ManualLogin:$ManualLogin `
                -ScriptName          $ScriptName `
                -LogPath             $LogPath `
                -GlobalCCPUrl        $config.CCP.Url
        }
        catch {
            Write-Log -Message "SharePoint automation failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    else {
        Write-Log -Message "SharePoint Automation is disabled or not configured." -ScriptName $ScriptName -LogPath $LogPath
    }

    # ================================================================
    # Step 5: Email Notification
    # ================================================================
    $sendEmail = -not $ManualLogin
    if ($ManualLogin) {
        Write-Log -Message "ManualLogin detected. Prompting for email notification..." -ScriptName $ScriptName -LogPath $LogPath
        $choice = Read-Host "Do you want to send the dashboard report via email? (Y/N)"
        if ($choice -ieq "Y" -or $choice -ieq "Yes") { $sendEmail = $true }
    }

    if ($sendEmail) {
        if ($config.Email -and $config.Email.SmtpServer -and $config.Email.To) {
            try {
                $filesToZip = @($invFile, $safesFile, $platsFile, $failFile, $comparisonFile, $failCompXls, $summaryFile, $discFile, $pendingDiscFile)
                Send-DashboardEmail `
                    -EmailConfig    $config.Email `
                    -SummaryRows    $SummaryRows `
                    -FilesToZip     $filesToZip `
                    -FailCompXls    $failCompXls `
                    -ExportDir      $ExportDir `
                    -TodayStr       $TodayStr `
                    -Timestamp      $timestamp `
                    -RootPath       $FeatureRoot `
                    -BaseOutputDir  $BaseOutputDir `
                    -ScriptName     $ScriptName `
                    -LogPath        $LogPath
            }
            catch {
                Write-Log -Message "Failed to send email notification: $_" -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
            }
        }
        else {
            Write-Log -Message "Email configuration missing in config.json. Skipping notification." -Level "WARNING" -ScriptName $ScriptName -LogPath $LogPath
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
