function Get-CATKCachedUser {
    <#
    .SYNOPSIS
        Returns a CyberArk user from the CSV cache.
        Automatically refreshes cache if missing or older than X days.
        Supports lookup by Username OR User ID.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,       # Username or ID

        [Parameter()]
        $Session,

        [int] $MaxAgeDays = 7
    )

    $cacheFile = Join-Path $Global:CATK_CachePath "UserList.csv"

    function _WriteCache {
        try {
            Write-Host "Fetching user list from CyberArk..." -ForegroundColor Cyan

            $result = Get-PASUser -Search '*' -SessionToken $Session.SessionToken

            $rows = foreach ($u in $result.Users) {
                [PSCustomObject]@{
                    Id           = $u.id
                    Username     = $u.username
                    Source       = $u.source
                    UserType     = $u.userType
                    Location     = $u.location

                    FirstName    = $u.personalDetails.firstName
                    MiddleName   = $u.personalDetails.middleName
                    LastName     = $u.personalDetails.lastName
                    Title        = $u.personalDetails.title
                    Organization = $u.personalDetails.organization
                    Department   = $u.personalDetails.department
                    Profession   = $u.personalDetails.profession

                    Groups       = ($u.groupsMembership.groupName -join ';')
                }
            }

            $rows | Export-Csv -Path $cacheFile -NoTypeInformation -Encoding UTF8
            Write-Host "User cache updated → $cacheFile" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Warning "Failed to refresh user cache: $_"
            return $false
        }
    }

    # Ensure cache exists or refreshed
    if (-not (Test-Path $cacheFile)) {
        Write-Host "User cache missing — creating..." -ForegroundColor Yellow
        if (-not (_WriteCache)) { return $null }
    }
    else {
        $fileAge = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($fileAge.Days -ge $MaxAgeDays) {
            Write-Host "User cache older than $MaxAgeDays days — refreshing..." -ForegroundColor Yellow
            if (-not (_WriteCache)) { return $null }
        }
    }

    # Load cache
    try {
        $cache = Import-Csv $cacheFile
    }
    catch {
        Write-Warning "Error reading cache file: $_"
        return $null
    }

    # -----------------------------
    # SEARCH: detect ID vs Username
    # -----------------------------
    if ($Query -match '^\d+$') {
        # numeric → match ID
        return $cache | Where-Object { $_.Id -eq $Query }
    }
    else {
        # string → match Username
        return $cache | Where-Object { $_.Username -eq $Query }
    }
}
