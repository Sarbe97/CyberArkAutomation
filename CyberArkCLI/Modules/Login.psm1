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
        
        # Configure Log Redirection for this scope
        $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
        $PSDefaultParameterValues["Write-Log:LogName"] = "SAML_Debug"
        $PSDefaultParameterValues["Write-Log:ShowOnScreen"] = $true

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

        # Establish psPAS session with the obtained token
        try {
            Write-Log "Initializing psPAS session with token..." "INFO"
            
            # Set the session token for psPAS
            $baseUrl = $authResult.BaseUrl
            $token = $authResult.SessionToken
            
            # Try to create a psPAS session using the token (modern psPAS support)
            # This is critical for subsequent psPAS commands (Get-PASSafe etc) to work
            $session = New-PASSession -BaseURI $baseUrl -Token $token -ErrorAction Stop
            
            # Update globals
            $global:CACSession = $session
            $global:CACSessionToken = $token
            
            # Verify session object
            if ($session) {
                Write-Log "psPAS session established successfully." "SUCCESS"
            }
            else {
                Write-Log "New-PASSession returned null but no error thrown." "WARN"
            }
            
            Write-Log "SAML Login Complete." "SUCCESS"
            return $true
        }
        catch {
            Write-Log "Failed to initialize psPAS session using token." "ERROR"
            Write-Log "Error: $($_.Exception.Message)" "ERROR"
            Write-Log "Exception Type: $($_.Exception.GetType().FullName)" "ERROR"
            
            Write-Log "Falling back to manual session construction (some psPAS commands may fail)." "WARN"
            
            # Manual fallback
            $global:CACSession = @{
                BaseURI      = $authResult.BaseUrl
                sessionToken = $authResult.SessionToken
                Headers      = @{ "Authorization" = $authResult.SessionToken }
            }
            $global:CACSessionToken = $authResult.SessionToken
            
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