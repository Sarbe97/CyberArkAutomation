# ============================================================
# Scheduler Utilities
# Common functions shared across all Scheduler scripts
# ============================================================

# ------------------------
# Logging Function
# ------------------------
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    # Ensure Logs directory exists
    $logDir = Split-Path -Parent $LogPath
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$ScriptName] [$Level] $Message"
    
    # Write to console and log file
    $logEntry | Tee-Object -FilePath $LogPath -Append
}

# ------------------------
# Get Credential from CCP
# ------------------------
function Get-CCPCredential {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$CCPConfig,

        [string]$ScriptName = "Unknown",
        [string]$LogPath
    )

    try {
        $uri = "$($CCPConfig.Url)?AppID=$($CCPConfig.AppId)&Safe=$($CCPConfig.Safe)"
        
        if ($LogPath) {
            Write-Log -Message "Retrieving credential from CCP" -ScriptName $ScriptName -LogPath $LogPath
        }

        $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop

        return New-Object PSCredential (
            $resp.UserName,
            (ConvertTo-SecureString $resp.Content -AsPlainText -Force)
        )
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "CCP credential retrieval failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
        throw
    }
}

# ------------------------
# REST API Call Wrapper
# ------------------------
function Invoke-CyberArkApi {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [pscredential]$Credential,

        [ValidateSet("Get", "Post", "Put", "Delete")]
        [string]$Method = "Get",

        [object]$Body = $null
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Credential  = $Credential
        ErrorAction = "Stop"
    }

    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 10
        $params.ContentType = "application/json"
    }

    Invoke-RestMethod @params
}

# ------------------------
# Template Processing
# ------------------------
function Get-TemplateContent {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [string]$TemplatesPath = (Join-Path $PSScriptRoot "Templates")
    )

    # Find template file (supports .html, .tmpl, .txt)
    $templateFile = Get-ChildItem -Path $TemplatesPath -Filter "$TemplateName.*" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $templateFile) {
        throw "Template '$TemplateName' not found in $TemplatesPath"
    }

    $content = Get-Content -Path $templateFile.FullName -Raw

    # Replace all {{placeholder}} with values from Data hashtable
    foreach ($key in $Data.Keys) {
        $placeholder = "{{$key}}"
        $content = $content -replace [regex]::Escape($placeholder), $Data[$key]
    }

    return $content
}

# ------------------------
# Send Email
# ------------------------
function Send-SchedulerEmail {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$EmailConfig,

        [switch]$IsHtml,

        [string]$ScriptName = "Scheduler",
        [string]$LogPath
    )

    try {
        $mailParams = @{
            SmtpServer = $EmailConfig.SmtpServer
            From       = $EmailConfig.From
            To         = $EmailConfig.To
            Subject    = $Subject
            Body       = $Body
        }

        if ($IsHtml) {
            $mailParams.BodyAsHtml = $true
        }

        Send-MailMessage @mailParams

        if ($LogPath) {
            Write-Log -Message "Email sent successfully: $Subject" -ScriptName $ScriptName -LogPath $LogPath
        }

        return $true
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "Email sending failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
        return $false
    }
}

# ------------------------
# Send Email with Attachments
# ------------------------
function Send-SchedulerEmailWithAttachment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$EmailConfig,

        [string[]]$Attachments,

        [switch]$IsHtml,

        [string]$ScriptName = "Scheduler",
        [string]$LogPath
    )

    try {
        $mailParams = @{
            SmtpServer = $EmailConfig.SmtpServer
            From       = $EmailConfig.From
            To         = $EmailConfig.To
            Subject    = $Subject
            Body       = $Body
        }

        if ($IsHtml) {
            $mailParams.BodyAsHtml = $true
        }

        if ($Attachments -and $Attachments.Count -gt 0) {
            # Filter only existing files
            $validAttachments = $Attachments | Where-Object { Test-Path $_ }
            if ($validAttachments.Count -gt 0) {
                $mailParams.Attachments = $validAttachments
            }
            if ($LogPath) {
                Write-Log -Message "Attaching $($validAttachments.Count) file(s)" -ScriptName $ScriptName -LogPath $LogPath
            }
        }

        Send-MailMessage @mailParams

        if ($LogPath) {
            Write-Log -Message "Email sent successfully: $Subject" -ScriptName $ScriptName -LogPath $LogPath
        }

        return $true
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "Email sending failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
        return $false
    }
}
