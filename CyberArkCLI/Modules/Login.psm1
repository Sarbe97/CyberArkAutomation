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

        # Since psPAS New-PASSession doesn't support passing a WebSession with the CA88888 cookie,
        # we need to complete the SAML authentication manually and then set up the psPAS session
        try {
            Write-Log "Completing SAML authentication with CyberArk..." "INFO"
            
            $baseUrl = $authResult.BaseUrl
            $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"
            
            # Build form data for the final authentication
            $body = @{
                SAMLResponse      = $authResult.SAMLResponse
                concurrentSession = "true"
                apiUse            = "true"
            }
            
            Write-Log "Sending SAMLResponse to: $apiLogonUrl" "DEBUG"
            Write-Log "Using WebSession with CA88888 cookie" "DEBUG"
            
            # Complete authentication using the WebSession (which has the CA88888 cookie)
            $authResponse = Invoke-WebRequest `
                -Uri $apiLogonUrl `
                -Method Post `
                -ContentType "application/x-www-form-urlencoded" `
                -Body $body `
                -WebSession $authResult.WebSession `
                -UseBasicParsing
            
            Write-Log "Auth response status: $($authResponse.StatusCode)" "DEBUG"
            
            # Extract session token
            $sessionToken = $authResponse.Content.Trim('"')
            
            if ([string]::IsNullOrWhiteSpace($sessionToken)) {
                throw "No session token received from CyberArk"
            }
            
            Write-Log "Session token received. Length: $($sessionToken.Length)" "SUCCESS"
            
            # Now set up psPAS session using Use-PASSession
            Write-Log "Initializing psPAS session with Use-PASSession..." "INFO"
            
            # Create session object that psPAS expects
            $sessionObject = [PSCustomObject]@{
                BaseURI            = [System.Uri]$baseUrl
                User               = $null  # Will be populated by psPAS
                ExternalVersion    = $null
                WebSession         = $authResult.WebSession
                StartTime          = Get-Date
                ElapsedTime        = $null
                LastCommand        = $null
                LastCommandTime    = $null
                LastCommandResults = $null
            }
            
            # Add the Authorization header to the WebSession
            $authResult.WebSession.Headers["Authorization"] = $sessionToken
            
            # Try Use-PASSession first (modern psPAS)
            try {
                Use-PASSession -Session $sessionObject
                Write-Log "psPAS session established via Use-PASSession" "SUCCESS"
            }
            catch {
                Write-Log "Use-PASSession failed, trying alternative approach..." "WARN"
                
                # Alternative: Set the session variables that psPAS uses internally
                $Script:psPASSession = $sessionObject
                
                # Also set global defaults so psPAS cmdlets work
                if ($null -eq $global:PSDefaultParameterValues) {
                    $global:PSDefaultParameterValues = @{}
                }
                $global:PSDefaultParameterValues["*-PAS*:WebSession"] = $authResult.WebSession
            }
            
            # Store in our global variable too
            $global:CACSession = $sessionObject
            $global:CACSessionToken = $sessionToken
            
            # Verify session by attempting a lightweight call
            try {
                Write-Log "Verifying session..." "DEBUG"
                $loggedInUser = Get-PASLoggedOnUser -ErrorAction Stop
                if ($loggedInUser) {
                    Write-Log "Session verified. Logged in as: $($loggedInUser.UserName)" "SUCCESS"
                }
            }
            catch {
                Write-Log "Session verification with Get-PASLoggedOnUser failed: $($_.Exception.Message)" "WARN"
                
                # Try alternative verification
                try {
                    Write-Log "Trying alternative verification with Get-PASSafe..." "DEBUG"
                    $testSafe = Get-PASSafe -limit 1 -ErrorAction Stop
                    Write-Log "Session verified via Get-PASSafe" "SUCCESS"
                }
                catch {
                    Write-Log "Alternative verification also failed: $($_.Exception.Message)" "WARN"
                    Write-Log "Session may still be valid - attempting to continue" "WARN"
                }
            }
            
            Write-Log "SAML Login Complete." "SUCCESS"
            return $true
        }
        catch {
            Write-Log "==========================================" "ERROR"
            Write-Log "FAILED TO ESTABLISH SESSION" "ERROR"
            Write-Log "==========================================" "ERROR"
            Write-Log "Error Message: $($_.Exception.Message)" "ERROR"
            Write-Log "Error Type: $($_.Exception.GetType().FullName)" "ERROR"
            Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
            
            # Try to get response body for web exceptions
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseBody = $reader.ReadToEnd()
                    Write-Log "Response Body: $responseBody" "ERROR"
                    $reader.Close()
                }
                catch {}
            }
            
            if ($_.Exception.InnerException) {
                Write-Log "Inner Exception: $($_.Exception.InnerException.Message)" "ERROR"
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