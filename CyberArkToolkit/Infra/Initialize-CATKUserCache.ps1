function Initialize-CATKUserCache {
    <#
    .SYNOPSIS
        Creates or refreshes cached user list (full users list) used for enrichment.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [switch] $ForceRefresh,
        [switch] $ForceIfMissing
    )

    $cacheFile = Join-Path $Global:CATK_CachePath 'UserList.json'

    function GetCacheAge {
        if (-not (Test-Path $cacheFile)) { return [double]::MaxValue }
        return ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalHours
    }

    $refreshNeeded = $ForceRefresh

    if ($ForceIfMissing -and -not (Test-Path $cacheFile)) {
        $refreshNeeded = $true
    }
    elseif ((GetCacheAge) -gt 24) {
        $refreshNeeded = $true
    }

    if (-not $refreshNeeded) {
        Write-Host "User cache is fresh (<=24 hours)." -ForegroundColor DarkGreen
        return
    }

    Write-Host "Refreshing CyberArk user cache..." -ForegroundColor Cyan

    $all = @()
    $limit = 100
    $offset = 0

    try {
        do {
            $page = Get-PASUser -Session $Session.Session -Limit $limit -Offset $offset -ErrorAction Stop
            if (-not $page) { break }

            if ($page -isnot [System.Collections.IEnumerable]) { $page = @($page) }

            $all += $page
            $offset += $page.Count
        }
        while ($page.Count -eq $limit)

        $all | ConvertTo-Json -Depth 6 | Out-File -FilePath $cacheFile -Encoding UTF8

        Write-Host "User cache updated. Total users cached: $($all.Count)" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to refresh user cache: $_"
    }
}
