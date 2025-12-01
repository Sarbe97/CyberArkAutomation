# Login.psm1
Import-Module psPAS -ErrorAction Stop
$loginFormScript = Join-Path $PSScriptRoot "LoginForm.ps1"
if (-not (Test-Path $loginFormScript)) {
    throw "LoginForm.ps1 not found: $loginFormScript"
}
. $loginFormScript   # <-- dot-source the UI function


function Invoke-CACLogin {
    $cfg = Get-CACConfig

    # Show form
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

function Invoke-CACLogout {
    try {
        if ($global:CACSession) {
            Close-PASSession -Session $global:CACSession -ErrorAction SilentlyContinue
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
