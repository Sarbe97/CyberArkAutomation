# SAMLHelper.psm1
# SAML Authentication Helper for CyberArk
# Follows the PSMEasyConnect pattern for reliable SAML auth

# Import Write-Log from Utils if available
$utilsPath = Join-Path $PSScriptRoot "Utils.psm1"
if (Test-Path $utilsPath) {
    Import-Module $utilsPath -Force
}

# Fallback Write-Log if Utils not loaded
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO", [bool]$ShowOnScreen = $false)
        $logDir = Join-Path $PSScriptRoot "../Logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logFile = Join-Path $logDir "saml_debug_$(Get-Date -Format 'yyyy-MM-dd').log"
        $line = "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message"
        Add-Content -Path $logFile -Value $line -Encoding UTF8
        if ($ShowOnScreen) { Write-Host $line -ForegroundColor $(if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "DEBUG") { "Magenta" } else { "Gray" }) }
    }
}

function Write-SAMLLog {
    param([string]$Message, [string]$Level = "DEBUG")
    # Always write to dedicated SAML log file AND console
    $logDir = Join-Path $PSScriptRoot "../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "saml_debug_$(Get-Date -Format 'yyyy-MM-dd').log"
    $line = "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        "INFO" { "Cyan" }
        default { "Magenta" }
    }
    Write-Host $line -ForegroundColor $color
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

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Web

    $Script:SAMLResponse = $null
    $Script:FormClosed = $false

    Write-SAMLLog "=== New-SAMLInteractive START ===" "INFO"
    Write-SAMLLog "IdP URL: $LoginIDP" "DEBUG"

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

    # Helper to check for SAML response
    $checkForSAML = {
        param($eventName)
        
        if ($Script:FormClosed) { return $false }
        
        try {
            $documentText = $web.DocumentText
            $currentUrl = if ($web.Url) { $web.Url.ToString() } else { "unknown" }
            
            Write-SAMLLog "[$eventName] URL: $currentUrl" "DEBUG"
            Write-SAMLLog "[$eventName] Document length: $($documentText.Length)" "DEBUG"
            
            # Check if SAMLResponse is in the document
            if ($documentText -match 'name="SAMLResponse"' -or $documentText -match 'name=''SAMLResponse''') {
                Write-SAMLLog "[$eventName] SAMLResponse FOUND in HTML!" "SUCCESS"
                
                # Try DOM extraction first
                if ($web.Document) {
                    $inputs = $web.Document.GetElementsByTagName("input")
                    Write-SAMLLog "[$eventName] Found $($inputs.Count) input elements" "DEBUG"
                    
                    foreach ($inp in $inputs) {
                        $inputName = $inp.GetAttribute("name")
                        if ($inputName -eq "SAMLResponse") {
                            $Script:SAMLResponse = $inp.GetAttribute("value")
                            Write-SAMLLog "[$eventName] Extracted via DOM. Length: $($Script:SAMLResponse.Length)" "SUCCESS"
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
                        Write-SAMLLog "[$eventName] Extracted via regex. Length: $($Script:SAMLResponse.Length)" "SUCCESS"
                        return $true
                    }
                }
                
                Write-SAMLLog "[$eventName] SAMLResponse tag found but extraction failed!" "ERROR"
            }
        }
        catch {
            Write-SAMLLog "[$eventName] Error: $($_.Exception.Message)" "ERROR"
        }
        
        return $false
    }

    # Event: Navigating (BEFORE page loads)
    $web.add_Navigating({
            param($sender, $e)
        
            if ($Script:FormClosed) { return }
        
            Write-SAMLLog "[Navigating] Target: $($e.Url)" "DEBUG"
        
            if (& $checkForSAML "Navigating") {
                # Decode HTML entities
                $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '=' -replace '&amp;', '&'
                Write-SAMLLog "[Navigating] SAMLResponse decoded. Closing form." "SUCCESS"
                $e.Cancel = $true
                $Script:FormClosed = $true
                $form.Close()
            }
        })

    # Event: DocumentCompleted (AFTER page loads) - backup check
    $web.add_DocumentCompleted({
            param($sender, $e)
        
            if ($Script:FormClosed) { return }
        
            Write-SAMLLog "[DocumentCompleted] URL: $($e.Url)" "DEBUG"
        
            if (& $checkForSAML "DocumentCompleted") {
                # Decode HTML entities
                $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '=' -replace '&amp;', '&'
                Write-SAMLLog "[DocumentCompleted] SAMLResponse decoded. Closing form." "SUCCESS"
                $Script:FormClosed = $true
                $form.Close()
            }
        })

    # Navigate to IdP
    Write-SAMLLog "Opening browser and navigating to IdP..." "INFO"
    $web.Navigate($LoginIDP)

    # Show dialog (blocks until closed)
    [void]$form.ShowDialog()

    # Cleanup
    $web.Dispose()
    $form.Dispose()

    if (-not [string]::IsNullOrEmpty($Script:SAMLResponse)) {
        Write-SAMLLog "=== New-SAMLInteractive SUCCESS ===" "SUCCESS"
        Write-SAMLLog "Returning SAMLResponse (length: $($Script:SAMLResponse.Length))" "DEBUG"
        Write-SAMLLog "SAMLResponse preview: $($Script:SAMLResponse.Substring(0, [Math]::Min(200, $Script:SAMLResponse.Length)))..." "DEBUG"
        return $Script:SAMLResponse
    }
    else {
        Write-SAMLLog "=== New-SAMLInteractive FAILED ===" "ERROR"
        Write-SAMLLog "No SAMLResponse was captured!" "ERROR"
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

    # Ensure TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $baseUrl = $PVWAURL.TrimEnd('/')
    $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

    Write-Host ""
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "      SAML Authentication     " -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-SAMLLog "==========================================" "INFO"
    Write-SAMLLog "SAML Authentication Starting" "INFO"
    Write-SAMLLog "Base URL: $baseUrl" "DEBUG"
    Write-SAMLLog "API Logon URL: $apiLogonUrl" "DEBUG"

    try {
        # ========================================
        # PHASE 1: Get IdP URL and CA88888 cookie
        # ========================================
        Write-Host "Step 1: Getting Identity Provider URL..." -ForegroundColor Cyan
        Write-SAMLLog "PHASE 1: Getting IdP URL" "INFO"

        $response = Invoke-WebRequest -Uri $apiLogonUrl -Method Post -ContentType "application/json" -Body "" -SessionVariable webSession -UseBasicParsing

        Write-SAMLLog "Response Status: $($response.StatusCode)" "DEBUG"
        Write-SAMLLog "Response Content: $($response.Content)" "DEBUG"

        # Extract IdP URL
        $idpUrl = $response.Content.Trim('"')
        Write-SAMLLog "IdP URL extracted: $idpUrl" "DEBUG"
        
        if ([string]::IsNullOrWhiteSpace($idpUrl)) {
            throw "Could not extract Identity Provider URL from response"
        }
        
        Write-Host "  IdP URL received" -ForegroundColor Green

        # Extract CA88888 cookie
        $ca88888 = $null
        $setCookieHeader = $response.Headers["Set-Cookie"]
        Write-SAMLLog "Set-Cookie header type: $($setCookieHeader.GetType().Name)" "DEBUG"
        Write-SAMLLog "Set-Cookie header: $setCookieHeader" "DEBUG"
        
        if ($setCookieHeader) {
            $cookieString = if ($setCookieHeader -is [array]) { $setCookieHeader -join "; " } else { $setCookieHeader.ToString() }
            Write-SAMLLog "Cookie string: $cookieString" "DEBUG"
            
            if ($cookieString -match 'CA88888=([^;]+)') {
                $ca88888 = $Matches[1]
                Write-SAMLLog "CA88888 cookie: $ca88888" "SUCCESS"
                Write-Host "  CA88888 cookie captured" -ForegroundColor Green
            }
            else {
                Write-SAMLLog "CA88888 not found in cookies!" "WARN"
            }
        }
        else {
            Write-SAMLLog "No Set-Cookie header found!" "WARN"
        }

        # ========================================
        # PHASE 2: User authenticates at IdP
        # ========================================
        Write-Host ""
        Write-Host "Step 2: Opening authentication window..." -ForegroundColor Cyan
        Write-Host "  Please log in with your credentials." -ForegroundColor Yellow
        Write-Host ""
        Write-SAMLLog "PHASE 2: Opening browser for IdP auth" "INFO"

        $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl

        Write-SAMLLog "SAMLResponse returned: $(if ($samlResponse) { 'YES' } else { 'NULL' })" "DEBUG"
        if ($samlResponse) {
            Write-SAMLLog "SAMLResponse length: $($samlResponse.Length)" "DEBUG"
        }

        if ([string]::IsNullOrWhiteSpace($samlResponse)) {
            throw "No SAML response received from IdP"
        }

        # ========================================
        # PHASE 3: Complete authentication
        # ========================================
        Write-Host ""
        Write-Host "Step 3: Completing authentication with CyberArk..." -ForegroundColor Cyan
        Write-SAMLLog "PHASE 3: Sending SAMLResponse to CyberArk" "INFO"

        # Build form data
        $formData = @{
            concurrentSession = if ($ConcurrentSession) { "true" } else { "false" }
            apiUse            = "true"
            SAMLResponse      = $samlResponse
        }
        
        Write-SAMLLog "Form data: concurrentSession=$($formData.concurrentSession), apiUse=$($formData.apiUse), SAMLResponse.Length=$($formData.SAMLResponse.Length)" "DEBUG"

        # Create cookie container
        $domain = ([System.Uri]$baseUrl).Host
        Write-SAMLLog "Cookie domain: $domain" "DEBUG"
        
        $cookieContainer = New-Object System.Net.CookieContainer
        
        if ($ca88888) {
            $cookie = New-Object System.Net.Cookie("CA88888", $ca88888, "/", $domain)
            $cookie.HttpOnly = $true
            $cookie.Secure = $true
            $cookieContainer.Add($cookie)
            Write-SAMLLog "Added CA88888 cookie to request" "DEBUG"
        }

        # Create request
        Write-SAMLLog "Creating POST request to: $apiLogonUrl" "DEBUG"
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
        Write-SAMLLog "Request body length: $($bodyString.Length)" "DEBUG"
        
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
        $authRequest.ContentLength = $bodyBytes.Length
        
        $requestStream = $authRequest.GetRequestStream()
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $requestStream.Close()

        # Get response
        Write-SAMLLog "Sending request..." "DEBUG"
        $authResponse = $authRequest.GetResponse()
        Write-SAMLLog "Response status: $($authResponse.StatusCode)" "DEBUG"
        
        $responseStream = $authResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)
        $rawToken = $reader.ReadToEnd()
        $reader.Close()
        $authResponse.Close()
        
        Write-SAMLLog "Raw token response: $rawToken" "DEBUG"
        
        $sessionToken = $rawToken.Trim('"')
        Write-SAMLLog "Session token: $sessionToken" "DEBUG"
        Write-SAMLLog "Session token length: $($sessionToken.Length)" "DEBUG"

        if ([string]::IsNullOrWhiteSpace($sessionToken)) {
            throw "No session token received from CyberArk"
        }

        Write-Host ""
        Write-Host "SAML AUTHENTICATION SUCCESSFUL!" -ForegroundColor Green
        Write-SAMLLog "==========================================" "SUCCESS"
        Write-SAMLLog "AUTHENTICATION SUCCESSFUL" "SUCCESS"
        Write-SAMLLog "==========================================" "SUCCESS"
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
        
        Write-SAMLLog "==========================================" "ERROR"
        Write-SAMLLog "AUTHENTICATION FAILED" "ERROR"
        Write-SAMLLog "Error: $($_.Exception.Message)" "ERROR"
        Write-SAMLLog "Exception type: $($_.Exception.GetType().FullName)" "ERROR"
        Write-SAMLLog "Stack: $($_.ScriptStackTrace)" "ERROR"
        
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            Write-SAMLLog "WebException Status: $($webEx.Status)" "ERROR"
            if ($webEx.Response) {
                try {
                    $errStream = $webEx.Response.GetResponseStream()
                    $errReader = New-Object System.IO.StreamReader($errStream)
                    $errBody = $errReader.ReadToEnd()
                    Write-SAMLLog "Server error: $errBody" "ERROR"
                    Write-Host "Server response: $errBody" -ForegroundColor Red
                    $errReader.Close()
                }
                catch {}
            }
        }
        
        Write-SAMLLog "==========================================" "ERROR"
        
        return $null
    }
}

Export-ModuleMember -Function New-SAMLInteractive, Invoke-SAMLAuthentication