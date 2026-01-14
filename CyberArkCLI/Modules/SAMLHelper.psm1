# SAMLHelper.psm1
# SAML Authentication Helper for CyberArk
# Follows the PSMEasyConnect pattern for reliable SAML auth

function New-SAMLInteractive {
    <#
    .SYNOPSIS
        Opens a browser window for SAML authentication and captures the SAMLResponse.
    .PARAMETER LoginIDP
        The Identity Provider URL to navigate to.
    .OUTPUTS
        String containing the base64-encoded SAMLResponse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LoginIDP
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Web

    $Script:SAMLResponse = $null
    $Script:FormClosed = $false

    Write-Host "[DEBUG] New-SAMLInteractive called with IdP: $LoginIDP" -ForegroundColor Magenta

    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SAML Authentication - Please Login"
    $form.Size = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.TopMost = $true
    $form.ShowIcon = $false

    # Create the WebBrowser control
    $web = New-Object System.Windows.Forms.WebBrowser
    $web.Dock = "Fill"
    $web.ScriptErrorsSuppressed = $true
    $web.IsWebBrowserContextMenuEnabled = $false
    $web.AllowWebBrowserDrop = $false
    $form.Controls.Add($web)

    # Event: Navigating - fires BEFORE navigation, can check document content
    $web.add_Navigating({
            param($sender, $e)
        
            # Skip if form already closed
            if ($Script:FormClosed) { return }
        
            try {
                $currentUrl = $e.Url.ToString()
                Write-Host "[DEBUG] Navigating to: $currentUrl" -ForegroundColor DarkMagenta
            
                $documentText = $web.DocumentText
            
                # Check if SAMLResponse is in the document
                if ($documentText -match 'name="SAMLResponse"') {
                    Write-Host "[DEBUG] SAMLResponse found in document!" -ForegroundColor Green
                    Write-Host "[DEBUG] Document length: $($documentText.Length) chars" -ForegroundColor DarkMagenta
                
                    # Try to extract from DOM first (most reliable)
                    if ($web.Document) {
                        $inputs = $web.Document.GetElementsByTagName("input")
                        Write-Host "[DEBUG] Found $($inputs.Count) input elements in DOM" -ForegroundColor DarkMagenta
                        foreach ($inp in $inputs) {
                            $inputName = $inp.GetAttribute("name")
                            if ($inputName -eq "SAMLResponse") {
                                $Script:SAMLResponse = $inp.GetAttribute("value")
                                Write-Host "[DEBUG] Extracted SAMLResponse from DOM, length: $($Script:SAMLResponse.Length)" -ForegroundColor Green
                                break
                            }
                        }
                    }
                
                    # Fallback: Extract via regex if DOM failed
                    if ([string]::IsNullOrEmpty($Script:SAMLResponse)) {
                        Write-Host "[DEBUG] DOM extraction failed, trying regex..." -ForegroundColor Yellow
                        # Pattern: name="SAMLResponse" ... value="..."
                        if ($documentText -match 'name="SAMLResponse"[^>]*value="([^"]+)"') {
                            $Script:SAMLResponse = $Matches[1]
                            Write-Host "[DEBUG] Extracted SAMLResponse via regex pattern 1, length: $($Script:SAMLResponse.Length)" -ForegroundColor Green
                        }
                        elseif ($documentText -match 'value="([^"]+)"[^>]*name="SAMLResponse"') {
                            $Script:SAMLResponse = $Matches[1]
                            Write-Host "[DEBUG] Extracted SAMLResponse via regex pattern 2, length: $($Script:SAMLResponse.Length)" -ForegroundColor Green
                        }
                    }
                
                    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
                        # Decode HTML entities
                        $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '='
                        Write-Host "[DEBUG] SAMLResponse after decoding, length: $($Script:SAMLResponse.Length)" -ForegroundColor Green
                        Write-Host "[DEBUG] SAMLResponse preview: $($Script:SAMLResponse.Substring(0, [Math]::Min(100, $Script:SAMLResponse.Length)))..." -ForegroundColor DarkGray
                    
                        # Cancel navigation and close form
                        $e.Cancel = $true
                        $Script:FormClosed = $true
                        $form.Close()
                    }
                    else {
                        Write-Host "[DEBUG] SAMLResponse pattern found but extraction failed!" -ForegroundColor Red
                    }
                }
            }
            catch {
                Write-Host "[DEBUG] Error in Navigating event: $($_.Exception.Message)" -ForegroundColor Red
            }
        })

    # Navigate to IdP
    Write-Host "[DEBUG] Opening SAML authentication window..." -ForegroundColor Cyan
    $web.Navigate($LoginIDP)

    # Show dialog (blocks until closed)
    [void]$form.ShowDialog()

    # Cleanup
    $web.Dispose()
    $form.Dispose()

    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
        Write-Host "[DEBUG] Returning SAMLResponse (length: $($Script:SAMLResponse.Length))" -ForegroundColor Green
        return $Script:SAMLResponse
    }
    else {
        Write-Host "[DEBUG] No SAMLResponse captured!" -ForegroundColor Red
        Write-Warning "SAML Authentication window closed without capturing a response."
        return $null
    }
}

