# ============================================================================
# MODULE: Session.psm1
# DESCRIPTION: Session information and current user details
# ============================================================================

function Get-CACCurrentUser {
    <#
    .SYNOPSIS
        Get details of the currently logged in user.
    .DESCRIPTION
        Calls the /API/LoggedOnUser endpoint to retrieve current session user information.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACCurrentUser()" "DEBUG"

    try {
        if (-not (Test-CACSession)) {
            Write-Host "Not logged in. Please login first." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching current user details..." -ForegroundColor Cyan

        # Get logged on user details
        $user = Invoke-CACAPIRequest -Method GET -Endpoint "/API/LoggedOnUser"

        if (-not $user) {
            Write-Host "Could not retrieve user details." -ForegroundColor Yellow
            return
        }

        # Get session info
        $session = Get-CACSession

        Write-Host ""
        Write-Host "===== Current Session Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  User Name:        $($user.Username)" -ForegroundColor White
        Write-Host "  User Source:      $($user.Source)" -ForegroundColor White
        Write-Host "  User Type:        $($user.UserType)" -ForegroundColor White
        Write-Host "  Component User:   $($user.ComponentUser)" -ForegroundColor White
        Write-Host ""
        Write-Host "===== Connection Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  PVWA URL:         $($session.BaseURI)" -ForegroundColor White
        Write-Host "  Session Started:  $($session.StartTime)" -ForegroundColor White
        
        # Calculate session duration
        if ($session.StartTime) {
            $duration = (Get-Date) - $session.StartTime
            Write-Host "  Session Duration: $([Math]::Floor($duration.TotalMinutes)) minutes" -ForegroundColor White
        }
        Write-Host ""

        # Return user object for programmatic use
        return [PSCustomObject]@{
            Username      = $user.Username
            Source        = $user.Source
            UserType      = $user.UserType
            ComponentUser = $user.ComponentUser
            BaseURI       = $session.BaseURI
            SessionStart  = $session.StartTime
        }
    }
    catch {
        Write-Log "Error in Get-CACCurrentUser(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-CACSessionInfo {
    <#
    .SYNOPSIS
        Display current session information.
    #>
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
    Write-Host "  Session Started:  $($session.StartTime)" -ForegroundColor White
    
    if ($session.StartTime) {
        $duration = (Get-Date) - $session.StartTime
        Write-Host "  Duration:         $([Math]::Floor($duration.TotalHours))h $($duration.Minutes)m" -ForegroundColor White
    }
    
    Write-Host "  Token Present:    $(if ($session.Token) { 'Yes' } else { 'No' })" -ForegroundColor White
    Write-Host ""

    return $session
}

Export-ModuleMember -Function Get-CACCurrentUser, Get-CACSessionInfo
