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
                $documentText = $web.DocumentText
            
                # Check if SAMLResponse is in the document
                if ($documentText -match 'name="SAMLResponse"') {
                
                    # Try to extract from DOM first (most reliable)
                    if ($web.Document) {
                        $inputs = $web.Document.GetElementsByTagName("input")
                        foreach ($inp in $inputs) {
                            if ($inp.GetAttribute("name") -eq "SAMLResponse") {
                                $Script:SAMLResponse = $inp.GetAttribute("value")
                                break
                            }
                        }
                    }
                
                    # Fallback: Extract via regex if DOM failed
                    if ([string]::IsNullOrEmpty($Script:SAMLResponse)) {
                        # Pattern: name="SAMLResponse" ... value="..."
                        if ($documentText -match 'name="SAMLResponse"[^>]*value="([^"]+)"') {
                            $Script:SAMLResponse = $Matches[1]
                        }
                        elseif ($documentText -match 'value="([^"]+)"[^>]*name="SAMLResponse"') {
                            $Script:SAMLResponse = $Matches[1]
                        }
                    }
                
                    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
                        # Decode HTML entities
                        $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '='
                    
                        # Cancel navigation and close form
                        $e.Cancel = $true
                        $Script:FormClosed = $true
                        $form.Close()
                    }
                }
            }
            catch {
                # Silently continue - document might not be ready
            }
        })

    # Navigate to IdP
    Write-Host "Opening SAML authentication window..." -ForegroundColor Cyan
    $web.Navigate($LoginIDP)

    # Show dialog (blocks until closed)
    [void]$form.ShowDialog()

    # Cleanup
    $web.Dispose()
    $form.Dispose()

    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
        Write-Host "SAML Response captured successfully." -ForegroundColor Green
        return $Script:SAMLResponse
    }
    else {
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

    try {
        # ========================================
        # PHASE 1: Get IdP URL and CA88888 cookie
        # ========================================
        Write-Host "Step 1: Getting Identity Provider URL..." -ForegroundColor Cyan
        Write-Host "  API: $apiLogonUrl" -ForegroundColor DarkGray

        # Use Invoke-WebRequest to capture cookies
        $response = Invoke-WebRequest -Uri $apiLogonUrl -Method Post -ContentType "application/json" -Body "" -SessionVariable webSession -UseBasicParsing

        # Extract IdP URL from response
        $idpUrl = $response.Content.Trim('"')
        
        if ([string]::IsNullOrWhiteSpace($idpUrl)) {
            throw "Could not extract Identity Provider URL from response"
        }
        
        Write-Host "  IdP URL received" -ForegroundColor Green

        # Extract CA88888 cookie from response headers
        $ca88888 = $null
        $setCookieHeader = $response.Headers["Set-Cookie"]
        if ($setCookieHeader) {
            if ($setCookieHeader -match 'CA88888=([^;]+)') {
                $ca88888 = $Matches[1]
                Write-Host "  CA88888 cookie captured" -ForegroundColor Green
            }
        }

        if ([string]::IsNullOrEmpty($ca88888)) {
            Write-Warning "CA88888 cookie not found - authentication may fail"
        }

        # ========================================
        # PHASE 2: User authenticates at IdP
        # ========================================
        Write-Host ""
        Write-Host "Step 2: Opening authentication window..." -ForegroundColor Cyan
        Write-Host "  Please log in with your credentials." -ForegroundColor Yellow
        Write-Host ""

        $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl

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

        # Create web request session with CA88888 cookie
        $domain = ([System.Uri]$baseUrl).Host
        $cookieContainer = New-Object System.Net.CookieContainer
        
        if ($ca88888) {
            $cookie = New-Object System.Net.Cookie("CA88888", $ca88888, "/", $domain)
            $cookie.HttpOnly = $true
            $cookie.Secure = $true
            $cookieContainer.Add($cookie)
        }

        # Create HttpWebRequest for the final auth call
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
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
        
        $authRequest.ContentLength = $bodyBytes.Length
        $requestStream = $authRequest.GetRequestStream()
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $requestStream.Close()

        # Get response
        $authResponse = $authRequest.GetResponse()
        $responseStream = $authResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)
        $sessionToken = $reader.ReadToEnd().Trim('"')
        $reader.Close()
        $authResponse.Close()

        if ([string]::IsNullOrWhiteSpace($sessionToken)) {
            throw "No session token received from CyberArk"
        }

        Write-Host ""
        Write-Host "SAML AUTHENTICATION SUCCESSFUL!" -ForegroundColor Green
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
        
        # Try to get more details from web exception
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            if ($webEx.Response) {
                try {
                    $errStream = $webEx.Response.GetResponseStream()
                    $errReader = New-Object System.IO.StreamReader($errStream)
                    $errBody = $errReader.ReadToEnd()
                    Write-Host "Server response: $errBody" -ForegroundColor DarkRed
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