function Invoke-SAMLAuthentication {
    <#
    .SYNOPSIS
        Complete SAML authentication flow for CyberArk.
        Handles the full 3-phase flow: Get IdP URL -> User Auth -> Complete Auth
    .PARAMETER PVWAURL
        The CyberArk PVWA base URL (e.g., https://cyberark.example.com)
    .PARAMETER ConcurrentSession
        Whether to allow concurrent sessions. Default: $true
    .OUTPUTS
        Hashtable with SessionToken if successful, $null otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PVWAURL,
        
        [bool]$ConcurrentSession = $true
    )

    # Ensure TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $baseUrl = $PVWAURL.TrimEnd('/')
    $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

    Write-Host ""
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "      SAML Authentication     " -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[DEBUG] Base URL: $baseUrl" -ForegroundColor Magenta
    Write-Host "[DEBUG] API Logon URL: $apiLogonUrl" -ForegroundColor Magenta

    try {
        # ========================================
        # PHASE 1: Get IdP URL and CA88888 cookie
        # ========================================
        Write-Host "Step 1: Getting Identity Provider URL..." -ForegroundColor Cyan
        Write-Host "  API: $apiLogonUrl" -ForegroundColor DarkGray

        # Use Invoke-WebRequest to capture cookies
        Write-Host "[DEBUG] Sending initial POST to get IdP URL..." -ForegroundColor Magenta
        $response = Invoke-WebRequest -Uri $apiLogonUrl -Method Post -ContentType "application/json" -Body "" -SessionVariable webSession -UseBasicParsing

        Write-Host "[DEBUG] Response Status: $($response.StatusCode)" -ForegroundColor Magenta
        Write-Host "[DEBUG] Response Content: $($response.Content)" -ForegroundColor Magenta
        Write-Host "[DEBUG] Response Headers:" -ForegroundColor Magenta
        foreach ($header in $response.Headers.Keys) {
            Write-Host "[DEBUG]   $header : $($response.Headers[$header])" -ForegroundColor DarkMagenta
        }

        # Extract IdP URL from response
        $idpUrl = $response.Content.Trim('"')
        
        if ([string]::IsNullOrWhiteSpace($idpUrl)) {
            throw "Could not extract Identity Provider URL from response"
        }
        
        Write-Host "  IdP URL received: $idpUrl" -ForegroundColor Green

        # Extract CA88888 cookie from response headers
        $ca88888 = $null
        $setCookieHeader = $response.Headers["Set-Cookie"]
        Write-Host "[DEBUG] Set-Cookie header: $setCookieHeader" -ForegroundColor Magenta
        
        if ($setCookieHeader) {
            # Handle both string and string[] types
            $cookieString = if ($setCookieHeader -is [array]) { $setCookieHeader -join "; " } else { $setCookieHeader }
            Write-Host "[DEBUG] Cookie string: $cookieString" -ForegroundColor DarkMagenta
            
            if ($cookieString -match 'CA88888=([^;]+)') {
                $ca88888 = $Matches[1]
                Write-Host "[DEBUG] CA88888 cookie extracted: $ca88888" -ForegroundColor Green
            }
        }

        if ([string]::IsNullOrEmpty($ca88888)) {
            Write-Host "[DEBUG] CA88888 cookie NOT found - this may cause authentication to fail!" -ForegroundColor Yellow
        }

        # ========================================
        # PHASE 2: User authenticates at IdP
        # ========================================
        Write-Host ""
        Write-Host "Step 2: Opening authentication window..." -ForegroundColor Cyan
        Write-Host "  Please log in with your credentials." -ForegroundColor Yellow
        Write-Host ""

        $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl

        Write-Host "[DEBUG] SAMLResponse returned: $(if ($samlResponse) { 'YES (length: ' + $samlResponse.Length + ')' } else { 'NULL' })" -ForegroundColor Magenta

        if ([string]::IsNullOrWhiteSpace($samlResponse)) {
            throw "No SAML response received from IdP"
        }

        # ========================================
        # PHASE 3: Complete authentication
        # ========================================
        Write-Host ""
        Write-Host "Step 3: Completing authentication with CyberArk..." -ForegroundColor Cyan

        # Build form data (like PSMEasyConnect does)
        $formData = @{
            concurrentSession = if ($ConcurrentSession) { "true" } else { "false" }
            apiUse            = "true"
            SAMLResponse      = $samlResponse
        }
        
        Write-Host "[DEBUG] Form data keys: $($formData.Keys -join ', ')" -ForegroundColor Magenta
        Write-Host "[DEBUG] SAMLResponse in form data length: $($formData.SAMLResponse.Length)" -ForegroundColor Magenta

        # Create web request session with CA88888 cookie
        $domain = ([System.Uri]$baseUrl).Host
        Write-Host "[DEBUG] Domain for cookie: $domain" -ForegroundColor Magenta
        
        $cookieContainer = New-Object System.Net.CookieContainer
        
        if ($ca88888) {
            $cookie = New-Object System.Net.Cookie("CA88888", $ca88888, "/", $domain)
            $cookie.HttpOnly = $true
            $cookie.Secure = $true
            $cookieContainer.Add($cookie)
            Write-Host "[DEBUG] Added CA88888 cookie to container" -ForegroundColor Green
        }

        # Create HttpWebRequest for the final auth call
        Write-Host "[DEBUG] Creating final auth request to: $apiLogonUrl" -ForegroundColor Magenta
        $authRequest = [System.Net.HttpWebRequest]::Create($apiLogonUrl)
        $authRequest.Method = "POST"
        $authRequest.ContentType = "application/x-www-form-urlencoded"
        $authRequest.CookieContainer = $cookieContainer

        # Encode form data
        $bodyParts = @()
        foreach ($key in $formData.Keys) {
            $encodedKey = [System.Web.HttpUtility]::UrlEncode($key)
            $encodedValue = [System.Web.HttpUtility]::UrlEncode($formData[$key])
            $bodyParts += "$encodedKey=$encodedValue"
        }
        $bodyString = $bodyParts -join "&"
        Write-Host "[DEBUG] Request body length: $($bodyString.Length) chars" -ForegroundColor Magenta
        
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
        
        $authRequest.ContentLength = $bodyBytes.Length
        $requestStream = $authRequest.GetRequestStream()
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $requestStream.Close()

        # Get response
        Write-Host "[DEBUG] Sending final auth request..." -ForegroundColor Magenta
        $authResponse = $authRequest.GetResponse()
        Write-Host "[DEBUG] Response status: $($authResponse.StatusCode)" -ForegroundColor Magenta
        
        $responseStream = $authResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)
        $rawToken = $reader.ReadToEnd()
        $reader.Close()
        $authResponse.Close()
        
        Write-Host "[DEBUG] Raw token response: $rawToken" -ForegroundColor Magenta
        
        $sessionToken = $rawToken.Trim('"')
        Write-Host "[DEBUG] Session token (after trim): $sessionToken" -ForegroundColor Magenta
        Write-Host "[DEBUG] Session token length: $($sessionToken.Length)" -ForegroundColor Magenta

        if ([string]::IsNullOrWhiteSpace($sessionToken)) {
            throw "No session token received from CyberArk"
        }

        Write-Host ""
        Write-Host "SAML AUTHENTICATION SUCCESSFUL!" -ForegroundColor Green
        Write-Host "[DEBUG] Returning auth result with BaseUrl: $baseUrl" -ForegroundColor Magenta
        Write-Host ""

        return @{
            SessionToken = $sessionToken
            BaseUrl      = $baseUrl
        }
    }
    catch {
        Write-Host ""
        Write-Host "SAML AUTHENTICATION FAILED" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[DEBUG] Exception type: $($_.Exception.GetType().FullName)" -ForegroundColor Magenta
        Write-Host "[DEBUG] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor DarkMagenta
        
        # Try to get more details from web exception
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            Write-Host "[DEBUG] WebException Status: $($webEx.Status)" -ForegroundColor Magenta
            if ($webEx.Response) {
                try {
                    $errStream = $webEx.Response.GetResponseStream()
                    $errReader = New-Object System.IO.StreamReader($errStream)
                    $errBody = $errReader.ReadToEnd()
                    Write-Host "[DEBUG] Server error response: $errBody" -ForegroundColor Red
                    $errReader.Close()
                }
                catch {}
            }
        }
        
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Verify PVWA URL is correct" -ForegroundColor Yellow
        Write-Host "  2. Ensure SAML is configured in CyberArk" -ForegroundColor Yellow
        Write-Host "  3. Check IdP (PingId) configuration" -ForegroundColor Yellow
        
        return $null
    }
}

Export-ModuleMember -Function New-SAMLInteractive, Invoke-SAMLAuthentication