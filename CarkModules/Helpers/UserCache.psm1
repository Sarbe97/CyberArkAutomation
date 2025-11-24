# UserCache.psm1 - Manages cached user data with auto-refresh

function Get-CachedUserDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $true)]
        [string]$Username,
        
        [int]$RefreshDays = 7,
        
        [string]$CachePath = "$PSScriptRoot\..\Data\users.csv"
    )

    # Ensure Data directory exists
    $dataDir = Split-Path $CachePath
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    # Check if cache exists and is fresh
    $needsRefresh = $true
    if (Test-Path $CachePath) {
        $fileAge = (Get-Date) - (Get-Item $CachePath).LastWriteTime
        if ($fileAge.TotalDays -lt $RefreshDays) {
            $needsRefresh = $false
            Write-Host "[CACHE] Using existing user cache (age: $([math]::Round($fileAge.TotalDays, 1)) days)" -ForegroundColor Cyan
        }
        else {
            Write-Host "[CACHE] User cache is stale (age: $([math]::Round($fileAge.TotalDays, 1)) days). Refreshing..." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[CACHE] No user cache found. Creating new cache..." -ForegroundColor Yellow
    }

    # Load or create cache
    $userCache = @{}
    if (-not $needsRefresh) {
        # Load from CSV
        $cachedUsers = Import-Csv -Path $CachePath
        foreach ($user in $cachedUsers) {
            $userCache[$user.username] = $user
        }
        Write-Host "[CACHE] Loaded $($userCache.Count) users from cache" -ForegroundColor Green
    }
    else {
        # Fetch all users from CyberArk
        Write-Host "[API] Fetching all users from CyberArk..." -ForegroundColor Cyan
        $allUsers = Get-AllCyberArkUsers -PvwaUrl $PvwaUrl -Token $Token
        
        # Build cache and save to CSV
        $userList = @()
        foreach ($user in $allUsers) {
            $userObj = [PSCustomObject]@{
                id              = $user.id
                username        = $user.username
                enableUser      = $user.enableUser
                firstName       = if ($user.personalDetails.firstName) { $user.personalDetails.firstName } else { "" }
                middleName      = if ($user.personalDetails.middleName) { $user.personalDetails.middleName } else { "" }
                lastName        = if ($user.personalDetails.lastName) { $user.personalDetails.lastName } else { "" }
                title           = if ($user.personalDetails.title) { $user.personalDetails.title } else { "" }
                department      = if ($user.personalDetails.department) { $user.personalDetails.department } else { "" }
                source          = $user.source
                userType        = $user.userType
            }
            $userCache[$user.username] = $userObj
            $userList += $userObj
        }
        
        # Save to CSV
        $userList | Export-Csv -Path $CachePath -NoTypeInformation -Encoding UTF8
        Write-Host "[CACHE] Saved $($userList.Count) users to cache: $CachePath" -ForegroundColor Green
    }

    # Return requested user
    if ($userCache.ContainsKey($Username)) {
        return $userCache[$Username]
    }
    else {
        Write-Warning "[CACHE] User '$Username' not found in cache"
        return $null
    }
}

function Get-AllCyberArkUsers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $allUsers = @()
    $limit = 100
    $offset = 0

    Write-Host "[API] Fetching users (paginated)..." -ForegroundColor Cyan
    
    do {
        $uri = "$PvwaUrl/PasswordVault/API/Users?ExtendedDetails=true&limit=$limit&offset=$offset"
        $headers = @{ Authorization = $Token }
        
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -ContentType "application/json" -Method Get
            $users = $response.Users
            
            if ($users.Count -gt 0) {
                $allUsers += $users
                Write-Host "  Fetched $($users.Count) users (offset: $offset)" -ForegroundColor Gray
                $offset += $users.Count
            }
            else {
                break
            }
        }
        catch {
            Write-Warning "Failed to fetch users: $_"
            break
        }
    }
    while ($users.Count -eq $limit)

    Write-Host "[API] Total users fetched: $($allUsers.Count)" -ForegroundColor Green
    return $allUsers
}

Export-ModuleMember -Function Get-CachedUserDetails, Get-AllCyberArkUsers
