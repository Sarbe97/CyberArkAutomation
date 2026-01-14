# Login.psm1
Import-Module psPAS -ErrorAction Stop

# Force TLS 1.2
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Import Utils for Write-Log
$utilsPath = Join-Path $PSScriptRoot "Utils.psm1"
if (Test-Path $utilsPath) {
    Import-Module $utilsPath -Force
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
        


        Write-Log "Starting SAML Authentication Flow" "INFO"

        # Get PVWA URL
        $url = $null
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
            Write-Log "Using configured PVWA URL: $url" "INFO"
        }
        else {
            Write-Log "Please enter your CyberArk PVWA URL (e.g., https://cyberark.example.com)" "WARN"
            $url = Read-Host "PVWA URL"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Log "PVWA URL cannot be empty." "ERROR"
            return $false
        }

        # Save URL if new or changed
        if ($url -ne $cfg.PVWAURL) {
            Set-CACConfig -PVWAURL $url
        }

        # Use the complete SAML authentication flow
        # This function handles its own internal logging redirection too
        $authResult = Invoke-SAMLAuthentication -PVWAURL $url

        if ($null -eq $authResult) {
            Write-Log "SAML Authentication returned null result." "ERROR"
            return $false
        }

        Write-Log "Authentication successful. Token length: $($authResult.SessionToken.Length)" "DEBUG"
        Write-Log "Base URL: $($authResult.BaseUrl)" "DEBUG"

        # Establish psPAS session manually since New-PASSession -Token is not supported
        try {
            Write-Log "Initializing psPAS session with token..." "INFO"
            
            $baseUrl = $authResult.BaseUrl
            $token = $authResult.SessionToken

            # Manual Session Construction
            # This mirrors the structure psPAS expects
            $session = @{
                BaseURI    = $baseUrl
                Token      = $token # Using simple 'Token' key as per modern psPAS custom session handling
                Headers    = @{ 
                    "Authorization" = $token 
                    "Content-Type"  = "application/json"
                }
                WebSession = $null # Not using a WebSession container for basic token auth
            }
            
            # --- CRITICAL STEP ---
            # Inject this session into ALL psPAS commands globally
            # This makes Get-PASAccount, Get-PASSafe, etc. automatically pick up this session
            if ($null -eq $PSDefaultParameterValues) {
                $global:PSDefaultParameterValues = @{}
            }
            
            # Set wildcard default for the 'Session' parameter on all modules
            # This ensures any cmdlet using a -Session parameter uses our object
            $global:PSDefaultParameterValues["*:Session"] = $session
            $global:PSDefaultParameterValues["*:BaseURI"] = $baseUrl

            # Update legacy globals for backward compatibility
            $global:CACSession = $session
            $global:CACSessionToken = $token
            
            Write-Log "psPAS session injected into global defaults." "SUCCESS"
            
            # Verify by attempting a simple lightweight call
            # We wrap this to ensure we don't fail the whole login if just the verification fails
            try {
                Write-Log "Verifying session with Get-PASUser..." "DEBUG"
                $currentUser = Get-PASUser -UserName "Manage" -ErrorAction SilentlyContinue 
                if ($currentUser) {
                    Write-Log "Session verification successful (Available)." "SUCCESS"
                }
            }
            catch {
                Write-Log "Session verification skipped/failed (non-fatal): $($_.Exception.Message)" "WARN"
            }
            
            Write-Log "SAML Login Complete." "SUCCESS"
            return $true
        }
        catch {
            Write-Log "Failed to initialize psPAS session manually." "ERROR"
            Write-Log "Error: $($_.Exception.Message)" "ERROR"
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