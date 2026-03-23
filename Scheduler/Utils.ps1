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
    
    # Write to console and log file (avoid pipeline leakage)
    Write-Host $logEntry
    $logEntry | Add-Content -Path $LogPath
}

# ------------------------
# Script-level session variable
# ------------------------
$script:CyberArkSession = $null

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
        # Build CCP URL with proper Query format: Safe=xxx;Object=xxx
        $query = "Safe=$($CCPConfig.Safe);Object=$($CCPConfig.Object)"
        $uri = "$($CCPConfig.Url)?AppID=$($CCPConfig.AppId)&Query=$query"
        
        if ($LogPath) {
            Write-Log -Message "Retrieving credential from CCP: $uri" -ScriptName $ScriptName -LogPath $LogPath
        }

        $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop

        # CCP returns: UserName ± Content (password)
        return @{
            Username = $resp.UserName
            Password = $resp.Content
        }
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "CCP credential retrieval failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
        throw
    }
}

# ------------------------
# CyberArk Logon (Get Token)
# ------------------------
function Connect-CyberArkApi {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Credential,

        [string]$ScriptName = "Unknown",
        [string]$LogPath
    )

    try {
        $loginUri = "$BaseUrl/PasswordVault/API/Auth/CyberArk/Logon"
        
        $body = @{
            username = $Credential.Username
            password = $Credential.Password
        } | ConvertTo-Json

        if ($LogPath) {
            Write-Log -Message "Logging in to CyberArk API..." -ScriptName $ScriptName -LogPath $LogPath
        }

        $response = Invoke-RestMethod -Uri $loginUri -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop

        # Response is the token string (quoted)
        $token = $response -replace '"', ''
        
        # Store session
        $script:CyberArkSession = @{
            BaseUrl    = $BaseUrl
            Token      = $token
            ScriptName = $ScriptName
            LogPath    = $LogPath
        }

        if ($LogPath) {
            Write-Log -Message "Successfully authenticated to CyberArk" -ScriptName $ScriptName -LogPath $LogPath
        }

        return $token
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "CyberArk logon failed: $_" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        }
        throw
    }
}

# ------------------------
# CyberArk Logoff
# ------------------------
function Disconnect-CyberArkApi {
    param (
        [string]$ScriptName = "Unknown",
        [string]$LogPath
    )

    if (-not $script:CyberArkSession) { return }

    try {
        $logoffUri = "$($script:CyberArkSession.BaseUrl)/PasswordVault/API/Auth/Logoff"
        $headers = @{ Authorization = $script:CyberArkSession.Token }
        $sName = $script:CyberArkSession.ScriptName
        $lPath = $script:CyberArkSession.LogPath

        Invoke-RestMethod -Uri $logoffUri -Method Post -Headers $headers -ErrorAction SilentlyContinue

        if ($lPath) {
            Write-Log -Message "Logged off from CyberArk" -ScriptName $sName -LogPath $lPath
        }
    }
    catch {
        if ($LogPath) {
            Write-Log -Message "Logoff warning: $_" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    finally {
        $script:CyberArkSession = $null
    }
}

# ------------------------
# REST API Call Wrapper (Token-based)
# ------------------------
function Invoke-CyberArkApi {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [ValidateSet("Get", "Post", "Put", "Delete")]
        [string]$Method = "Get",

        [object]$Body = $null
    )

    if (-not $script:CyberArkSession) {
        throw "CyberArk session not initialized. Call Connect-CyberArkApi first."
    }

    $headers = @{
        Authorization = $script:CyberArkSession.Token
    }

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $headers
        ContentType = "application/json"
        ErrorAction = "Stop"
    }

    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 10
    }

    if ($script:CyberArkSession.LogPath) {
        Write-Log -Message "API Request: [$Method] $Uri" -ScriptName $script:CyberArkSession.ScriptName -LogPath $script:CyberArkSession.LogPath
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
