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
        
        # Try to get psPAS session first
        $session = Get-PASSession -ErrorAction SilentlyContinue
        
        Write-Log "Get-PASSession returned: $(if ($session) { 'Object' } else { 'NULL' })" "DEBUG"
        
        # Handle both OrderedDictionary (psPAS 7.x) and PSCustomObject
        $baseURIValue = $null
        $webSessionValue = $null
        $usingFallback = $false
        
        if ($session) {
            Write-Log "Session Type: $($session.GetType().FullName)" "DEBUG"
            
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
        }
        
        # FALLBACK: If psPAS session is null or BaseURI is null, use global:CACSession
        if ($null -eq $session -or $null -eq $baseURIValue -or [string]::IsNullOrWhiteSpace($baseURIValue)) {
            Write-Log "psPAS session invalid - falling back to global:CACSession" "WARN"
            
            if ($null -eq $global:CACSession) {
                Write-Log "CRITICAL: Both psPAS session and global:CACSession are null!" "ERROR"
                throw "Not logged in. Please login first."
            }
            
            Write-Log "Using global:CACSession for API call" "INFO"
            $baseURIValue = $global:CACSession.BaseURI
            $webSessionValue = $global:CACSession.WebSession
            $usingFallback = $true
        }

        Write-Log "  BaseURI: $baseURIValue (Source: $(if ($usingFallback) { 'global:CACSession' } else { 'psPAS' }))" "DEBUG"
        Write-Log "  WebSession: $(if ($webSessionValue) { 'Present' } else { 'NULL' })" "DEBUG"
        
        # Final validation
        if ($null -eq $baseURIValue -or [string]::IsNullOrWhiteSpace($baseURIValue)) {
            Write-Log "CRITICAL: BaseURI is NULL or empty even after fallback!" "ERROR"
            throw "Session BaseURI is null. Please login again."
        }
        
        if ($null -eq $webSessionValue) {
            Write-Log "CRITICAL: WebSession is NULL!" "ERROR"
            throw "WebSession is null. Please login again."
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
