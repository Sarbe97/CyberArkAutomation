<#
.SYNOPSIS
    Shift Handover Report Automation (Orchestrator)

.DESCRIPTION
    Automates the shift handover email generation process from a centralized SharePoint
    Excel workbook tracking application teams (e.g. SailPoint, Idera, Ping).
    
    Modular architecture:
    - Modules/SHR_Logging.ps1       : Logging and retention cleanup
    - Modules/SHR_SharePoint.ps1    : Microsoft Graph API client & SharePoint downloader
    - Modules/SHR_DataProcessor.ps1 : Excel reader, categorization, and metrics engine
    - Modules/SHR_Email.ps1         : HTML template renderer and SMTP email dispatcher
    - Templates/ShiftHandoverReport.html : Responsive executive HTML email template
    - config.json                   : Master configuration

.PARAMETER LocalExcelPath
    Optional local path to a tracker Excel file. When specified, skips the SharePoint download
    and uses the local file directly. Ideal for offline testing and verification.

.PARAMETER ReportDate
    Optional report date string in 'yyyy-MM-dd' format. Defaults to today's date.

.PARAMETER SkipEmail
    Switch to generate local HTML output and log without sending an email notification.

.PARAMETER SendEmailTo
    Optional array of email addresses to override the recipient list defined in config.

.PARAMETER ConfigPath
    Optional custom path to the JSON configuration file. Defaults to 'config.json'
    in the script directory.

.PARAMETER ForceDownload
    Switch to force re-downloading the Excel tracker from SharePoint even if a local cache exists.

.EXAMPLE
    .\ShiftHandoverReport.ps1
    # Automatically resolves 1st Shift (~11:30 AM) or 2nd Shift (~7:30 PM) based on config.json

.EXAMPLE
    .\ShiftHandoverReport.ps1 -ReportDate "2026-09-17"

.EXAMPLE
    .\ShiftHandoverReport.ps1 -LocalExcelPath ".\ShiftHandover_Tracker.xlsx" -SkipEmail
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$LocalExcelPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ReportDate = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipEmail,

    [Parameter(Mandatory = $false)]
    [string[]]$SendEmailTo = @(),

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload
)

# -----------------------------------------------------------------------------
# 1. Environment & Path Resolution
# -----------------------------------------------------------------------------
$ScriptName   = "ShiftHandoverReport"
$ScriptRoot   = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$ModulesDir   = Join-Path $ScriptRoot "Modules"
$TemplatesDir = Join-Path $ScriptRoot "Templates"

# Resolve Config Path (default: config.json in script root)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptRoot "config.json"
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at: $ConfigPath"
    exit 1
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse JSON configuration file ($ConfigPath): $($_.Exception.Message)"
    exit 1
}

# Resolve Effective Dates and Timestamps
if ([string]::IsNullOrWhiteSpace($ReportDate)) {
    $ReportDate = (Get-Date).ToString("yyyy-MM-dd")
}
$TodayCompact = (Get-Date).ToString("yyyyMMdd")
$FileTimestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# Setup Log and Output Directories
$LogDirName    = if ($config.Output -and $config.Output.LogDirectory) { $config.Output.LogDirectory } else { "Logs" }
$OutputDirName = if ($config.Output -and $config.Output.Directory) { $config.Output.Directory } else { "Output" }

$LogDir        = Join-Path $ScriptRoot $LogDirName
$BaseOutputDir = Join-Path $ScriptRoot $OutputDirName
$DailyOutputDir= Join-Path $BaseOutputDir $TodayCompact

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $DailyOutputDir)) { New-Item -ItemType Directory -Path $DailyOutputDir -Force | Out-Null }

$LogPath = Join-Path $LogDir "$ScriptName-$TodayCompact.log"

# -----------------------------------------------------------------------------
# 2. Import Feature Modules (Self-Contained in ./Modules)
# -----------------------------------------------------------------------------
$moduleFiles = @(
    (Join-Path $ModulesDir "SHR_Logging.ps1"),
    (Join-Path $ModulesDir "SHR_SharePoint.ps1"),
    (Join-Path $ModulesDir "SHR_DataProcessor.ps1"),
    (Join-Path $ModulesDir "SHR_Email.ps1")
)

