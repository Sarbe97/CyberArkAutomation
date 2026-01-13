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

# Import SAMLHelper
$samlHelper = Join-Path $PSScriptRoot "SAMLHelper.psm1"
if (Test-Path $samlHelper) {
    Import-Module $samlHelper -Force
}


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
        Write-Host ""
        Write-Host "==============================" -ForegroundColor Cyan
        Write-Host "      SAML Authentication     " -ForegroundColor Cyan
        Write-Host "==============================" -ForegroundColor Cyan
        Write-Host ""

        # Get PVWA URL
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
            Write-Host "Using configured PVWA URL: $url" -ForegroundColor Gray
        }
        else {
            Write-Host "Enter your CyberArk PVWA URL" -ForegroundColor Yellow
            $url = Read-Host "Example: https://cyberark.example.com"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host "PVWA URL cannot be empty." -ForegroundColor Red
            return $false
        }

        # Clean and validate URL
        $baseUrl = $url.TrimEnd('/')
        $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

        Write-Host ""
        Write-Host "Step 1: Getting Identity Provider URL..." -ForegroundColor Cyan
        Write-Host "Calling: $apiLogonUrl" -ForegroundColor DarkGray

        try {
            # Step 1: Get IdP URL from CyberArk
            $response = Invoke-RestMethod -Uri $apiLogonUrl -Method Post -ErrorAction Stop
            
            # Parse the IdP URL from response
            $idpUrl = $null
            if ($response -is [string]) {
                $idpUrl = $response.Trim('"')
            }
            elseif ($response.PSObject.Properties['Url']) {
                $idpUrl = $response.Url
            }
            elseif ($response.PSObject.Properties['Value']) {
                $idpUrl = $response.Value
            }
            elseif ($response.PSObject.Properties['SSOUrl']) {
                $idpUrl = $response.SSOUrl
            }
            else {
                $idpUrl = $response.ToString()
            }

            if ([string]::IsNullOrWhiteSpace($idpUrl)) {
                throw "Could not extract Identity Provider URL from response"
            }

            Write-Host "✓ Identity Provider URL received" -ForegroundColor Green
            Write-Host "IdP URL: $idpUrl" -ForegroundColor DarkGray

            # Save URL if new or changed
            if ($url -ne $cfg.PVWAURL) {
                Set-CACConfig -PVWAURL $url
            }

            Write-Host ""
            Write-Host "Step 2: Opening authentication window..." -ForegroundColor Cyan
            Write-Host "A browser window will open. Please log in with your credentials." -ForegroundColor Yellow
            
            # Step 2: Use the fixed New-SAMLInteractive (uses WebBrowser control)
            $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl
            
            if ([string]::IsNullOrWhiteSpace($samlResponse)) {
                throw "No SAML response received"
            }

            Write-Host ""
            Write-Host "Step 3: Authenticating with CyberArk..." -ForegroundColor Cyan
            
            # Step 3: Try different parameter names for psPAS compatibility
            $session = $null
            $errorMessages = @()
            
            # Try SAMLResponse parameter first (most common)
            try {
                Write-Host "Trying SAMLResponse parameter..." -ForegroundColor DarkGray
                $session = New-PASSession -BaseURI $baseUrl -SAMLResponse $samlResponse
            }
            catch [System.Management.Automation.ParameterBindingException] {
                $errorMessages += "SAMLResponse parameter failed: $($_.Exception.Message)"
                # Try SAMLAuth parameter
                Write-Host "Trying SAMLAuth parameter..." -ForegroundColor DarkGray
                try {
                    $session = New-PASSession -BaseURI $baseUrl -SAMLAuth $samlResponse
                }
                catch {
                    $errorMessages += "SAMLAuth parameter failed: $($_.Exception.Message)"
                    throw "Failed to authenticate. Tried both SAMLResponse and SAMLAuth parameters."
                }
            }
            catch {
                $errorMessages += "Authentication failed: $($_.Exception.Message)"
                throw $_.Exception.Message
            }

            if ($session) {
                $global:CACSession = $session
                Write-Host ""
                Write-Host "SAML AUTHENTICATION SUCCESSFUL!" -ForegroundColor Green
                Write-Host "Session established with CyberArk" -ForegroundColor Green
                Write-Host ""
                return $true
            }
        }
        catch {
            Write-Host ""
            Write-Host "SAML AUTHENTICATION FAILED" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            
            # Show detailed error information for debugging
            if ($errorMessages.Count -gt 0) {
                Write-Host "Error details:" -ForegroundColor DarkRed
                foreach ($msg in $errorMessages) {
                    Write-Host "  - $msg" -ForegroundColor DarkRed
                }
            }
            
            # Check for HTTP response errors
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $respBody = $reader.ReadToEnd()
                    Write-Host "Server response: $respBody" -ForegroundColor DarkRed
                }
                catch {
                    Write-Host "Could not read server response" -ForegroundColor DarkRed
                }
            }
            
            Write-Host ""
            Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
            Write-Host "1. Verify your PVWA URL is correct and accessible" -ForegroundColor Yellow
            Write-Host "2. Ensure SAML is properly configured in CyberArk" -ForegroundColor Yellow
            Write-Host "3. Check if you have permissions for SAML authentication" -ForegroundColor Yellow
            Write-Host "4. Verify the IdP URL works in a regular browser" -ForegroundColor Yellow
            
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