function Get-CATKCachedUser {
    <#
    .SYNOPSIS
        Retrieves CyberArk user details from local JSON cache.
        If the cache is missing or expired, it will refresh it.
        Lookup supports Username OR UserID.

    .PARAMETER Query
        Username or Numeric User ID.

    .PARAMETER Session
        CATK session object (Connect-CATK output).

    .PARAMETER MaxAgeHours
        Cache expiry time. Default 24h (same as Initialize-CATKUserCache).
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $Query,

        [Parameter(Mandatory=$true)]
        $Session,

        [int] $MaxAgeHours = 24
    )

    # ----------------------------
    # Cache file location
    # ----------------------------
    $cacheFile = Join-Path $Global:CATK_CachePath 'UserList.json'

    # ----------------------------
    # Checks cache age
    # ----------------------------
    function Get-CacheAge {
        if (-not (Test-Path $cacheFile)) { return [double]::MaxValue }
        return ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalHours
    }

    # ----------------------------
    # Refresh cache logic
    # ----------------------------
    function Refresh-UserCache {
        try {
            Write-Host "Refreshing user cache from CyberArk..." -ForegroundColor Cyan

            $all = @()
            $limit = 100
            $offset = 0

            do {
                $page = Get-PASUser -Session $Session.Session -Limit $limit -Offset $offset -ErrorAction Stop

                if ($page -isnot [System.Collections.IEnumerable]) { $page = @($page) }
                if (-not $page) { break }

                $all += $page
                $offset += $page.Count
            }
            while ($page.Count -eq $limit)

            # Save JSON
            $all | ConvertTo-Json -Depth 6 | Out-File -FilePath $cacheFile -Encoding UTF8
            Write-Host "User cache updated. Total: $($all.Count)" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Warning "Failed to refresh user cache: $_"
            return $false
        }
    }

    # ----------------------------
    # Ensure cache exists or is fresh
    # ----------------------------
    if (-not (Test-Path $cacheFile) -or (Get-CacheAge) -gt $MaxAgeHours) {
        if (-not (Refresh-UserCache)) {
            return $null
        }
    }

    # ----------------------------
    # Load cached users
    # ----------------------------
    try {
        $users = Get-Content $cacheFile | ConvertFrom-Json
    }
    catch {
        Write-Warning "User cache file corrupted — rebuilding..."
        if (-not (Refresh-UserCache)) { return $null }
        $users = Get-Content $cacheFile | ConvertFrom-Json
    }

    if (-not $users) { return $null }

    # ----------------------------
    # Query: detect numeric UserID vs Username
    # ----------------------------
    $match =
        if ($Query -match '^\d+$') {
            # ID lookup
            $users | Where-Object { $_.id -eq $Query }
        }
        else {
            # username lookup
            $users | Where-Object { $_.username -eq $Query }
        }

    return $match
}
