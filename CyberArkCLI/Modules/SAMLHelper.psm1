# SAMLHelper.psm1
# SAML Authentication Helper for CyberArk
# Follows the PSMEasyConnect pattern for reliable SAML auth

# Import Utils for Write-Log
$utilsPath = Join-Path $PSScriptRoot "Utils.psm1"
if (Test-Path $utilsPath) {
    Import-Module $utilsPath -Force
}

function New-SAMLInteractive {
    <#
    .SYNOPSIS
        Opens a browser window for SAML authentication and captures the SAMLResponse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LoginIDP
    )

    # Redirect logs to separate file (Locally scoped)
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["Write-Log:LogName"] = "SAML_Debug"
    $PSDefaultParameterValues["Write-Log:ShowOnScreen"] = $true

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Web

    $Script:SAMLResponse = $null
    $Script:FormClosed = $false

    Write-Log "=== New-SAMLInteractive START ===" "INFO"
    Write-Log "IdP URL: $LoginIDP" "DEBUG"

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

    # Helper scriptblock to check for SAML response
    # Note: We pass Write-Log through to ensure it works in the event scope
    $checkForSAML = {
        param($eventName)
        
        if ($Script:FormClosed) { return $false }
        
        try {
            $documentText = $web.DocumentText
            $currentUrl = if ($web.Url) { $web.Url.ToString() } else { "unknown" }
            
            Write-Log "[$eventName] URL: $currentUrl" "DEBUG"
            Write-Log "[$eventName] Document length: $($documentText.Length)" "DEBUG"
            
            # Check if SAMLResponse is in the document
            if ($documentText -match 'name="SAMLResponse"' -or $documentText -match 'name=''SAMLResponse''') {
                Write-Log "[$eventName] SAMLResponse FOUND in HTML!" "SUCCESS"
                
                # Try DOM extraction first
                if ($web.Document) {
                    $inputs = $web.Document.GetElementsByTagName("input")
                    Write-Log "[$eventName] Found $($inputs.Count) input elements" "DEBUG"
                    
                    foreach ($inp in $inputs) {
                        $inputName = $inp.GetAttribute("name")
                        if ($inputName -eq "SAMLResponse") {
                            $Script:SAMLResponse = $inp.GetAttribute("value")
                            Write-Log "[$eventName] Extracted via DOM. Length: $($Script:SAMLResponse.Length)" "SUCCESS"
                            return $true
                        }
                    }
                }
                
                # Regex fallback - try multiple patterns
                $patterns = @(
                    'name="SAMLResponse"[^>]*value="([^"]+)"',
                    'value="([^"]+)"[^>]*name="SAMLResponse"',
                    "name='SAMLResponse'[^>]*value='([^']+)'",
                    "value='([^']+)'[^>]*name='SAMLResponse'"
                )
                
                foreach ($pattern in $patterns) {
                    if ($documentText -match $pattern) {
                        $Script:SAMLResponse = $Matches[1]
                        Write-Log "[$eventName] Extracted via regex. Length: $($Script:SAMLResponse.Length)" "SUCCESS"
                        return $true
                    }
                }
                
                Write-Log "[$eventName] SAMLResponse tag found but extraction failed!" "ERROR"
            }
        }
        catch {
            Write-Log "[$eventName] Error: $($_.Exception.Message)" "ERROR"
        }
        
        return $false
    }

    # Event: Navigating (BEFORE page loads)
    $web.add_Navigating({
        param($sender, $e)
        
        if ($Script:FormClosed) { return }
        
        Write-Log "[Navigating] Target: $($e.Url)" "DEBUG"
        
        if (& $checkForSAML "Navigating") {
            # Decode HTML entities
            $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '=' -replace '&amp;', '&'
            Write-Log "[Navigating] SAMLResponse decoded. Closing form." "SUCCESS"
            $e.Cancel = $true
            $Script:FormClosed = $true
            $form.Close()
        }
    })

    # Event: DocumentCompleted (AFTER page loads) - backup check
    $web.add_DocumentCompleted({
        param($sender, $e)
        
        if ($Script:FormClosed) { return }
        
        Write-Log "[DocumentCompleted] URL: $($e.Url)" "DEBUG"
        
        if (& $checkForSAML "DocumentCompleted") {
            # Decode HTML entities
            $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '=' -replace '&amp;', '&'
            Write-Log "[DocumentCompleted] SAMLResponse decoded. Closing form." "SUCCESS"
            $Script:FormClosed = $true
            $form.Close()
        }
    })

    # Navigate to IdP
    Write-Log "Opening browser and navigating to IdP..." "INFO"
    $web.Navigate($LoginIDP)

    # Show dialog (blocks until closed)
    [void]$form.ShowDialog()

    # Cleanup
    $web.Dispose()
    $form.Dispose()

    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
        Write-Log "=== New-SAMLInteractive SUCCESS ===" "SUCCESS"
        Write-Log "Returning SAMLResponse (length: $($Script:SAMLResponse.Length))" "DEBUG"
        return $Script:SAMLResponse
    }
    else {
        Write-Log "=== New-SAMLInteractive FAILED ===" "ERROR"
        Write-Log "No SAMLResponse was captured!" "ERROR"
        return $null
    }
}

