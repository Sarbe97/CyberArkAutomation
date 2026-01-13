function Invoke-CACLogin {
    [CmdletBinding()]
    param(
        [switch]$SAML
    )

    $cfg = Get-CACConfig

    # Show form for non-SAML
    if (-not $SAML) {
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
            Write-Host "Login Successful!" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "Login Failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    else {
        # --- SAML FLOW ---
        Write-Host ""
        Write-Host "=== SAML Authentication ===" -ForegroundColor Cyan
        
        # Get PVWA URL
        if (-not [string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
            $url = $cfg.PVWAURL
            Write-Host "Using PVWA URL from config: $url" -ForegroundColor Gray
        }
        else {
            $url = Read-Host "Enter PVWA URL (e.g. https://cyberark.example.com)"
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Host "PVWA URL cannot be empty." -ForegroundColor Red
            return $false
        }

        # Clean URL
        $url = $url.Trim()
        if (-not $url.EndsWith('/')) {
            $url = $url + '/'
        }

        # Save URL if new (or updated)
        if ($url -ne $cfg.PVWAURL) {
            Set-CACConfig -PVWAURL $url
        }

        # Construct Base URL
        $baseUrl = $url.TrimEnd('/')
        $apiLogonUrl = "$baseUrl/PasswordVault/api/auth/saml/logon"

        Write-Host ""
        Write-Host "Step 1: Getting IdP URL from CyberArk..." -ForegroundColor Cyan
        Write-Host "Calling: $apiLogonUrl" -ForegroundColor Gray

        try {
            # Step 1: Get IdP URL from API
            $response = Invoke-RestMethod -Uri $apiLogonUrl -Method Post -ErrorAction Stop
            
            # Parse response
            if ($response -is [string]) {
                $idpUrl = $response.Trim('"')
            }
            elseif ($response -is [pscustomobject]) {
                # Try different property names
                if ($response.Url) { $idpUrl = $response.Url }
                elseif ($response.Value) { $idpUrl = $response.Value }
                elseif ($response.SSOUrl) { $idpUrl = $response.SSOUrl }
                else { $idpUrl = $response.ToString() }
            }
            else {
                $idpUrl = $response.ToString()
            }

            Write-Host "IdP URL received successfully" -ForegroundColor Green
            Write-Host "IdP URL: $idpUrl" -ForegroundColor Gray

            # Step 2: Interactive Login
            Write-Host ""
            Write-Host "Step 2: Starting interactive SAML login..." -ForegroundColor Cyan
            $samlResponse = New-SAMLInteractive -LoginIDP $idpUrl
            
            if ([string]::IsNullOrWhiteSpace($samlResponse)) {
                throw "No SAML response received"
            }

            # Step 3: Authenticate with SAML Response
            Write-Host ""
            Write-Host "Step 3: Authenticating with CyberArk..." -ForegroundColor Cyan
            
            # Try different parameter names based on psPAS version
            $success = $false
            $errorMsg = ""
            
            try {
                Write-Host "Trying SAMLResponse parameter..." -ForegroundColor Gray
                $global:CACSession = New-PASSession -BaseURI $baseUrl -SAMLResponse $samlResponse
                $success = $true
            }
            catch [System.Management.Automation.ParameterBindingException] {
                $errorMsg = $_.Exception.Message
                Write-Host "Trying SAMLAuth parameter..." -ForegroundColor Gray
                try {
                    $global:CACSession = New-PASSession -BaseURI $baseUrl -SAMLAuth $samlResponse
                    $success = $true
                }
                catch {
                    throw "Failed with SAMLAuth parameter: $($_.Exception.Message)"
                }
            }
            catch {
                throw "Failed with SAMLResponse parameter: $($_.Exception.Message)"
            }

            if ($success) {
                Write-Host ""
                Write-Host "✓ SAML Login Successful!" -ForegroundColor Green
                return $true
            }
        }
        catch {
            Write-Host ""
            Write-Host "✗ SAML Login Failed!" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            
            # Debug information
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $respBody = $reader.ReadToEnd()
                    Write-Host "Response: $respBody" -ForegroundColor DarkRed
                }
                catch {}
            }
            
            Write-Host ""
            Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
            Write-Host "1. Verify your PVWA URL is correct" -ForegroundColor Yellow
            Write-Host "2. Ensure SAML is configured in CyberArk" -ForegroundColor Yellow
            Write-Host "3. Check if the IdP URL is accessible from your machine" -ForegroundColor Yellow
            Write-Host "4. Verify you copied the entire SAMLResponse value" -ForegroundColor Yellow
            
            return $false
        }
    }
}