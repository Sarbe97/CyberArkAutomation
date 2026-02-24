# ============================================================================
# MODULE: APIClient.psm1
# DESCRIPTION: Central API client for CyberArk REST API calls
# ============================================================================

# Force TLS 1.2
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ============================================================================
# SSL CERTIFICATE BYPASS (for dev/test environments)
# ============================================================================

function Initialize-CACSSLBypass {
    <#
    .SYNOPSIS
        Bypasses SSL certificate validation if IgnoreSSLErrors is enabled in config.
    .DESCRIPTION
        WARNING: Only use in dev/test environments with self-signed certificates.
        This function checks config.json for IgnoreSSLErrors flag and disables
        certificate validation when set to true.
    #>
    [CmdletBinding()]
    param()

    try {
        $cfg = Get-CACConfig
        if ($cfg.IgnoreSSLErrors -eq $true) {
            # Check if already bypassed
            if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
                Add-Type @"
                    using System.Net;
                    using System.Security.Cryptography.X509Certificates;
                    public class TrustAllCertsPolicy : ICertificatePolicy {
                        public bool CheckValidationResult(
                            ServicePoint srvPoint, X509Certificate certificate,
                            WebRequest request, int certificateProblem) {
                            return true;
                        }
                    }
"@
            }
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            Write-Host "[WARNING] SSL certificate validation DISABLED (IgnoreSSLErrors=true)" -ForegroundColor Yellow
            Write-Log "SSL certificate validation bypassed (IgnoreSSLErrors=true)" "WARN"
        }
    }
    catch {
        # Config not loaded yet or IgnoreSSLErrors not set - skip silently
        Write-Log "Could not check IgnoreSSLErrors config: $($_.Exception.Message)" "DEBUG"
    }
}

# ============================================================================
# SESSION MANAGEMENT
# ============================================================================

# Global session state
$global:CACApiSession = @{
    BaseURI    = $null      # e.g., "https://pvwa.example.com/PasswordVault"
    Token      = $null      # Authorization token from login
    WebSession = $null      # WebRequestSession with cookies
    StartTime  = $null      # Session start time
    User       = $null      # Logged in user (if known)
}

function Initialize-CACSession {
    <#
    .SYNOPSIS
        Initialize the API session after successful authentication.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseURI,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter(Mandatory = $false)]
        [string]$User
    )

    $global:CACApiSession.BaseURI = $BaseURI.TrimEnd('/')
    $global:CACApiSession.Token = $Token
    $global:CACApiSession.StartTime = Get-Date
    $global:CACApiSession.User = $User

    if ($WebSession) {
        $global:CACApiSession.WebSession = $WebSession
        # Add Authorization header to WebSession
        $global:CACApiSession.WebSession.Headers["Authorization"] = $Token
    }
    else {
        # Create new WebSession with Authorization header
        $global:CACApiSession.WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $global:CACApiSession.WebSession.Headers["Authorization"] = $Token
    }

    Write-Log "Session initialized for $BaseURI" "SUCCESS"
}

function Get-CACSession {
    <#
    .SYNOPSIS
        Returns the current API session or $null if not logged in.
    #>
    [CmdletBinding()]
    param()

    if ($global:CACApiSession.Token) {
        return [PSCustomObject]@{
            BaseURI    = $global:CACApiSession.BaseURI
            Token      = $global:CACApiSession.Token
            WebSession = $global:CACApiSession.WebSession
            StartTime  = $global:CACApiSession.StartTime
            User       = $global:CACApiSession.User
        }
    }

    return $null
}

function Test-CACSession {
    <#
    .SYNOPSIS
        Tests if a valid session exists.
    #>
    [CmdletBinding()]
    param()

    return ($null -ne $global:CACApiSession.Token -and $null -ne $global:CACApiSession.BaseURI)
}

function Clear-CACSession {
    <#
    .SYNOPSIS
        Clears the current session (logout).
    #>
    [CmdletBinding()]
    param()

    $global:CACApiSession.BaseURI = $null
    $global:CACApiSession.Token = $null
    $global:CACApiSession.WebSession = $null
    $global:CACApiSession.StartTime = $null
    $global:CACApiSession.User = $null

    Write-Log "Session cleared" "DEBUG"
}

# ============================================================================
# CORE API REQUEST FUNCTION
# ============================================================================

