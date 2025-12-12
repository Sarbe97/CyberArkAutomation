# - Supports Daily or Size-based rotation
# - Detailed logging for each operation
# - Rotates log files by adding timestamp suffix
# - Compresses each rotated log into a ZIP file
# - Deletes logs older than N retention days (per directory)
# - Sends email alerts (SMTP config inside function)
# - Continues processing even if errors occur
# - Creates Backup folder INSIDE EACH log folder
# - Creates script execution logs

# ==============================
#          CONFIG
# ==============================

$Environment = "DEV"   # DEV / UAT / PROD

# Rotation mode:  "Daily" or "Size"
$RotationMode = "Daily"

# Threshold for size-based rotation (MB)
$SizeThresholdMB = 20

# Log folders (each gets its own Backup folder)
$LogPaths = @(
    "C:\CyberArk\Logs",
    "C:\Ss_Folder\WS\store-front\store-front-node\logs"
)

# Retention for compressed logs
$RetentionDays = 30

# Timestamp pattern
$TimeStamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# ==============================
#            LOGGER
# ==============================

# Script log directory
$ScriptLogDir = "C:\LogBackupScriptLogs"
if (!(Test-Path $ScriptLogDir)) {
    New-Item -ItemType Directory -Path $ScriptLogDir | Out-Null
}

# Script log file
$ScriptLog = Join-Path $ScriptLogDir "LogBackup-$TimeStamp.log"

function Write-Log {
    param([string]$Message)

    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Line = "$Timestamp : $Message"

    Add-Content -Path $ScriptLog -Value $Line
    Write-Host $Line
}

# ==============================
#       FUNCTIONS
# ==============================

function Send-BackupAlert {
    param(
        [string]$Message,
        [string]$Level = "ERROR"
    )

    # SMTP CONFIG INSIDE FUNCTION
    $Environment = "DEV"
    $SmtpServer = "smtp.example.local"
    $EmailFrom = "log-backup@example.com"
    $EmailTo = "admin@example.com"
    $EmailSubject = "$Environment - Log Backup Status"

    $FullSubject = "$EmailSubject - $Level"

    Send-MailMessage `
        -To $EmailTo `
        -From $EmailFrom `
        -Subject $FullSubject `
        -Body $Message `
        -SmtpServer $SmtpServer `
        -Priority High

    Write-Log "Email alert sent: $Message"
}


function Should-RotateLog {
    param([System.IO.FileInfo]$File)

    if ($RotationMode -eq "Daily") {
        return $true
    }

    if ($RotationMode -eq "Size") {
        $SizeMB = [math]::Round($File.Length / 1MB, 2)

        if ($SizeMB -ge $SizeThresholdMB) {
            return $true
        }
        else {
            Write-Log "Skipping (size below threshold $SizeThresholdMB MB): $($File.FullName) ($SizeMB MB)"
            return $false
        }
    }

    return $false
}


function Rotate-And-CompressLog {
    param(
        [string]$FilePath,
        [string]$BackupFolder
    )

    try {
        Write-Log "Processing file: $FilePath"

        $Dir = Split-Path $FilePath -Parent
        $File = Split-Path $FilePath -Leaf
        $Name = [IO.Path]::GetFileNameWithoutExtension($File)
        $Ext = [IO.Path]::GetExtension($File)

        # Rotated file
        $RotatedFile = Join-Path $Dir "$Name-$TimeStamp$Ext"

        # Rotate
        Rename-Item -Path $FilePath -NewName $RotatedFile
        Write-Log "Rotated to: $RotatedFile"

        # Compress
        $ZipTarget = Join-Path $BackupFolder "$Name-$TimeStamp.zip"
        Compress-Archive -Path $RotatedFile -DestinationPath $ZipTarget -Force
        Write-Log "Compressed to: $ZipTarget"

        # Remove rotated file
        Remove-Item $RotatedFile -Force
        Write-Log "Removed intermediate rotated file: $RotatedFile"

        return $true
    }
    catch {
        $ErrMsg = "❌ ERROR rotating: $FilePath | $_"
        Write-Log $ErrMsg
        Send-BackupAlert $ErrMsg
        return $false
    }
}


function Clear-OldArchives {
    param([string]$BackupFolder)

    Write-Log "Checking for old archives in: $BackupFolder"

    $OldFiles = Get-ChildItem -Path $BackupFolder -Filter *.zip -File |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) }

    foreach ($File in $OldFiles) {
        Write-Log "Deleting old archive: $($File.FullName)"
        Remove-Item $File.FullName -Force
    }
}

# ==============================
#       MAIN EXECUTION
# ==============================

Write-Log "===== Log Backup Started ($Environment) ====="

foreach ($LogPath in $LogPaths) {

    if (!(Test-Path $LogPath)) {
        Write-Log "Skipping missing log path: $LogPath"
        continue
    }

    Write-Log "Processing directory: $LogPath"

    # Backup folder per log directory
    $BackupFolder = Join-Path $LogPath "Backup"
    if (!(Test-Path $BackupFolder)) {
        New-Item -ItemType Directory -Path $BackupFolder | Out-Null
        Write-Log "Created backup folder: $BackupFolder"
    }

    # Get all log files
    $Logs = Get-ChildItem -Path $LogPath -Filter *.log -File -Recurse

    foreach ($Log in $Logs) {

        if (Should-RotateLog -File $Log) {
            Rotate-And-CompressLog -FilePath $Log.FullName -BackupFolder $BackupFolder | Out-Null
        }
    }

    # Apply retention
    Clear-OldArchives -BackupFolder $BackupFolder
}

Write-Log "===== Log Backup Completed Successfully ====="
Write-Host "`nScript log saved to: $ScriptLog"
