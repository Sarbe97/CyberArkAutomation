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
        
        # Handle both OrderedDictionary (psPAS 7.x) and PSCustomObject
        $baseURIValue = $null
        $webSessionValue = $null
        
        if ($session -is [System.Collections.IDictionary]) {
            Write-Log "Session is Dictionary type - using key access" "DEBUG"
            $baseURIValue = $session['BaseURI']
            $webSessionValue = $session['WebSession']
        }
        else {
            Write-Log "Session is Object type - using property access" "DEBUG"
            $baseURIValue = $session.BaseURI
            $webSessionValue = $session.WebSession
        }
        
        Write-Log "  BaseURI: $baseURIValue" "DEBUG"
        Write-Log "  WebSession: $(if ($webSessionValue) { 'Present' } else { 'NULL' })" "DEBUG"
        
        # Validate BaseURI
        if ($null -eq $baseURIValue -or [string]::IsNullOrWhiteSpace($baseURIValue)) {
            Write-Log "CRITICAL: BaseURI is NULL or empty!" "ERROR"
            Write-Log "Session may not be properly initialized. Try logging in again." "ERROR"
            throw "Session BaseURI is null. Session may not be properly initialized."
        }
        
        # Convert Uri to string if needed and trim
        $baseURI = $baseURIValue.ToString().TrimEnd('/')
        
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
            WebSession  = $webSessionValue
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