function Invoke-CACAPIRequest {
    <#
    .SYNOPSIS
        Execute a REST API request to CyberArk.
    .DESCRIPTION
        Central function for all CyberArk API calls. Handles authentication headers,
        JSON serialization, and error handling.
    .PARAMETER Method
        HTTP method (GET, POST, PUT, DELETE, PATCH)
    .PARAMETER Endpoint
        API endpoint path (e.g., "/api/Accounts")
    .PARAMETER Body
        Optional request body (will be converted to JSON)
    .PARAMETER ContentType
        Content type (default: application/json)
    .EXAMPLE
        Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts?limit=10"
    .EXAMPLE
        Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts" -Body $accountData
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PUT", "DELETE", "PATCH")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $false)]
        [object]$Body,

        [Parameter(Mandatory = $false)]
        [string]$ContentType = "application/json"
    )

    Write-Log "API Request: $Method $Endpoint" "DEBUG"

    # Validate session
    if (-not (Test-CACSession)) {
        throw "Not logged in. Please login first."
    }

    # Build full URL
    $baseURI = $global:CACApiSession.BaseURI
    if (-not $Endpoint.StartsWith("/")) {
        $Endpoint = "/$Endpoint"
    }
    $fullURL = "$baseURI$Endpoint"

    Write-Log "Full URL: $fullURL" "DEBUG"

    # Build request parameters
    $requestParams = @{
        Uri         = $fullURL
        Method      = $Method
        WebSession  = $global:CACApiSession.WebSession
        ContentType = $ContentType
        ErrorAction = "Stop"
    }

    # Add body if provided
    if ($Body) {
        if ($Body -is [string]) {
            $requestParams["Body"] = $Body
        }
        else {
            $requestParams["Body"] = $Body | ConvertTo-Json -Depth 10
        }
        Write-Log "Request body: $($requestParams['Body'])" "DEBUG"
    }

    try {
        $response = Invoke-RestMethod @requestParams
        Write-Log "API request successful" "DEBUG"
        return $response
    }
    catch {
        $err = $_
        $ex = $_.Exception
        $errorMessage = $ex.Message
        $responseBody = $null

        # Try ErrorDetails first, fall back to reading the response stream
        if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
            $responseBody = $err.ErrorDetails.Message
        }
        elseif ($ex.Response) {
            try {
                $stream = $ex.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                }
            }
            catch { }
        }

        # Try to parse CyberArk JSON error payload (ErrorCode + ErrorMessage)
        $apiErrorCode = $null
        $apiErrorMessage = $null
        if ($responseBody) {
            try {
                $json = $responseBody | ConvertFrom-Json -ErrorAction Stop
                $apiErrorCode = $json.ErrorCode
                $apiErrorMessage = $json.ErrorMessage
            }
            catch { }
        }

        # Log the most descriptive message available
        if ($apiErrorCode -or $apiErrorMessage) {
            Write-Log "API Error: [$apiErrorCode] $apiErrorMessage" "ERROR"
        }
        elseif ($responseBody) {
            Write-Log "API Error: $responseBody" "ERROR"
        }
        else {
            Write-Log "API Error: $errorMessage" "ERROR"
        }

        # Throw with full detail appended to original exception message
        if ($responseBody) {
            $errorMessage = "$errorMessage - $responseBody"
        }
        throw $errorMessage
    }
}

# ============================================================================
# HELPER FUNCTIONS FOR COMMON OPERATIONS
# ============================================================================

function ConvertTo-CACResponseArray {
    <#
    .SYNOPSIS
        Converts various API response formats to a consistent array.
    .DESCRIPTION
        CyberArk API responses can return data in different formats:
        - { value: [...] } - Most list endpoints
        - { Users: [...] } - Users endpoint
        - [...] - Direct array
        - { ... } - Single object
        This function normalizes all these to a consistent array.
    .PARAMETER Response
        The API response object to convert.
    .PARAMETER PropertyName
        Optional property name to extract (e.g., "Users", "Accounts").
        If not specified, tries "value" first, then checks if response is array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Response,

        [Parameter(Mandatory = $false)]
        [string]$PropertyName
    )

    if ($null -eq $Response) {
        return @()
    }

    # If specific property name is provided, try that first
    if ($PropertyName -and $Response.$PropertyName) {
        return @($Response.$PropertyName)
    }

    # Try common property names
    if ($Response.value) {
        return @($Response.value)
    }
    if ($Response.Users) {
        return @($Response.Users)
    }
    if ($Response.Accounts) {
        return @($Response.Accounts)
    }

    # Check if response itself is an array
    if ($Response -is [array]) {
        return @($Response)
    }

    # Single object - wrap in array
    return @($Response)
}

Export-ModuleMember -Function Initialize-CACSession, Get-CACSession, Test-CACSession, Clear-CACSession, 
Invoke-CACAPIRequest, ConvertTo-CACResponseArray, Initialize-CACSSLBypass

