# ============================================================================
# MODULE: Login.psm1
# DESCRIPTION: Authentication module for CyberArk CLI (CyberArk, LDAP, and SAML)
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
        Authenticates to CyberArk using CyberArk, LDAP, or SAML authentication.
    .PARAMETER LDAP
        Use LDAP authentication instead of standard CyberArk.
    .PARAMETER SAML
        Use SAML authentication instead of standard CyberArk.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [switch]$LDAP,
        [switch]$SAML,
        [switch]$CCP
    )

    $cfg = Get-CACConfig

    # Initialize SSL bypass if configured (for dev/test environments)
    Initialize-CACSSLBypass

    if (-not $SAML) {
        # ========================================
        # STANDARD/LDAP/CCP AUTHENTICATION FLOW
        # ========================================
        $authType = if ($LDAP) { "LDAP" } elseif ($CCP) { "CCP" } else { "CyberArk" }
        
        $username = $null
        $password = $null
        $baseUrl = $cfg.PVWAURL.TrimEnd('/')

        if ($CCP) {
            Write-Log "Retrieving credentials from CCP..." "INFO"
            try {
                $query = "Safe=$($cfg.CCP.Safe);Object=$($cfg.CCP.Object)"
                $ccpUri = "$($cfg.CCP.Url)?AppID=$($cfg.CCP.AppId)&Query=$query"
                
                $ccpResp = Invoke-RestMethod -Uri $ccpUri -Method Get -ErrorAction Stop
                $username = $ccpResp.UserName
                $password = $ccpResp.Content
                Write-Log "Credentials retrieved for user: $username" "SUCCESS"
            }
            catch {
                Write-Log "CCP Retrieval Failed: $($_.Exception.Message)" "ERROR"
                return $false
            }
        }
        else {
            $result = Show-CACLoginForm -PVWAURL $cfg.PVWAURL
            if (-not $result) { return $false }

            if ([string]::IsNullOrWhiteSpace($result.Url)) {
                Write-Log "PVWA URL cannot be empty." "ERROR"
                return $false
            }
            $baseUrl = $result.Url.TrimEnd('/')
            $username = $result.Username
            $password = $result.Password
        }

        $pvwaBase = "$baseUrl/PasswordVault"
        $loginType = if ($LDAP) { "LDAP" } else { "CyberArk" }
        $loginUrl = "$pvwaBase/api/Auth/$loginType/Logon"

        Write-Log "Attempting $loginType login to $loginUrl" "INFO"

        try {
            # Build credentials body
            $body = @{
                username          = $username
                password          = $password
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
            Initialize-CACSession -BaseURI $pvwaBase -Token $token -User $username
            
            # Store login method for auto-relogin
            $global:CACLoginMethod = $authType

            Write-Log "$authType Login Successful!" "SUCCESS"
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
            
            # Store login method for auto-relogin
            $global:CACLoginMethod = "SAML"
            
            # ========================================
            # DEBUG: Attempt to get username via multiple methods
            # ========================================
            
            # Method 1: Parse username from SAML Response (NameID)
            Write-Host ""
            Write-Host "===== DEBUG: Extracting Username from SAML =====" -ForegroundColor Magenta
            try {
                # Decode the SAMLResponse (it's Base64 encoded)
                $samlXmlBytes = [System.Convert]::FromBase64String($authResult.SAMLResponse)
                $samlXml = [System.Text.Encoding]::UTF8.GetString($samlXmlBytes)
                
                Write-Host "SAML Response decoded. Length: $($samlXml.Length) chars" -ForegroundColor Gray
                Write-Log "SAML XML decoded successfully" "DEBUG"
                
                # Parse as XML
                $xml = [xml]$samlXml
                
                # Try to find NameID (username is usually here)
                $namespaceManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $namespaceManager.AddNamespace("saml", "urn:oasis:names:tc:SAML:2.0:assertion")
                $namespaceManager.AddNamespace("saml2", "urn:oasis:names:tc:SAML:2.0:assertion")
                
                $nameIdNode = $xml.SelectSingleNode("//saml:NameID", $namespaceManager)
                if (-not $nameIdNode) {
                    $nameIdNode = $xml.SelectSingleNode("//saml2:NameID", $namespaceManager)
                }
                if (-not $nameIdNode) {
                    # Try without namespace
                    $nameIdNode = $xml.SelectSingleNode("//*[local-name()='NameID']")
                }
                
                if ($nameIdNode -and $nameIdNode.InnerText) {
                    $samlUserName = $nameIdNode.InnerText.Trim()
                    Write-Host "SAML NameID found: $samlUserName" -ForegroundColor Green
                    Write-Log "SAML NameID: $samlUserName" "SUCCESS"
                    $global:CACApiSession.User = $samlUserName
                }
                else {
                    Write-Host "SAML NameID not found in response" -ForegroundColor Yellow
                    Write-Log "NameID node not found in SAML response" "WARN"
                    
                    # Debug: Show available elements
                    $allElements = $xml.SelectNodes("//*[local-name()='NameID' or local-name()='Subject' or local-name()='Attribute']")
                    Write-Host "Found $($allElements.Count) potential identity elements" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "SAML parsing failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "SAML parsing error: $($_.Exception.Message)" "ERROR"
            }
            
            # Method 2: Try PIMServices API (legacy, may not work)
            Write-Host ""
            Write-Host "===== DEBUG: Trying PIMServices API =====" -ForegroundColor Magenta
            try {
                Write-Host "Calling: /WebServices/PIMServices.svc/User/" -ForegroundColor Gray
                $userInfo = Invoke-CACAPIRequest -Method GET -Endpoint "/WebServices/PIMServices.svc/User/"
                
                Write-Host "PIMServices Response Type: $($userInfo.GetType().Name)" -ForegroundColor Gray
                Write-Host "PIMServices Response: $($userInfo | ConvertTo-Json -Depth 3 -Compress)" -ForegroundColor Gray
                Write-Log "PIMServices User API response received" "DEBUG"
                
                # Extract username from response (handle different response structures)
                if ($userInfo) {
                    $userName = if ($userInfo.UserName) { $userInfo.UserName } 
                    elseif ($userInfo.username) { $userInfo.username }
                    elseif ($userInfo.User) { $userInfo.User }
                    elseif ($userInfo.user) { $userInfo.user }
                    else { $null }
                    
                    if ($userName) {
                        $global:CACApiSession.User = $userName
                        Write-Host "Username from PIMServices: $userName" -ForegroundColor Green
                        Write-Log "Logged in as: $userName" "SUCCESS"
                    }
                    else {
                        Write-Host "PIMServices returned data but no username field found" -ForegroundColor Yellow
                        Write-Log "User info retrieved but username field not found. Response: $($userInfo | ConvertTo-Json -Compress)" "WARN"
                    }
                }
                else {
                    Write-Host "PIMServices returned null/empty" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "PIMServices API failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "Could not fetch username from PIMServices: $($_.Exception.Message)" "WARN"
            }
            
            Write-Host "=========================================" -ForegroundColor Magenta
            Write-Host ""
            
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
