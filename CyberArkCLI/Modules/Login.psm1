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

        # Construct IdP URL
        # Logic: PVWA URL + /PasswordVault/auth/saml/
        # Remove trailing slash from base if present
        $baseUrl = $url.TrimEnd('/')
        $idpUrl = "$baseUrl/PasswordVault/auth/saml/"
        
        Write-Host "Starting SAML Authentication..." -ForegroundColor Cyan
        Write-Host "IdP URL: $idpUrl" -ForegroundColor Gray

        try {
            $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl
            
            # Authenticate with SAML
            # Note: psPAS New-PASSession -SAMLAuth requires -SAMLResponse
            $global:CACSession = New-PASSession -BaseURI $baseUrl -SAMLAuth -SAMLResponse $samlResponse
            
            Write-Host "SAML Login Successful!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "SAML Login Failed: $($_.Exception.Message)" -ForegroundColor Red
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
