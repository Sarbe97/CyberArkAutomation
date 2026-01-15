# ============================================================================
# MODULE: Session.psm1
# DESCRIPTION: Session information and current user details
# ============================================================================

function Get-CACCurrentUser {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACCurrentUser()" "DEBUG"

    try {
        if (-not (Test-CACSession)) {
            Write-Host "Not logged in. Please login first." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching current user details..." -ForegroundColor Cyan

        # Use the legacy PIM Services API for user info
        $user = Invoke-CACAPIRequest -Method GET -Endpoint "/WebServices/PIMServices.svc/User"

        if (-not $user) {
            Write-Host "Could not retrieve user details." -ForegroundColor Yellow
            return
        }

        # Get session info
        $session = Get-CACSession

        Write-Host ""
        Write-Host "===== Current User Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  User Name:        $($user.UserName)" -ForegroundColor White
        Write-Host "  First Name:       $($user.FirstName)" -ForegroundColor White
        Write-Host "  Last Name:        $($user.LastName)" -ForegroundColor White
        Write-Host "  Email:            $($user.Email)" -ForegroundColor White
        Write-Host "  Location:         $($user.Location)" -ForegroundColor White
        Write-Host "  User Type:        $($user.UserTypeName)" -ForegroundColor White
        Write-Host "  Vault Auth:       $($user.VaultAuthorization -join ', ')" -ForegroundColor White
        Write-Host ""
        Write-Host "===== Connection Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  PVWA URL:         $($session.BaseURI)" -ForegroundColor White
        Write-Host "  Session Started:  $($session.StartTime)" -ForegroundColor White
        
        if ($session.StartTime) {
            $duration = (Get-Date) - $session.StartTime
            Write-Host "  Session Duration: $([Math]::Floor($duration.TotalMinutes)) minutes" -ForegroundColor White
        }
        Write-Host ""

        return $user
    }
    catch {
        Write-Log "Error in Get-CACCurrentUser(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-CACSessionInfo {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACSessionInfo()" "DEBUG"

    if (-not (Test-CACSession)) {
        Write-Host "Not logged in." -ForegroundColor Yellow
        return
    }

    $session = Get-CACSession

    Write-Host ""
    Write-Host "===== Session Information =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Connected:        Yes" -ForegroundColor Green
    Write-Host "  PVWA URL:         $($session.BaseURI)" -ForegroundColor White
    Write-Host "  User:             $($session.User)" -ForegroundColor White
    Write-Host "  Session Started:  $($session.StartTime)" -ForegroundColor White
    
    if ($session.StartTime) {
        $duration = (Get-Date) - $session.StartTime
        Write-Host "  Duration:         $([Math]::Floor($duration.TotalHours))h $($duration.Minutes)m" -ForegroundColor White
    }
    
    Write-Host "  Token Present:    $(if ($session.Token) { 'Yes' } else { 'No' })" -ForegroundColor White
    Write-Host ""

    return $session
}

function Show-CACSessionHeader {
    $session = Get-CACSession
    if ($session) {
        Write-Host "URL:    $($session.BaseURI)" -ForegroundColor DarkCyan
        Write-Host "User:   $($session.User)" -ForegroundColor DarkCyan
        if ($session.StartTime) {
            Write-Host "Since:  $($session.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkCyan
        }
    }
}

Export-ModuleMember -Function Get-CACCurrentUser, Get-CACSessionInfo, Show-CACSessionHeader
