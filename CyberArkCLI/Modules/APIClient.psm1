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

        $baseURL = $session.BaseURI
        $fullURL = "$baseURL$Endpoint"

        Write-Log "Calling API: $fullURL" "DEBUG"

        $requestParams = @{
            Uri             = $fullURL
            Method          = $Method
            WebSession      = $session.WebSession
            ContentType     = "application/json"
            SkipCertificateCheck = $true
        }

        if ($Body) {
            $requestParams["Body"] = $Body | ConvertTo-Json -Depth 10
            Write-Log "Request body size: $($requestParams['Body'].Length) bytes" "DEBUG"
        }

        $response = Invoke-WebRequest @requestParams -ErrorAction Stop

        Write-Log "API request successful. Status: $($response.StatusCode)" "DEBUG"

        $content = $response.Content | ConvertFrom-Json

        return $content
    }
    catch {
        Write-Log "Error in Invoke-CACAPIRequest(): $($_.Exception.Message)" "ERROR"
        throw $_.Exception
    }
}

Export-ModuleMember -Function Invoke-CACAPIRequest