function Invoke-SAMLAuthentication {
    <#
    .SYNOPSIS
        Complete SAML authentication flow for CyberArk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PVWAURL,
        
        [bool]$ConcurrentSession = $true
    )

    # Redirect logs to separate file (Locally scoped)
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["Write-Log:LogName"] = "SAML_Debug"
    $PSDefaultParameterValues["Write-Log:ShowOnScreen"] = $true

    # Ensure TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $baseUrl = $PVWAURL.TrimEnd('/')
    $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

    Write-Log "==========================================" "INFO"
    Write-Log "SAML Authentication Starting" "INFO"
    Write-Log "Base URL: $baseUrl" "DEBUG"
    Write-Log "API Logon URL: $apiLogonUrl" "DEBUG"

    try {
        # ========================================
        # PHASE 1: Get IdP URL and CA88888 cookie
        # ========================================
        Write-Log "PHASE 1: Getting IdP URL" "INFO"

        $response = Invoke-WebRequest -Uri $apiLogonUrl -Method Post -ContentType "application/json" -Body "" -SessionVariable webSession -UseBasicParsing

        Write-Log "Response Status: $($response.StatusCode)" "DEBUG"
        
        # Extract IdP URL
        $idpUrl = $response.Content.Trim('"')
        Write-Log "IdP URL extracted: $idpUrl" "DEBUG"
        
        if ([string]::IsNullOrWhiteSpace($idpUrl)) {
            throw "Could not extract Identity Provider URL from response"
        }
        
        Write-Log "IdP URL received" "INFO"

        # Extract CA88888 cookie
        $ca88888 = $null
        $setCookieHeader = $response.Headers["Set-Cookie"]
        Write-Log "Set-Cookie header available: $(if($setCookieHeader){'Yes'}else{'No'})" "DEBUG"
        
        if ($setCookieHeader) {
            $cookieString = if ($setCookieHeader -is [array]) { $setCookieHeader -join "; " } else { $setCookieHeader.ToString() }
            Write-Log "Cookie string: $cookieString" "DEBUG"
            
            if ($cookieString -match 'CA88888=([^;]+)') {
                $ca88888 = $Matches[1]
                Write-Log "CA88888 cookie found" "SUCCESS"
            }
            else {
                Write-Log "CA88888 not found in cookies!" "WARN"
            }
        }
        else {
            Write-Log "No Set-Cookie header found!" "WARN"
        }

        # ========================================
        # PHASE 2: User authenticates at IdP
        # ========================================
        Write-Log "PHASE 2: Opening browser for IdP auth" "INFO"

        $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl

        Write-Log "SAMLResponse returned: $(if ($samlResponse) { 'YES' } else { 'NULL' })" "DEBUG"
        if ($samlResponse) {
            Write-Log "SAMLResponse length: $($samlResponse.Length)" "DEBUG"
        }

        if ([string]::IsNullOrWhiteSpace($samlResponse)) {
            throw "No SAML response received from IdP"
        }

        # ========================================
        # PHASE 3: Complete authentication
        # ========================================
        Write-Log "PHASE 3: Sending SAMLResponse to CyberArk" "INFO"

        # Build form data
        $formData = @{
            concurrentSession = if ($ConcurrentSession) { "true" } else { "false" }
            apiUse = "true"
            SAMLResponse = $samlResponse
        }
        
        Write-Log "Form data: concurrentSession=$($formData.concurrentSession), apiUse=$($formData.apiUse)" "DEBUG"

        # Create cookie container
        $domain = ([System.Uri]$baseUrl).Host
        Write-Log "Cookie domain: $domain" "DEBUG"
        
        $cookieContainer = New-Object System.Net.CookieContainer
        
        if ($ca88888) {
            $cookie = New-Object System.Net.Cookie("CA88888", $ca88888, "/", $domain)
            $cookie.HttpOnly = $true
            $cookie.Secure = $true
            $cookieContainer.Add($cookie)
            Write-Log "Added CA88888 cookie to request" "DEBUG"
        }

        # Create request
        Write-Log "Creating POST request to: $apiLogonUrl" "DEBUG"
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
        Write-Log "Request body length: $($bodyString.Length)" "DEBUG"
        
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
        $authRequest.ContentLength = $bodyBytes.Length
        
        $requestStream = $authRequest.GetRequestStream()
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $requestStream.Close()

        # Get response
        Write-Log "Sending request..." "DEBUG"
        $authResponse = $authRequest.GetResponse()
        Write-Log "Response status: $($authResponse.StatusCode)" "DEBUG"
        
        $responseStream = $authResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)
        $rawToken = $reader.ReadToEnd()
        $reader.Close()
        $authResponse.Close()
        
        Write-Log "Raw token response received" "DEBUG"
        
        $sessionToken = $rawToken.Trim('"')
        Write-Log "Session token length: $($sessionToken.Length)" "DEBUG"

        if ([string]::IsNullOrWhiteSpace($sessionToken)) {
            throw "No session token received from CyberArk"
        }

        Write-Log "==========================================" "SUCCESS"
        Write-Log "AUTHENTICATION SUCCESSFUL" "SUCCESS"
        Write-Log "==========================================" "SUCCESS"

        return @{
            SessionToken = $sessionToken
            BaseUrl = $baseUrl
        }
    }
    catch {
        Write-Log "==========================================" "ERROR"
        Write-Log "AUTHENTICATION FAILED" "ERROR"
        Write-Log "Error: $($_.Exception.Message)" "ERROR"
        Write-Log "Exception type: $($_.Exception.GetType().FullName)" "ERROR"
        Write-Log "Stack: $($_.ScriptStackTrace)" "ERROR"
        
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            Write-Log "WebException Status: $($webEx.Status)" "ERROR"
            if ($webEx.Response) {
                try {
                    $errStream = $webEx.Response.GetResponseStream()
                    $errReader = New-Object System.IO.StreamReader($errStream)
                    $errBody = $errReader.ReadToEnd()
                    Write-Log "Server error: $errBody" "ERROR"
                    $errReader.Close()
                }
                catch {}
            }
        }
        
        Write-Log "==========================================" "ERROR"
        
        return $null
    }
}

Export-ModuleMember -Function New-SAMLInteractive, Invoke-SAMLAuthentication