foreach ($mod in $moduleFiles) {
    if (-not (Test-Path $mod)) {
        Write-Error "Required module not found: $mod"
        exit 1
    }
    . $mod
}

# -----------------------------------------------------------------------------
# 3. Main Execution Pipeline
# -----------------------------------------------------------------------------
try {
    Write-Log -Message "=================================================================" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Shift Handover Report Automation Started (Report Date: $ReportDate)" -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "Configuration loaded from: $ConfigPath" -ScriptName $ScriptName -LogPath $LogPath

    # Step A: Identify Shift Name (Determined automatically by config.json and execution time)
    $EffectiveShiftName = Get-CurrentShiftName -ShiftsConfig $config.Shifts
    Write-Log -Message "Active Shift Identified from config: '$EffectiveShiftName'" -ScriptName $ScriptName -LogPath $LogPath

    # Step B: Acquire Excel Tracker Workbook (SharePoint Download or Local File)
    $WorkingExcelPath = Get-ShiftHandoverWorkbook `
        -Config           $config `
        -LocalExcelPath   $LocalExcelPath `
        -DailyOutputDir   $DailyOutputDir `
        -ForceDownload:$ForceDownload `
        -ScriptRoot       $ScriptRoot `
        -ScriptName       $ScriptName `
        -LogPath          $LogPath

    # Step C: Parse Excel Sheets & Aggregate Shift Metrics
    $MetricsResult = Get-ShiftHandoverMetrics `
        -WorkbookPath     $WorkingExcelPath `
        -Config           $config `
        -ReportDate       $ReportDate `
        -ScriptName       $ScriptName `
        -LogPath          $LogPath

    # Step D: Render Responsive HTML Email Report
    $RenderedHtml = Build-ShiftHandoverHtml `
        -MetricsResult    $MetricsResult `
        -Config           $config `
        -ShiftName        $EffectiveShiftName `
        -ReportDate       $ReportDate `
        -TemplatesDir     $TemplatesDir `
        -ScriptName       $ScriptName `
        -LogPath          $LogPath

    # Step E: Save Local HTML Report & Metrics CSV to Output Directory
    $safeShiftName  = $EffectiveShiftName -replace '\s','_'
    $outputHtmlFile = Join-Path $DailyOutputDir "ShiftHandoverReport_${safeShiftName}_$FileTimestamp.html"
    Set-Content -Path $outputHtmlFile -Value $RenderedHtml -Encoding UTF8
    Write-Log -Message "Generated HTML report saved: $outputHtmlFile" -ScriptName $ScriptName -LogPath $LogPath

    $outputCsvFile  = Join-Path $DailyOutputDir "ShiftHandover_Metrics_${safeShiftName}_$FileTimestamp.csv"
    $MetricsResult.Applications | Export-Csv -Path $outputCsvFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Exported metrics CSV to: $outputCsvFile" -ScriptName $ScriptName -LogPath $LogPath

    # Step F: Dispatch Shift Email Notification
    if ($SkipEmail) {
        Write-Log -Message "-SkipEmail switch specified. Skipping email dispatch." -ScriptName $ScriptName -LogPath $LogPath
    }
    else {
        Send-ShiftHandoverEmail `
            -EmailConfig             $config.Email `
            -HtmlBody                $RenderedHtml `
            -ShiftName               $EffectiveShiftName `
            -ReportDate              $ReportDate `
            -RecipientOverride       $SendEmailTo `
            -WorkbookAttachmentPath  $WorkingExcelPath `
            -ScriptName              $ScriptName `
            -LogPath                 $LogPath
    }

    # Step G: Retention Cleanup
    $retentionDays = if ($config.Output -and $config.Output.RetentionDays) { [int]$config.Output.RetentionDays } else { 30 }
    Invoke-RetentionCleanup `
        -LogDir           $LogDir `
        -BaseOutputDir    $BaseOutputDir `
        -RetentionDays    $retentionDays `
        -ScriptName       $ScriptName `
        -LogPath          $LogPath

    Write-Log -Message "Shift Handover Report Execution Completed Successfully." -ScriptName $ScriptName -LogPath $LogPath
    Write-Log -Message "=================================================================" -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}
catch {
    Write-Log -Message "Shift Handover Report Execution Failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}
