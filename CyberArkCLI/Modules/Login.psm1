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
        # we complete the SAML authentication manually and then set up the psPAS session
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
            $authResponse = Invoke-WebRequest `
                -Uri $apiLogonUrl `
                -Method Post `
                -ContentType "application/x-www-form-urlencoded" `
                -Body $body `
                -WebSession $authResult.WebSession `
                -UseBasicParsing
            
            Write-Log "Auth response status: $($authResponse.StatusCode)" "DEBUG"
            
            # Extract session token
            $CyberArkLogonResult = $authResponse.Content.Trim('"')
            
            if ([string]::IsNullOrWhiteSpace($CyberArkLogonResult)) {
                throw "No session token received from CyberArk"
            }
            
            Write-Log "Session token received. Length: $($CyberArkLogonResult.Length)" "SUCCESS"
            
            # Add Authorization header to WebSession (this is how psPAS stores the token)
            $authResult.WebSession.Headers["Authorization"] = [string]$CyberArkLogonResult
            
            Write-Log "==========================================" "DEBUG"
            Write-Log "Setting up psPAS session:" "DEBUG"
            Write-Log "  BaseURI: $Uri" "DEBUG"
            Write-Log "  Token Length: $($CyberArkLogonResult.Length)" "DEBUG"
            Write-Log "==========================================" "DEBUG"
            
            # Create session object that matches psPAS internal structure
            $sessionObject = [PSCustomObject]@{
                BaseURI            = [System.Uri]$Uri
                ApiURI             = $null
                WebSession         = $authResult.WebSession
                StartTime          = Get-Date
                ElapsedTime        = $null
                LastCommand        = $null
                LastCommandTime    = $null
                LastCommandResults = $null
                User               = $null
                ExternalVersion    = [System.Version]"0.0"
            }
            
            # Use Set-PASSession to properly inject the session into psPAS's internal state
            # This ensures Get-PASSession will return our SAML session
            Write-Log "Injecting SAML session into psPAS using Set-PASSession..." "DEBUG"
            try {
                Set-PASSession -Session $sessionObject
                Write-Log "Set-PASSession succeeded - psPAS session initialized!" "SUCCESS"
            }
            catch {
                Write-Log "Set-PASSession failed: $($_.Exception.Message)" "ERROR"
                Write-Log "Falling back to manual WebSession storage" "WARN"
            }
            
            # Store in our global variable for backward compatibility
            $global:CACSession = $sessionObject
            $global:CACSessionToken = $CyberArkLogonResult
            
            Write-Log "Session setup complete" "DEBUG"
            
            # Verify session with direct API call (most reliable test)
            Write-Log "Verifying session with direct API call..." "DEBUG"
            try {
                # Legacy API endpoint - returns XML, not JSON
                $verifyUrl = "$Uri/WebServices/PIMServices.svc/User"
                Write-Log "Verification URL: $verifyUrl" "DEBUG"
                
                $verifyResponse = Invoke-WebRequest -Uri $verifyUrl -Method Get -WebSession $authResult.WebSession -UseBasicParsing
                
                if ($verifyResponse.StatusCode -eq 200) {
                    Write-Log "Session verified via direct API call! HTTP $($verifyResponse.StatusCode)" "SUCCESS"
                    
                    # Try to extract username from XML response
                    try {
                        $xmlContent = [xml]$verifyResponse.Content
                        $userName = $xmlContent.User.UserName
                        if ($userName) {
                            Write-Log "Logged in as: $userName" "SUCCESS"
                            $global:CACSession.User = $userName
                        }
                    }
                    catch {
                        Write-Log "Could not parse user info from response (non-critical)" "DEBUG"
                    }
                }
            }
            catch {
                Write-Log "Direct API verification failed: $($_.Exception.Message)" "WARN"
                Write-Log "Session token may still be valid - some features will work" "WARN"
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
