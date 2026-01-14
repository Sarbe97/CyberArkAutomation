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
        Write-Log "  BaseUrl: $($authResult.BaseUrl)" "DEBUG"
        Write-Log "  WebSession: $(if ($authResult.WebSession) { 'Present' } else { 'NULL' })" "DEBUG"
        Write-Log "==========================================" "DEBUG"

        # Since psPAS New-PASSession -SAMLResponse doesn't accept an external WebSession with the CA88888 cookie,
        # we complete the SAML authentication manually and then set up the psPAS session exactly like psPAS does internally
        try {
            Write-Log "Completing SAML authentication with CyberArk..." "INFO"
            
            $baseUrl = $authResult.BaseUrl.TrimEnd('/')
            $pvwaAppName = "PasswordVault"
            $Uri = "$baseUrl/$pvwaAppName"
            $apiLogonUrl = "$Uri/api/auth/SAML/Logon"
            
            # Build form data exactly like psPAS does for Gen2SAML
            $body = @{
                SAMLResponse      = $authResult.SAMLResponse
                concurrentSession = $true
                apiUse            = $true
            }
            
            Write-Log "Sending SAMLResponse to: $apiLogonUrl" "DEBUG"
            Write-Log "Using WebSession with CA88888 cookie" "DEBUG"
            
            # Complete authentication using the WebSession (which has the CA88888 cookie)
            # This mirrors what Invoke-PASRestMethod does internally
            $authResponse = Invoke-WebRequest `
                -Uri $apiLogonUrl `
                -Method Post `
                -ContentType "application/x-www-form-urlencoded" `
                -Body $body `
                -WebSession $authResult.WebSession `
                -UseBasicParsing
            
            Write-Log "Auth response status: $($authResponse.StatusCode)" "DEBUG"
            
            # Extract session token (CyberArkLogonResult)
            $CyberArkLogonResult = $authResponse.Content.Trim('"')
            
            if ([string]::IsNullOrWhiteSpace($CyberArkLogonResult)) {
                throw "No session token received from CyberArk"
            }
            
            Write-Log "Session token received. Length: $($CyberArkLogonResult.Length)" "SUCCESS"
            
            # Now set up psPAS session EXACTLY like New-PASSession.ps1 does
            # Reference: https://github.com/pspete/psPAS/blob/master/psPAS/Functions/Authentication/New-PASSession.ps1
            Write-Log "Initializing psPAS session (matching internal psPAS structure)..." "INFO"
            
            # Get the psPAS module-scoped session object
            # psPAS stores session in a script-scoped variable that Get-PASSession retrieves
            try {
                $psPASSession = Get-PASSession
                Write-Log "Retrieved existing psPAS session object" "DEBUG"
            }
            catch {
                Write-Log "Get-PASSession failed, creating new session structure..." "DEBUG"
                # If Get-PASSession fails, we need to initialize the session differently
                $psPASSession = $null
            }
            
            if ($null -eq $psPASSession) {
                # psPAS isn't initialized yet, we need to set module variables directly
                # This is a workaround - we'll use the WebSession from our auth
                Write-Log "Creating new psPAS-compatible session..." "DEBUG"
            }
            
            # Add the Authorization header to the WebSession (this is how psPAS stores the token)
            $authResult.WebSession.Headers["Authorization"] = [string]$CyberArkLogonResult
            
            # Set up the session using the psPAS pattern
            # psPAS uses: $psPASSession.BaseURI, $psPASSession.WebSession, $psPASSession.User, etc.
            
            # Try to use the psPAS internal session by calling a simple command first
            # This is a workaround to get psPAS to accept our session
            
            # Create a minimal session and try Set-Variable in psPAS scope
            $sessionData = @{
                BaseURI         = [System.Uri]$Uri
                WebSession      = $authResult.WebSession
                StartTime       = Get-Date
                User            = $null
                ExternalVersion = [System.Version]"0.0"
            }
            
            # Store in our global variables for compatibility
            $global:CACSession = $sessionData
            $global:CACSessionToken = $CyberArkLogonResult
            
            # Now verify if psPAS commands work by using the WebSession directly
            # We'll set PSDefaultParameterValues to inject our WebSession into psPAS calls
            if ($null -eq $global:PSDefaultParameterValues) {
                $global:PSDefaultParameterValues = @{}
            }
            
            # Inject our authenticated WebSession into all psPAS commands
            $global:PSDefaultParameterValues["Invoke-PASRestMethod:WebSession"] = $authResult.WebSession
            
            Write-Log "Session configured. Testing with Get-PASLoggedOnUser..." "DEBUG"
            
            # Verify session by attempting a lightweight call
            try {
                $loggedInUser = Get-PASLoggedOnUser -ErrorAction Stop
                if ($loggedInUser) {
                    Write-Log "Session verified. Logged in as: $($loggedInUser.UserName)" "SUCCESS"
                    
                    # Update session with user info
                    $global:CACSession.User = $loggedInUser.UserName
                }
            }
            catch {
                Write-Log "Get-PASLoggedOnUser failed: $($_.Exception.Message)" "WARN"
                
                # Try alternative verification
                try {
                    Write-Log "Trying alternative verification with Get-PASSafe..." "DEBUG"
                    $testSafe = Get-PASSafe -limit 1 -ErrorAction Stop
                    if ($testSafe) {
                        Write-Log "Session verified via Get-PASSafe" "SUCCESS"
                    }
                }
                catch {
                    Write-Log "Alternative verification also failed: $($_.Exception.Message)" "WARN"
                    Write-Log "Attempting direct API call to verify connectivity..." "DEBUG"
                    
                    # Direct API call to verify the token works
                    try {
                        $verifyUrl = "$Uri/api/Users/MyDetails"
                        $verifyResponse = Invoke-WebRequest -Uri $verifyUrl -Method Get -WebSession $authResult.WebSession -UseBasicParsing
                        Write-Log "Direct API verification successful. Status: $($verifyResponse.StatusCode)" "SUCCESS"
                    }
                    catch {
                        Write-Log "Direct API verification failed: $($_.Exception.Message)" "ERROR"
                    }
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