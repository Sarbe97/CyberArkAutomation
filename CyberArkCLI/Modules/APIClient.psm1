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
        if (-not $global:CACSession) {
            Write-Log "CACSession not available" "ERROR"
            throw "Not logged in. Please login first."
        }

        $baseURL = $global:CACSession.BaseURI
        $fullURL = "$baseURL$Endpoint"

        Write-Log "Calling API: $fullURL" "DEBUG"

        $headers = @{
            "Authorization" = $global:CACSession.WebSession.Headers.Authorization
            "Content-Type"  = "application/json"
        }

        $requestParams = @{
            Uri             = $fullURL
            Method          = $Method
            Headers         = $headers
            WebSession      = $global:CACSession.WebSession
            SkipCertificateCheck = $true
        }

        if ($Body) {
            $requestParams["Body"] = $Body | ConvertTo-Json -Depth 10
            Write-Log "Request body size: $($requestParams['Body'].Length) bytes" "DEBUG"
        }

        $response = Invoke-RestMethod @requestParams -ErrorAction Stop

        Write-Log "API request successful. Response type: $($response.GetType().Name)" "DEBUG"

        return $response
    }
    catch {
        Write-Log "Error in Invoke-CACAPIRequest(): $($_.Exception.Message)" "ERROR"
        throw $_.Exception
    }
}

Export-ModuleMember -Function Invoke-CACAPIRequest
