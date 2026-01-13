# Login.psm1
Import-Module psPAS -ErrorAction Stop
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

    # Show form
    if ($SAML) {
        # --- SAML FLOW ---
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
        }
        else {
            $url = Read-Host "Enter PVWA URL (e.g. https://cyberark.example.com)"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host "PVWA URL cannot be empty." -ForegroundColor Red
            return $false
        }

        # Save URL if new (or updated)
        if ($url -ne $cfg.PVWAURL) {
            Set-CACConfig -PVWAURL $url
        }

        # Construct Base URL
        $baseUrl = $url.TrimEnd('/')
        $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

        Write-Host "Starting SAML Authentication..." -ForegroundColor Cyan
        try {
            # Step 1: Get IdP URL from API
            Write-Host "Fetching IdP URL from: $apiLogonUrl" -ForegroundColor Gray
    
            # Important: Use Invoke-WebRequest to get proper headers/cookies
            $response = Invoke-WebRequest -Uri $apiLogonUrl -Method Post -SessionVariable 'session' -ErrorAction Stop
            $idpUrl = $response.Content.Trim('"')
    
            Write-Host "IdP URL received: $idpUrl" -ForegroundColor Gray

            # Step 2: Interactive Login
            Write-Host "Opening browser for SAML login..." -ForegroundColor Cyan
            $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl
    
            if ([string]::IsNullOrWhiteSpace($samlResponse)) {
                throw "No SAML response received"
            }

            # Step 3: Authenticate with SAML Response
            Write-Host "Authenticating with CyberArk..." -ForegroundColor Gray
            $global:CACSession = New-PASSession -BaseURI $baseUrl -SAMLResponse $samlResponse
    
            Write-Host "SAML Login Successful!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "SAML Login Failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader $_.Exception.Response.GetResponseStream()
                    $respBody = $reader.ReadToEnd()
                    Write-Host "API Error Body: $respBody" -ForegroundColor DarkRed
                }
                catch {
                    Write-Host "Could not read error response body" -ForegroundColor DarkRed
                }
            }
            return $false
        }

    }
    else {
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
            return $true
        }
        catch {
            Write-Host "Login Failed: $($_.Exception.Message)" -ForegroundColor Red
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
