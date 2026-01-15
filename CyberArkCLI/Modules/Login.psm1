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

        # --- NEW IMPLEMENTATION USING psPAS FUNCTION ---
        Write-Log "Attempting psPAS SAML Login using New-PASSession..." "INFO"
        try {
            # Using the standard psPAS SAML login function as requested
            # Note: This requires psPAS 3.0+ and assumes standard SAML flow 
            $null = New-PASSession -BaseURI $authResult.BaseUrl -SAMLResponse $authResult.SAMLResponse -ErrorAction Stop
             
            # Store session in global variable (New-PASSession sets it internally for the module, but we track it too)
            # psPAS usually handles the session internally, but if we need the object:
            $global:CACSession = Get-PASSession
             
            Write-Log "psPAS SAML Login Successful!" "SUCCESS"
            return $true
        }
        catch {
            Write-Log "psPAS SAML Login Failed: $($_.Exception.Message)" "ERROR"
            if ($_.Exception.InnerException) {
                Write-Log "Inner Exception: $($_.Exception.InnerException.Message)" "ERROR"
            }
            return $false
        }

        <#
        # --- PREVIOUS CUSTOM IMPLEMENTATION ---
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
            
            # Create session object that matches psPAS internal structure (must be PSCustomObject)
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
            
            # Store in our global variables
            $global:CACSession = $sessionObject
            $global:CACSessionToken = $CyberArkLogonResult
            
            # Try Use-PASSession to properly initialize psPAS module session
            Write-Log "Attempting Use-PASSession..." "DEBUG"
            $usePASSessionWorked = $false
            try {
                Use-PASSession -Session $sessionObject
                Write-Log "Use-PASSession succeeded!" "SUCCESS"
                $usePASSessionWorked = $true
            }
            catch {
                Write-Log "Use-PASSession failed: $($_.Exception.Message)" "WARN"
                Write-Log "This is expected - psPAS doesn't fully support external SAML sessions" "INFO"
            }
            
            # Since Use-PASSession likely failed, inject session data via PSDefaultParameterValues
            # This allows direct API calls to work even if psPAS cmdlets have issues
            Write-Log "Setting up PSDefaultParameterValues for session injection..." "DEBUG"
            
            if ($null -eq $global:PSDefaultParameterValues) {
                $global:PSDefaultParameterValues = @{}
            }
            
            # Inject into multiple psPAS internal functions
            $global:PSDefaultParameterValues["Invoke-PASRestMethod:WebSession"] = $authResult.WebSession
            $global:PSDefaultParameterValues["Invoke-PASRestMethod:BaseURI"] = [System.Uri]$Uri
            
            # Also inject for Get-PAS* commands that might use BaseURI parameter directly
            $global:PSDefaultParameterValues["Get-PAS*:BaseURI"] = [System.Uri]$Uri
            
            Write-Log "Session injection complete" "DEBUG"
            
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
        #>
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
