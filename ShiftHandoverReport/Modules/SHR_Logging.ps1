# =============================================================================
# SHR_Logging.ps1
# Self-contained logging and retention cleanup module for Shift Handover Report
# =============================================================================

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$ScriptName = "ShiftHandoverReport",
        [string]$LogPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$ScriptName] [$Level] $Message"

    $color = switch ($Level) {
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "Cyan" }
        default { "Green" }
    }
    Write-Host $logEntry -ForegroundColor $color

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        # Ensure parent directory exists
        $logDir = Split-Path -Parent $LogPath
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Thread-safe file append with retry loop
        for ($i = 1; $i -le 3; $i++) {
            try {
                $logEntry | Add-Content -Path $LogPath -ErrorAction Stop
                break
            }
            catch {
                if ($i -lt 3) { Start-Sleep -Milliseconds 150 }
            }
        }
    }
}

function Invoke-RetentionCleanup {
    param (
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$BaseOutputDir,
        [int]$RetentionDays = 30,
        [string]$ScriptName = "ShiftHandoverReport",
        [string]$LogPath
    )

    if ($RetentionDays -le 0) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Write-Log -Message "Starting retention cleanup (older than $RetentionDays days / $cutoff)..." -ScriptName $ScriptName -LogPath $LogPath

    # Cleanup logs
    if (Test-Path $LogDir) {
        $oldLogs = Get-ChildItem -Path $LogDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoff }
        foreach ($f in $oldLogs) {
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($oldLogs.Count -gt 0) {
            Write-Log -Message "Removed $($oldLogs.Count) log file(s) past retention." -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # Cleanup output subdirectories
    if (Test-Path $BaseOutputDir) {
        $oldDirs = Get-ChildItem -Path $BaseOutputDir -Directory | Where-Object { $_.LastWriteTime -lt $cutoff }
        foreach ($d in $oldDirs) {
            Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($oldDirs.Count -gt 0) {
            Write-Log -Message "Removed $($oldDirs.Count) output folder(s) past retention." -ScriptName $ScriptName -LogPath $LogPath
        }
    }
}
