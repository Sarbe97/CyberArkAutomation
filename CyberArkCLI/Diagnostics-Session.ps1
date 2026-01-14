# Diagnostic Check PASSession After SAML Login
# This script should be run immediately after SAML login via cli.ps1
# It shows the contents of the psPAS session

Write-Host ""
Write-Host "PAS SESSION DIAGNOSTICS"
Write-Host ""

# 1. Check if psPAS module is loaded
Write-Host "1 Checking psPAS module"
$mod = Get-Module psPAS
if ($mod) {
    Write-Host "psPAS loaded Version $($mod.Version)"
}
else {
    Write-Host "psPAS NOT loaded"
}

# 2. Get PASSession
Write-Host ""
Write-Host "2 Getting PASSession"
$session = Get-PASSession -ErrorAction SilentlyContinue

if ($null -eq $session) {
    Write-Host "Get-PASSession returned NULL"
    Write-Host "This means the reflection injection failed"
    Write-Host "Check the login log for errors"
    exit
}

Write-Host "Session object exists"
Write-Host "Type $($session.GetType().FullName)"

# 3. Check BaseURI
Write-Host ""
Write-Host "3 Checking BaseURI"
if ($null -eq $session.BaseURI) {
    Write-Host "BaseURI is NULL"
}
else {
    Write-Host "BaseURI exists"
    Write-Host "Value $($session.BaseURI)"
    Write-Host "Type $($session.BaseURI.GetType().FullName)"
    Write-Host "ToString $($session.BaseURI.ToString())"
}

# 4. Check WebSession
Write-Host ""
Write-Host "4 Checking WebSession"
if ($null -eq $session.WebSession) {
    Write-Host "WebSession is NULL"
}
else {
    Write-Host "WebSession exists"
    if ($session.WebSession.Headers -and $session.WebSession.Headers["Authorization"]) {
        Write-Host "Authorization Header Present"
        Write-Host "Token Length $($session.WebSession.Headers["Authorization"].Length)"
    }
    else {
        Write-Host "Authorization Header MISSING"
    }
}

# 5. Check Global CACSession
Write-Host ""
Write-Host "5 Checking Global CACSession"
if ($null -eq $global:CACSession) {
    Write-Host "Global CACSession is NULL"
}
elseif ($null -eq $global:CACSession.BaseURI) {
    Write-Host "Global CACSession exists but BaseURI is NULL"
}
else {
    Write-Host "Global CACSession exists with BaseURI"
    Write-Host "BaseURI $($global:CACSession.BaseURI)"
}

# 6. Test a simple psPAS command
Write-Host ""
Write-Host "6 Testing Get-PASSafe command"
try {
    $testSafe = Get-PASSafe -ErrorAction Stop | Select-Object -First 1
    Write-Host "SUCCESS Retrieved $($testSafe.SafeName)"
}
catch {
    Write-Host "FAILED"
    Write-Host "Error $($_.Exception.Message)"
}

Write-Host ""
Write-Host "DIAGNOSTICS COMPLETE"
Write-Host ""

Write-Host "If BaseURI is NULL after injection the issue is in Login.psm1"
Write-Host "Check the logs at CyberArkCLI Logs cyberark_date.log"
