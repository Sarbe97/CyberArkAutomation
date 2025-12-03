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
        if (-not $global:CACVaultAddress) {
            Write-Log "Vault address not configured" "ERROR"
            throw "Vault address not configured. Please login first."
        }

        if (-not $global:CACAuthToken) {
            Write-Log "Authentication token not available" "ERROR"
            throw "Authentication token not available. Please login first."
        }

        $baseURL = "https://$($global:CACVaultAddress)"
        $fullURL = "$baseURL$Endpoint"

        Write-Log "Calling API: $fullURL" "DEBUG"

        $headers = @{
            "Authorization" = $global:CACAuthToken
            "Content-Type"  = "application/json"
        }

        $requestParams = @{
            Uri             = $fullURL
            Method          = $Method
            Headers         = $headers
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
