# ============================================================================
# MODULE: Login.psm1
# DESCRIPTION: Authentication module for CyberArk CLI (Standard and SAML)
# ============================================================================

# Force TLS 1.2
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Dot-source the login form
$loginFormScript = Join-Path $PSScriptRoot "LoginForm.ps1"
if (-not (Test-Path $loginFormScript)) {
    throw "LoginForm.ps1 not found: $loginFormScript"
}
. $loginFormScript

function Invoke-CACLogin {
    <#
    .SYNOPSIS
        Authenticates to CyberArk using standard or SAML authentication.
    .PARAMETER SAML
        Use SAML authentication instead of standard.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [switch]$SAML
    )

    $cfg = Get-CACConfig

    if (-not $SAML) {
        # ========================================
        # STANDARD AUTHENTICATION FLOW
        # ========================================
        $result = Show-CACLoginForm -PVWAURL $cfg.PVWAURL
        if (-not $result) { return $false }

        if ([string]::IsNullOrWhiteSpace($result.Url)) {
            Write-Log "PVWA URL cannot be empty." "ERROR"
            return $false
        }

        # NOTE: PVWAURL must be configured manually in config.json

        $baseUrl = $result.Url.TrimEnd('/')
        $pvwaBase = "$baseUrl/PasswordVault"
        $loginUrl = "$pvwaBase/api/Auth/CyberArk/Logon"

        Write-Log "Attempting standard login to $loginUrl" "INFO"

        try {
            # Build credentials body
            $body = @{
                username          = $result.Username
                password          = $result.Password
                concurrentSession = $true
            } | ConvertTo-Json

            # Make login request
            $response = Invoke-RestMethod -Uri $loginUrl -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop

            # Response is the session token (string)
            $token = $response

            if ([string]::IsNullOrWhiteSpace($token)) {
                throw "No session token received from CyberArk"
            }

            # Initialize session
            Initialize-CACSession -BaseURI $pvwaBase -Token $token -User $result.Username

            Write-Log "Standard Login Successful!" "SUCCESS"
            return $true
        }
        catch {
            Write-Log "Login Failed: $($_.Exception.Message)" "ERROR"
            
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $respBody = $reader.ReadToEnd()
                    $reader.Close()
                    Write-Log "API Error Body: $respBody" "ERROR"
                }
                catch { }
            }
            return $false
        }
    }
    else {
        # ========================================
        # SAML AUTHENTICATION FLOW
        # ========================================
        Write-Log "Starting SAML Authentication Flow" "INFO"

        # Get PVWA URL
        $url = $null
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
            Write-Log "Using configured PVWA URL: $url" "INFO"
        }
        else {
            Write-Host "Please enter your CyberArk PVWA URL (e.g., https://cyberark.example.com)" -ForegroundColor Yellow
            $url = Read-Host "PVWA URL"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Log "PVWA URL cannot be empty." "ERROR"
            return $false
        }

        # NOTE: PVWAURL must be configured manually in config.json

        # Get SAMLResponse from helper function
        $authResult = Invoke-SAMLAuthentication -PVWAURL $url

        if ($null -eq $authResult -or [string]::IsNullOrEmpty($authResult.SAMLResponse)) {
            Write-Log "SAML Authentication returned null or empty SAMLResponse." "ERROR"
            return $false
        }

        Write-Log "SAMLResponse Length: $($authResult.SAMLResponse.Length)" "DEBUG"

        try {
            Write-Log "Completing SAML authentication with CyberArk..." "INFO"
            
            $baseUrl = $authResult.BaseUrl.TrimEnd('/')
            $pvwaBase = "$baseUrl/PasswordVault"
            $apiLogonUrl = "$pvwaBase/api/auth/SAML/Logon"
            
            # Build form data
            $body = @{
                SAMLResponse      = $authResult.SAMLResponse
                concurrentSession = $true
                apiUse            = $true
            }
            
            Write-Log "Sending SAMLResponse to: $apiLogonUrl" "DEBUG"
            
            # Complete authentication using the WebSession (which has the essential cookies)
            $authResponse = Invoke-WebRequest `
                -Uri $apiLogonUrl `
                -Method Post `
                -ContentType "application/x-www-form-urlencoded" `
                -Body $body `
                -WebSession $authResult.WebSession `
                -UseBasicParsing
            
            Write-Log "Auth response status: $($authResponse.StatusCode)" "DEBUG"
            
            # Extract session token
            $token = $authResponse.Content.Trim('"')
            
            if ([string]::IsNullOrWhiteSpace($token)) {
                throw "No session token received from CyberArk"
            }
            
            Write-Log "Session token received. Length: $($token.Length)" "SUCCESS"
            
            # Initialize session with WebSession (for cookies)
            Initialize-CACSession -BaseURI $pvwaBase -Token $token -WebSession $authResult.WebSession
            
            # Fetch username from API (SAML doesn't provide it directly)
            try {
                $userInfo = Invoke-CACAPIRequest -Method GET -Endpoint "/WebServices/PIMServices.svc/User"
                Write-Log "PIMServices User API response received" "DEBUG"
                
                # Extract username from response (handle different response structures)
                if ($userInfo) {
                    $userName = if ($userInfo.UserName) { $userInfo.UserName } 
                    elseif ($userInfo.username) { $userInfo.username }
                    else { $null }
                    
                    if ($userName) {
                        $global:CACApiSession.User = $userName
                        Write-Log "Logged in as: $userName" "SUCCESS"
                    }
                    else {
                        Write-Log "User info retrieved but username field not found. Response: $($userInfo | ConvertTo-Json -Compress)" "WARN"
                    }
                }
            }
            catch {
                Write-Log "Could not fetch username: $($_.Exception.Message)" "WARN"
            }
            
            Write-Log "SAML Login Complete!" "SUCCESS"
            return $true
        }
        catch {
            Write-Log "FAILED TO ESTABLISH SESSION" "ERROR"
            Write-Log "Error Message: $($_.Exception.Message)" "ERROR"
            
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                    Write-Log "Response Body: $responseBody" "ERROR"
                }
                catch { }
            }
            return $false
        }
    }
}

function Invoke-CACLogout {
    <#
    .SYNOPSIS
        Logs out from the current CyberArk session.
    #>
    [CmdletBinding()]
    param()

    try {
        if (Test-CACSession) {
            Write-Log "Logging out..." "INFO"
            
            $session = Get-CACSession
            $logoffUrl = "$($session.BaseURI)/api/Auth/Logoff"
            
            try {
                # Call logoff API
                Invoke-RestMethod -Uri $logoffUrl -Method POST -WebSession $session.WebSession -ErrorAction SilentlyContinue
            }
            catch {
                # Ignore logoff errors - we're clearing the session anyway
                Write-Log "Logoff API call failed (ignored): $($_.Exception.Message)" "DEBUG"
            }
        }

        # Clear local session
        Clear-CACSession

        Write-Log "Logged out successfully." "SUCCESS"
    }
    catch {
        Write-Log "Logout error: $($_.Exception.Message)" "WARN"
        # Still clear the session
        Clear-CACSession
    }
}

Export-ModuleMember -Function Invoke-CACLogin, Invoke-CACLogout
