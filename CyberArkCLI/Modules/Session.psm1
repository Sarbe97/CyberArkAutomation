# ============================================================================
# MODULE: Session.psm1
# DESCRIPTION: Session information and current user details
# ============================================================================

function Show-CACSessionDetails {
    <#
    .SYNOPSIS
        Displays combined session and user information in a single panel.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Show-CACSessionDetails()" "DEBUG"

    if (-not (Test-CACSession)) {
        Write-Host "Not logged in. Please login first." -ForegroundColor Yellow
        return
    }

    $session = Get-CACSession

    # --- Session Panel ---
    Write-Host ""
    Write-Host "===== Session Information =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Status:           Connected" -ForegroundColor Green
    Write-Host "  PVWA URL:         $($session.BaseURI)" -ForegroundColor White
    Write-Host "  User:             $($session.User)" -ForegroundColor White

    # Login method
    $loginMethod = if ($global:CACLoginMethod) { $global:CACLoginMethod } else { "Unknown" }
    Write-Host "  Login Method:     $loginMethod" -ForegroundColor White

    Write-Host "  Session Started:  $($session.StartTime)" -ForegroundColor White

    if ($session.StartTime) {
        $duration = (Get-Date) - $session.StartTime
        Write-Host "  Duration:         $([Math]::Floor($duration.TotalHours))h $($duration.Minutes)m" -ForegroundColor White
    }

    Write-Host "  Token Present:    $(if ($session.Token) { 'Yes' } else { 'No' })" -ForegroundColor White

    # --- User Details Panel ---
    Write-Host ""
    Write-Host "===== User Details =====" -ForegroundColor Cyan
    Write-Host ""

    $user = $null
    try {
        $user = Invoke-CACAPIRequest -Method GET -Endpoint "/WebServices/PIMServices.svc/User"
    }
    catch {
        Write-Log "PIMServices User API failed: $($_.Exception.Message)" "WARN"
    }

    if ($user) {
        $userName = if ($user.UserName) { $user.UserName }     elseif ($user.username) { $user.username }  else { $session.User }
        $firstName = if ($user.FirstName) { $user.FirstName }    elseif ($user.firstName) { $user.firstName } else { "-" }
        $lastName = if ($user.LastName) { $user.LastName }     elseif ($user.lastName) { $user.lastName }  else { "-" }
        $email = if ($user.Email) { $user.Email }        elseif ($user.email) { $user.email }     else { "-" }
        $location = if ($user.Location) { $user.Location }     elseif ($user.location) { $user.location }  else { "-" }
        $userType = if ($user.UserTypeName) { $user.UserTypeName } elseif ($user.userType) { $user.userType }  else { "-" }

        Write-Host "  User Name:        $userName" -ForegroundColor White
        Write-Host "  First Name:       $firstName" -ForegroundColor White
        Write-Host "  Last Name:        $lastName" -ForegroundColor White
        Write-Host "  Email:            $email" -ForegroundColor White
        Write-Host "  Location:         $location" -ForegroundColor White
        Write-Host "  User Type:        $userType" -ForegroundColor White
    }
    else {
        Write-Host "  (Could not retrieve user details from PIM Services)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host ""
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

Export-ModuleMember -Function Show-CACSessionDetails, Show-CACSessionHeader
