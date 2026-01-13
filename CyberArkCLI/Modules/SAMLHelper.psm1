function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Write-Host ""
    Write-Host "===================== SAML AUTHENTICATION =====================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. A browser will open for SAML login to: $LoginIDP" -ForegroundColor Yellow
    Write-Host "2. Complete your authentication in the browser" -ForegroundColor Yellow
    Write-Host "3. After successful login, the browser will redirect to CyberArk" -ForegroundColor Yellow
    Write-Host "4. Press F12 to open Developer Tools (Network tab)" -ForegroundColor Yellow
    Write-Host "5. Find the POST request to: /PasswordVault/api/auth/saml/logon" -ForegroundColor Yellow
    Write-Host "6. Copy the SAMLResponse value (long encoded string)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Open browser
    try {
        Write-Host "Opening browser..." -ForegroundColor Green
        Start-Process $LoginIDP
    }
    catch {
        Write-Host "Could not open browser automatically." -ForegroundColor Red
        Write-Host "Please manually open: $LoginIDP" -ForegroundColor Yellow
    }

    # Get SAML response from user
    Write-Host ""
    $samlResponse = Read-Host "Paste the SAMLResponse value here (or press Enter to cancel)"

    if ([string]::IsNullOrWhiteSpace($samlResponse)) {
        Write-Host "Authentication cancelled." -ForegroundColor Red
        throw "SAML authentication cancelled"
    }

    # Clean up the response
    $samlResponse = $samlResponse.Trim()
    
    # Remove quotes if present
    $samlResponse = $samlResponse.Trim('"', "'")
    
    # Remove any whitespace/newlines
    $samlResponse = $samlResponse -replace "`n|`r|\s", ""

    Write-Host "SAML response captured successfully!" -ForegroundColor Green
    return $samlResponse
}

Export-ModuleMember -Function New-SAMLInteractive