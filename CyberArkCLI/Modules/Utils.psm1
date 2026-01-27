# ============================================================================
# MODULE: Utils.psm1
# DESCRIPTION: Logging and utility functions for CyberArk CLI
# ============================================================================

# Script-scope log file path
$Script:LogFile = $null

function Initialize-CACLogging {
    [CmdletBinding()]
    param(
        [string]$LogDir = "$PSScriptRoot/../Logs",
        [string]$Prefix = "CAC"
    )

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $Script:LogFile = Join-Path $LogDir "${Prefix}_${timestamp}.log"
    
    Write-Log "Logging initialized: $Script:LogFile" "INFO"
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false)]
        [string]$CustomLogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Determine log file
    $targetLog = if ($CustomLogFile) { $CustomLogFile } else { $Script:LogFile }

    # Write to log file if available
    if ($targetLog) {
        try {
            Add-Content -Path $targetLog -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # Console output with colors
    $color = switch ($Level) {
        "DEBUG" { "Gray" }
        "INFO" { "White" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        default { "White" }
    }

    # Only show non-debug messages on console (unless verbose)
    if ($Level -ne "DEBUG" -or $VerbosePreference -eq "Continue") {
        Write-Host $logEntry -ForegroundColor $color
    }
}

function Convert-CACTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $UnixTimestamp
    )

    process {
        if ($null -eq $UnixTimestamp -or $UnixTimestamp -eq 0) {
            return "N/A"
        }

        try {
            # Handle both seconds and milliseconds
            if ($UnixTimestamp -gt 9999999999) {
                $UnixTimestamp = $UnixTimestamp / 1000
            }
            return [DateTimeOffset]::FromUnixTimeSeconds($UnixTimestamp).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            return "Invalid"
        }
    }
}

function Get-CACOutputDir {
    param(
        [string]$SubFolder = ""
    )

    $baseDir = "$PSScriptRoot/../Output"
    $targetDir = if ($SubFolder) { Join-Path $baseDir $SubFolder } else { $baseDir }

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    return (Resolve-Path $targetDir).Path
}

# ============================================================
# Send Email Notification
# ============================================================
function Get-CACMailConfig {
    <#
    .SYNOPSIS
        Gets mail configuration from config.json (Mail object).
    #>
    [CmdletBinding()]
    param()

    $config = Get-CACConfig
    
    if ($null -eq $config.Mail) {
        Write-Log "Mail configuration not found in config.json" "WARN"
        return $null
    }

    return $config.Mail
}

function Send-CACEmail {
    <#
    .SYNOPSIS
        Sends an email using SMTP settings from config.json (Mail object).
    .PARAMETER To
        Recipient email address.
    .PARAMETER Subject
        Email subject line.
    .PARAMETER Body
        Email body content (HTML supported).
    .PARAMETER CC
        CC recipients (array of email addresses). If not provided, uses DefaultCC from config.
    .PARAMETER Attachments
        Array of file paths to attach to the email.
    .PARAMETER IsHtml
        If true, sends email as HTML. Default: true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$To,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [string[]]$CC = $null,

        [string[]]$Attachments = $null,

        [bool]$IsHtml = $true
    )

    Write-Log "Sending email to: $To" "DEBUG"

    try {
        # Load mail config from main config.json
        $mailConfig = Get-CACMailConfig
        
        if ($null -eq $mailConfig) {
            throw "Mail configuration not found. Please configure 'Mail' section in config.json"
        }

        # Validate SMTP settings
        if ([string]::IsNullOrWhiteSpace($mailConfig.SmtpServer)) {
            throw "Mail.SmtpServer not configured in config.json"
        }
        if ([string]::IsNullOrWhiteSpace($mailConfig.SmtpFrom)) {
            throw "Mail.SmtpFrom not configured in config.json"
        }

        $smtpParams = @{
            From       = $mailConfig.SmtpFrom
            To         = $To
            Subject    = $Subject
            Body       = $Body
            SmtpServer = $mailConfig.SmtpServer
            BodyAsHtml = $IsHtml
        }

        # Add optional port
        if ($mailConfig.SmtpPort) {
            $smtpParams["Port"] = $mailConfig.SmtpPort
        }

        # Add SSL if configured
        if ($mailConfig.SmtpUseSSL -eq $true) {
            $smtpParams["UseSsl"] = $true
        }

        # Add CC - use provided CC or default from config
        $ccList = if ($CC -and $CC.Count -gt 0) { $CC } elseif ($mailConfig.DefaultCC) { @($mailConfig.DefaultCC) } else { $null }
        if ($ccList -and $ccList.Count -gt 0) {
            $smtpParams["Cc"] = $ccList
            Write-Log "CC recipients: $($ccList -join ', ')" "DEBUG"
        }

        # Add attachments if provided
        if ($Attachments -and $Attachments.Count -gt 0) {
            $validAttachments = @()
            foreach ($attachment in $Attachments) {
                if (Test-Path $attachment) {
                    $validAttachments += $attachment
                    Write-Log "Attaching file: $attachment" "DEBUG"
                }
                else {
                    Write-Log "Attachment not found: $attachment" "WARN"
                }
            }
            if ($validAttachments.Count -gt 0) {
                $smtpParams["Attachments"] = $validAttachments
            }
        }

        Send-MailMessage @smtpParams -ErrorAction Stop

        Write-Log "Email sent successfully to: $To" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to send email to $To : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

Export-ModuleMember -Function Initialize-CACLogging, Write-Log, Convert-CACTimestamp, Get-CACOutputDir, Get-CACMailConfig, Send-CACEmail
