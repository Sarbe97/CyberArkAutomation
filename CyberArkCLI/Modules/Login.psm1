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
            # We must hit the logon API first. It returns the actual IdP URL.
            # It also sets a CA88888 cookie which is handled by the browser session.
            Write-Host "Fetching IdP URL from: $apiLogonUrl" -ForegroundColor Gray
            
            # Using Invoke-WebRequest to get headers/cookies if needed, but for now just body is enough for the URL.
            # Note: psPAS might handle the session cookie internally if we init session later.
            # Ideally we should capture cookies here but let's try the simple URL redirect first.
            $response = Invoke-RestMethod -Uri $apiLogonUrl -Method Post -ErrorAction Stop
            
            # The API returns the URL as a string (usually quoted).
            $idpUrl = $response.Trim('"')
            
            Write-Host "Redirecting to IdP: $idpUrl" -ForegroundColor Gray

            # Step 2: Interactive Login
            $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl
            
            # Step 3: Authenticate with SAML Response
            $global:CACSession = New-PASSession -BaseURI $baseUrl -SAMLAuth -SAMLResponse $samlResponse
            
            Write-Host "SAML Login Successful!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "SAML Login Failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.Response) {
                # Debugging info
                $reader = New-Object System.IO.StreamReader $_.Exception.Response.GetResponseStream()
                $respBody = $reader.ReadToEnd()
                Write-Host "API Error Body: $respBody" -ForegroundColor DarkRed
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
