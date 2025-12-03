# ==========================
# Users.psm1 (Optimized - Return Only Core Fields)
# ==========================

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"
$Script:UserCache = $null              # In-memory cache (loaded once)
$Script:UserCacheLoadTime = $null      # Track when cache was loaded
#$Script:CacheExpireMinutes = 30        # Refresh cache every 30 minutes


$cfg = Get-CACConfig
$Script:CacheExpireMinutes = if ($cfg.UserCacheTTL) { [int]$cfg.UserCacheTTL } else { 30 }
# ============================================================
# Load user cache into memory (with TTL)
# ============================================================
function Initialize-CACUserCache {
    param(
        [bool]$Force = $false
    )

    Write-Log "Initializing user cache (Force: $Force)" "DEBUG"

    # Check if cache is still valid
    if (-not $Force -and $Script:UserCache -and $Script:UserCacheLoadTime) {
        $elapsed = (Get-Date) - $Script:UserCacheLoadTime
        if ($elapsed.TotalMinutes -lt $Script:CacheExpireMinutes) {
            Write-Log "User cache still valid (loaded $([Math]::Round($elapsed.TotalMinutes, 2)) minutes ago)" "DEBUG"
            return
        }
    }

    # Load from CSV file
    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "Cache file missing at: $Script:UserCachePath" "WARN"
        $Script:UserCache = $null
        return
    }

    try {
        $Script:UserCache = Import-Csv $Script:UserCachePath
        $Script:UserCacheLoadTime = Get-Date
        Write-Log "User cache loaded into memory. Records: $($Script:UserCache.Count)" "INFO"
    }
    catch {
        Write-Log "Failed to load cache: $($_.Exception.Message)" "ERROR"
        $Script:UserCache = $null
    }
}

# ============================================================
# Refresh full user cache from CyberArk (write to disk)
# ============================================================
function New-CACUserStore {
    Write-Log "Refreshing CyberArk user cache from API" "INFO"

    try {
        $users = Get-PASUser
        if (-not $users) {
            Write-Log "No PAS users returned" "ERROR"
            return
        }
    }
    catch {
        Write-Log "Failed fetching PAS users: $($_.Exception.Message)" "ERROR"
        return
    }

    $finalUsers = @()
    $counter = 1
    $total = $users.Count

    foreach ($u in $users) {
        Write-Log "Fetching full details ($counter/$total): $($u.id)" "DEBUG"

        try { $detail = Get-PASUser -id $u.id } 
        catch { $detail = $u }

        $first = $detail.personalDetails.firstName
        $middle = $detail.personalDetails.middleName
        $last = $detail.personalDetails.lastName
        $fullName = "$first $middle $last".Trim()

        # Extended user data - Store ALL fields
        $finalUsers += New-CACUserObject `
            -Id $detail.id `
            -UserName $detail.UserName `
            -FullName $fullName `
            -Email $detail.personalDetails.mail `
            -Department $detail.personalDetails.department `
            -Title $detail.personalDetails.title `
            -Organization $detail.personalDetails.organization `
            -Source $detail.source `
            -UserType $detail.userType `
            -Phone $detail.personalDetails.phone `
            -Mobile $detail.personalDetails.mobile `
            -Status $detail.userStatus

        $counter++
    }

    $folder = Split-Path $Script:UserCachePath
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }

    $finalUsers | Export-Csv -Path $Script:UserCachePath -NoTypeInformation -Encoding UTF8
    Write-Log "User cache saved to disk at: $Script:UserCachePath" "SUCCESS"
    Write-Log "Cache contains: Id, UserName, FullName, Email, Department, Title, Organization, Source, UserType, Phone, Mobile, Status, Created, LastLogin" "INFO"

    # Reload into memory
    Initialize-CACUserCache -Force $true
}

# ============================================================
# Get user details from in-memory cache (CORE FIELDS ONLY)
# ============================================================
function Get-CACUserDetailsFromStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputValue
    )

    Write-Log "Looking up user: $InputValue" "DEBUG"

    # Ensure cache is loaded
    Initialize-CACUserCache

    if (-not $Script:UserCache) {
        Write-Log "User cache empty, cannot lookup" "ERROR"
        return New-CACUserObject -UserName $InputValue
    }

    # Check if searching by ID (numeric)
    $searchById = $InputValue -match '^\d+$'

    if ($searchById) {
        $match = $Script:UserCache | Where-Object { $_.Id -eq $InputValue }
    }
    else {
        $match = $Script:UserCache | Where-Object { 
            $_.UserName -eq $InputValue -or $_.FullName -like "*$InputValue*" 
        }
    }

    if (-not $match) {
        Write-Log "No user found: $InputValue" "WARN"
        return New-CACUserObject -UserName $InputValue
    }

    # Return ONLY CORE FIELDS (Id, UserName, FullName, Department, Title, Organization)
    # Extended fields (Email, Phone, etc.) stored in CSV but NOT returned here
    return New-CACUserObject `
        -Id $match.Id `
        -UserName $match.UserName `
        -FullName $match.FullName `
        -Title $match.Title `
        -Department $match.Department
}

# ============================================================
# Get group members (ONLY Id and UserName, no enrichment)
# ============================================================
function Get-CACGroupUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    Write-Log "Fetching group: $GroupName" "INFO"

    try {
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true
    }
    catch {
        Write-Log "Group fetch failed: $($_.Exception.Message)" "ERROR"
        return
    }

    if (-not $group.Members) {
        Write-Log "Group has no members" "WARN"
        return
    }

    # Return ONLY member objects with Id and UserName
    # Do NOT call Get-CACUserDetailsFromStore here
    $output = @()
    foreach ($m in $group.Members) {
        $output += [PSCustomObject]@{
            Id       = $m.Id
            UserName = $m.UserName
        }
    }

    Write-Log "Retrieved $($output.Count) members from group: $GroupName" "INFO"
    return $output
}

# ============================================================
# EXPORT ALL PUBLIC FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    Initialize-CACUserCache, `
    New-CACUserStore, `
    Get-CACUserDetailsFromStore, `
    Get-CACGroupUsers
