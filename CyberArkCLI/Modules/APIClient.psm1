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
        Write-Log "=================== API CLIENT DEBUG ===================" "DEBUG"
        $session = Get-PASSession
        
        Write-Log "Get-PASSession returned: $(if ($session) { 'Object' } else { 'NULL' })" "DEBUG"

        if (-not $session) {
            Write-Log "PAS session not available. Not logged in." "ERROR"
            throw "Not logged in. Please login first."
        }
        
        Write-Log "Session Type: $($session.GetType().FullName)" "DEBUG"
        Write-Log "Session Properties:" "DEBUG"
        Write-Log "  BaseURI: $($session.BaseURI) (Type: $($session.BaseURI.GetType().FullName))" "DEBUG"
        Write-Log "  WebSession: $(if ($session.WebSession) { 'Present' } else { 'NULL' })" "DEBUG"
        
        # Handle BaseURI whether it's a string or Uri object
        if ($null -eq $session.BaseURI) {
            Write-Log "CRITICAL: BaseURI is NULL!" "ERROR"
            throw "Session BaseURI is null. Session may not be properly initialized."
        }
        
        # Convert Uri to string if needed and trim
        $baseURI = $session.BaseURI.ToString().TrimEnd('/')
        
        Write-Log "Converted BaseURI: $baseURI" "DEBUG"
        Write-Log "=========================================================" "DEBUG"
        
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
