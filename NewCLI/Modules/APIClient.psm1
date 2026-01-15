# ============================================================================
# MODULE: APIClient.psm1
# DESCRIPTION: Central API client for CyberArk REST API calls
# ============================================================================

# Force TLS 1.2
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
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
        $errorMessage = $_.Exception.Message
        
        # Try to extract more details from the response
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                
                if ($responseBody) {
                    $errorMessage = "$errorMessage - $responseBody"
                }
            }
            catch { }
        }

        Write-Log "API Error: $errorMessage" "ERROR"
        throw $errorMessage
    }
}

# ============================================================================
# HELPER FUNCTIONS FOR COMMON OPERATIONS
# ============================================================================

function Invoke-CACGetRequest {
    <#
    .SYNOPSIS
        Shorthand for GET requests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    return Invoke-CACAPIRequest -Method GET -Endpoint $Endpoint
}

function Invoke-CACPostRequest {
    <#
    .SYNOPSIS
        Shorthand for POST requests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $false)]
        [object]$Body
    )

    return Invoke-CACAPIRequest -Method POST -Endpoint $Endpoint -Body $Body
}

function Invoke-CACDeleteRequest {
    <#
    .SYNOPSIS
        Shorthand for DELETE requests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    return Invoke-CACAPIRequest -Method DELETE -Endpoint $Endpoint
}

Export-ModuleMember -Function Initialize-CACSession, Get-CACSession, Test-CACSession, Clear-CACSession, 
Invoke-CACAPIRequest, Invoke-CACGetRequest, Invoke-CACPostRequest, Invoke-CACDeleteRequest
