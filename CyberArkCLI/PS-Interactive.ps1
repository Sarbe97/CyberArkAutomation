
# Test-PingID-SAML.ps1
# Manual SAML authentication test for CyberArk using PingID + psPAS
# Reference: https://pspas.pspete.dev/docs/authentication/#saml-authentication

# -----------------------------
# CONFIGURATION
# -----------------------------

$BaseURL = 'https://pvwa.mycompany.com'   # PVWA base URL (no /PasswordVault)
$SamlModulePath = 'C:\PS-SAML-Interactive.psm1'

# -----------------------------
# IMPORT MODULES
# -----------------------------

Import-Module psPAS -ErrorAction Stop
Import-Module $SamlModulePath -ErrorAction Stop

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Modules loaded successfully." -ForegroundColor Green

# -----------------------------
# STEP 1: GET IDP URL FROM CYBERARK
# -----------------------------

$logonUrl = "$BaseURL/PasswordVault/api/auth/saml/logon"

Write-Host "Requesting IdP redirect URL from CyberArk..." -ForegroundColor Yellow

$response = Invoke-WebRequest `
    -Uri $logonUrl `
    -Method Post `
    -ContentType "application/json" `
    -Body "" `
    -SessionVariable webSession `
    -UseBasicParsing

$idpUrl = $response.Content.Trim('"')

if ([string]::IsNullOrWhiteSpace($idpUrl)) {
    throw "Failed to retrieve IdP URL from CyberArk"
}

Write-Host "IdP URL received:" -ForegroundColor Green
Write-Host $idpUrl

# -----------------------------
# STEP 2: OPEN BROWSER & CAPTURE SAML RESPONSE
# -----------------------------

Write-Host "Opening browser for PingID authentication..." -ForegroundColor Yellow

$samlResponse = New-SAMLInteractive -LoginIDP $idpUrl

if (-not $samlResponse) {
    throw "Failed to capture SAMLResponse from PingID"
}

Write-Host "SAMLResponse captured successfully." -ForegroundColor Green
Write-Host "SAMLResponse length: $($samlResponse.Length)"

# -----------------------------
# STEP 3: CREATE psPAS SESSION
# -----------------------------

Write-Host "Creating psPAS session using SAMLResponse..." -ForegroundColor Yellow

$session = New-PASSession `
    -BaseURI $BaseURL `
    -SAMLResponse $samlResponse `
    -ConcurrentSession $true

Write-Host "psPAS SAML session established successfully!" -ForegroundColor Green

# -----------------------------
# STEP 4: VERIFY SESSION
# -----------------------------

Write-Host "Verifying session..." -ForegroundColor Yellow

$currentUser = Get-PASCurrentUser

Write-Host "Logged in as:" -ForegroundColor Green
$currentUser

Write-Host "SAML authentication test completed successfully." -ForegroundColor Cyan
