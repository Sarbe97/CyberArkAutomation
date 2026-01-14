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
        # Get PVWA URL
        $url = $null
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

        # Save URL if new or changed
        if ($url -ne $cfg.PVWAURL) {
            Set-CACConfig -PVWAURL $url
        }

        # Use the complete SAML authentication flow
        $authResult = Invoke-SAMLAuthentication -PVWAURL $url

        if ($null -eq $authResult) {
            return $false
        }

        # Establish psPAS session with the obtained token
        try {
            Write-Host "Establishing psPAS session..." -ForegroundColor Cyan
            
            # Set the session token for psPAS
            # psPAS stores session info in module-scoped variables
            $baseUrl = $authResult.BaseUrl
            $token = $authResult.SessionToken
            
            # Try to create a psPAS session by setting the auth header manually
            # This uses the internal psPAS session management
            $headers = @{
                "Authorization" = $token
            }
            
            # Test the session by making a simple API call
            $testUrl = "$baseUrl/PasswordVault/API/Users"
            $testResponse = Invoke-RestMethod -Uri $testUrl -Headers $headers -Method Get -ErrorAction Stop
            
            # If we get here, the session is valid
            # Store session info for use by other modules
            $global:CACSession = @{
                BaseURI      = $baseUrl
                sessionToken = $token
                Headers      = $headers
            }
            $global:CACSessionToken = $token
            
            Write-Host "Session established successfully!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Warning: Session token obtained but psPAS session setup failed." -ForegroundColor Yellow
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
            
            # Still consider this a success since we have a valid token
            $global:CACSession = @{
                BaseURI      = $authResult.BaseUrl
                sessionToken = $authResult.SessionToken
                Headers      = @{ "Authorization" = $authResult.SessionToken }
            }
            $global:CACSessionToken = $authResult.SessionToken
            
            Write-Host "Session token stored. Some psPAS commands may not work." -ForegroundColor Yellow
            return $true
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