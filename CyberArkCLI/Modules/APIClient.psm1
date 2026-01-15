function Invoke-CACAPIRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PUT", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $false)]
        [hashtable]$Body
    )

    Write-Log "Started Invoke-CACAPIRequest() - Method: $Method, Endpoint: $Endpoint" "DEBUG"

    try {
        $session = Get-PASSession

        if (-not $session) {
            Write-Log "PAS session not available. Not logged in." "ERROR"
            throw "Not logged in. Please login first."
        }

        Write-Log "PAS session found. BaseURI: $($session.BaseURI)" "DEBUG"

        $baseURI = $session.BaseURI.TrimEnd('/')
        
        # Ensure Endpoint has a leading slash if not present
        if (-not $Endpoint.StartsWith("/")) {
            $Endpoint = "/$Endpoint"
        }

        $fullURL = "$baseURI$Endpoint"

        Write-Log "Calling API: $fullURL" "DEBUG"

        $requestParams = @{
            Uri         = $fullURL
            Method      = $Method
            WebSession  = $session.WebSession
            ContentType = "application/json"
            ErrorAction = "Stop"
        }

        if ($Body) {
            $requestParams["Body"] = $Body | ConvertTo-Json -Depth 10
            Write-Log "Request body size: $($requestParams['Body'].Length) bytes" "DEBUG"
        }

        $response = Invoke-RestMethod @requestParams

        Write-Log "API request successful." "DEBUG"

        return $response
    }
    catch {
        Write-Log "Error in Invoke-CACAPIRequest(): $($_.Exception.Message)" "ERROR"
        throw $_.Exception
    }
}

Export-ModuleMember -Function Invoke-CACAPIRequest
