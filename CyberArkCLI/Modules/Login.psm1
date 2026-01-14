# Login.psm1
Import-Module psPAS -ErrorAction Stop

# Force TLS 1.2
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

 
$loginFormScript = Join-Path $PSScriptRoot "LoginForm.ps1"
if (-not (Test-Path $loginFormScript)) {
    throw "LoginForm.ps1 not found: $loginFormScript"
}
. $loginFormScript   # <-- dot-source the UI function


function Invoke-CACLogin {
    [CmdletBinding()]
    param(
        [switch]$SAML
    )

    $cfg = Get-CACConfig

    if (-not $SAML) {
        # --- STANDARD FLOW ---
        $result = Show-CACLoginForm -PVWAURL $cfg.PVWAURL
        if (-not $result) { return $false }

        if ([string]::IsNullOrWhiteSpace($result.Url)) {
            Write-Host "PVWA URL cannot be empty." -ForegroundColor Red
            return $false
        }

        # Save URL if new
        Set-CACConfig -PVWAURL $result.Url

        # Build credentials
        $secure = ConvertTo-SecureString $result.Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($result.Username, $secure)

        try {
            $global:CACSession = New-PASSession -Credential $cred -BaseURI $result.Url
            Write-Host "Standard Login Successful!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Login Failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader $_.Exception.Response.GetResponseStream()
                    $respBody = $reader.ReadToEnd()
                    Write-Host "API Error Body: $respBody" -ForegroundColor DarkRed
                }
                catch {}
            }
            return $false
        }
    }
    else {
        # --- SAML FLOW ---
        Write-Log "Starting SAML Authentication Flow" "INFO"

        # Get PVWA URL
        $url = $null
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
            Write-Log "Using configured PVWA URL: $url" "INFO"
        }
        else {
            Write-Log "Please enter your CyberArk PVWA URL (e.g., https://cyberark.example.com)" "WARN"
            $url = Read-Host "PVWA URL"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Log "PVWA URL cannot be empty." "ERROR"
            return $false
        }

        # Save URL if new or changed
        if ($url -ne $cfg.PVWAURL) {
            Set-CACConfig -PVWAURL $url
        }

        # Get SAMLResponse from our helper function
        # This opens the browser for IdP authentication and returns the SAMLResponse
        $authResult = Invoke-SAMLAuthentication -PVWAURL $url

        if ($null -eq $authResult -or [string]::IsNullOrEmpty($authResult.SAMLResponse)) {
            Write-Log "SAML Authentication returned null or empty SAMLResponse." "ERROR"
            return $false
        }

        Write-Log "==========================================" "DEBUG"
        Write-Log "SAML Authentication Result Details:" "DEBUG"
        Write-Log "  SAMLResponse Length: $($authResult.SAMLResponse.Length)" "DEBUG"
        Write-Log "  SAMLResponse Preview: $($authResult.SAMLResponse.Substring(0, [Math]::Min(80, $authResult.SAMLResponse.Length)))..." "DEBUG"
        Write-Log "  BaseUrl: $($authResult.BaseUrl)" "DEBUG"
        Write-Log "  WebSession: $(if ($authResult.WebSession) { 'Present' } else { 'NULL' })" "DEBUG"
        if ($authResult.WebSession -and $authResult.WebSession.Cookies) {
            Write-Log "  WebSession Cookies Count: $($authResult.WebSession.Cookies.Count)" "DEBUG"
            foreach ($cookie in $authResult.WebSession.Cookies.GetCookies($authResult.BaseUrl)) {
                Write-Log "    Cookie: $($cookie.Name) = $($cookie.Value.Substring(0, [Math]::Min(20, $cookie.Value.Length)))..." "DEBUG"
            }
        }
        Write-Log "==========================================" "DEBUG"

        # Use psPAS native SAML authentication
        # This properly establishes the PASSession so all psPAS commands work
        try {
            Write-Log "Calling New-PASSession with following parameters:" "INFO"
            Write-Log "  -SAMLResponse: [Base64 string, length $($authResult.SAMLResponse.Length)]" "INFO"
            Write-Log "  -BaseURI: $($authResult.BaseUrl)" "INFO"
            Write-Log "  -concurrentSession: `$true" "INFO"
            if ($authResult.WebSession) {
                Write-Log "  -WebSession: [WebRequestSession with cookies]" "INFO"
            }
            
            # Call New-PASSession with WebSession if available
            if ($authResult.WebSession) {
                $global:CACSession = New-PASSession `
                    -SAMLResponse $authResult.SAMLResponse `
                    -BaseURI $authResult.BaseUrl `
                    -concurrentSession $true `
                    -WebSession $authResult.WebSession
            }
            else {
                $global:CACSession = New-PASSession `
                    -SAMLResponse $authResult.SAMLResponse `
                    -BaseURI $authResult.BaseUrl `
                    -concurrentSession $true
            }

            Write-Log "psPAS SAML session established successfully!" "SUCCESS"
            
            # Verify session by attempting a lightweight call
            try {
                Write-Log "Verifying session..." "DEBUG"
                $loggedInUser = Get-PASLoggedOnUser -ErrorAction SilentlyContinue
                if ($loggedInUser) {
                    Write-Log "Session verified. Logged in as: $($loggedInUser.UserName)" "SUCCESS"
                }
            }
            catch {
                Write-Log "Session verification call failed (non-fatal): $($_.Exception.Message)" "WARN"
            }
            
            Write-Log "SAML Login Complete." "SUCCESS"
            return $true
        }
        catch {
            Write-Log "==========================================" "ERROR"
            Write-Log "FAILED TO ESTABLISH psPAS SESSION" "ERROR"
            Write-Log "==========================================" "ERROR"
            Write-Log "Error Message: $($_.Exception.Message)" "ERROR"
            Write-Log "Error Type: $($_.Exception.GetType().FullName)" "ERROR"
            Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
            
            # Try to get more details from web exception
            if ($_.Exception.InnerException) {
                Write-Log "Inner Exception: $($_.Exception.InnerException.Message)" "ERROR"
            }
            
            # Check for common issues
            if ($_.Exception.Message -match "401|Unauthorized") {
                Write-Log "HINT: The SAMLResponse may have expired or is invalid. Please try again." "WARN"
            }
            elseif ($_.Exception.Message -match "hostname|URL") {
                Write-Log "HINT: Base URL issue. Please verify your PVWA URL is correct." "WARN"
            }
            elseif ($_.Exception.Message -match "parameter") {
                Write-Log "HINT: Parameter issue with New-PASSession. Check psPAS version supports -SAMLResponse." "WARN"
            }
            
            Write-Log "==========================================" "ERROR"
            return $false
        }
    }
}

function Invoke-CACLogout {
    try {
        if ($global:CACSession) {
            Write-Host "Logging out..." -ForegroundColor Yellow
            Close-PASSession
        }

        $global:CACSession = $null
        $global:CACSessionToken = $null

        Write-Host "Logged out successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Logout error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Invoke-CACLogin, Invoke-CACLogout