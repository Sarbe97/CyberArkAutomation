
# ==========================
# Users.psm1
# ==========================

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"
$Script:UserCache = $null              # In-memory cache
$Script:UserCacheLoadTime = $null      # Track load time

# Load TTL from config or default to 30 mins
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
            Write-Log "User cache valid (Loaded $([Math]::Round($elapsed.TotalMinutes, 2)) mins ago)" "DEBUG"
            return
        }
    }

    # Load from CSV file
    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "Cache file missing: $Script:UserCachePath" "WARN"
        $Script:UserCache = $null
        return
    }

    try {
        $Script:UserCache = Import-Csv $Script:UserCachePath
        $Script:UserCacheLoadTime = Get-Date
        Write-Log "User cache loaded. Total Records: $($Script:UserCache.Count)" "INFO"
    }
    catch {
        Write-Log "Failed to load user cache: $($_.Exception.Message)" "ERROR"
        $Script:UserCache = $null
    }
}

# ============================================================
# Refresh full user cache from CyberArk (write to disk)
# ============================================================
function New-CACUserStore {
    Write-Log "Starting User Cache Refresh (Querying Vault...)" "INFO"

    # 1. Fetch All Users (High level list)
    try {
        Write-Progress -Activity "User Cache Refresh" -Status "Fetching user list..." -PercentComplete 0
        $users = Get-PASUser
        
        if (-not $users) {
            Write-Log "No users returned from Vault" "WARN"
            Write-Progress -Activity "User Cache Refresh" -Completed
            return
        }
    }
    catch {
        Write-Log "Failed fetching PAS users: $($_.Exception.Message)" "ERROR"
        Write-Progress -Activity "User Cache Refresh" -Completed
        return
    }

    $finalUsers = @()
    $counter = 0
    $total = $users.Count

    Write-Log "Found $total users. Fetching details..." "INFO"

    # 2. Iterate and Fetch Details
    foreach ($u in $users) {
        $counter++
        $percent = ($counter / $total) * 100
        
        # --- PROGRESS BAR ---
        Write-Progress -Activity "User Cache Refresh" `
            -Status "Processing $counter of $total : $($u.UserName)" `
            -PercentComplete $percent
        # --------------------

        try { 
            # Fetch full details for specific user
            $userDetail = Get-PASUser -id $u.id -ErrorAction Stop
        } 
        catch { 
            Write-Log "Could not fetch details for user $($u.UserName). Using basic info." "WARN"
            $userDetail = $u 
        }

        # --- Name Construction ---
        $first    = $userDetail.personalDetails.firstName
        $middle   = $userDetail.personalDetails.middleName
        $last     = $userDetail.personalDetails.lastName
        $fullName = "$first $middle $last".Trim()
        if (-not $fullName) { $fullName = $userDetail.UserName }

        # --- Status Logic (Suspended vs Active) ---
        $statusStr = "Active"
        if ($userDetail.suspended -eq $true) {
            $statusStr = "Suspended"
        }

        # --- Create Flattened Object ---
        # We use [PSCustomObject] directly to ensure exact column names for the CSV
        $userObj = [PSCustomObject]@{
            Id           = $userDetail.id
            UserName     = $userDetail.UserName
            FullName     = $fullName
            UserType     = $userDetail.userType
            Source       = $userDetail.source
            
            # Contact Info (Internet & Phones Sections)
            Email        = $userDetail.internet.businessEmail
            Phone        = $userDetail.phones.cellularNumber
            
            # Organization Info
            Department   = $userDetail.personalDetails.department
            Title        = $userDetail.personalDetails.title
            Organization = $userDetail.personalDetails.organization
            
            # Status & Login
            Status       = $statusStr
            LastLogon    = $userDetail.lastSuccessfulLoginDate
        }

        $finalUsers += $userObj
    }

    # Close Progress Bar
    Write-Progress -Activity "User Cache Refresh" -Completed

        # 3. Save to Disk (With Timestamp)
    # Update the cache path variable dynamically with the current time
    $Script:UserCachePath = "$PSScriptRoot/../Data/users_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    $folder = Split-Path $Script:UserCachePath
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }

    try {
        $finalUsers | Export-Csv -Path $Script:UserCachePath -NoTypeInformation -Encoding UTF8
        Write-Log "User cache saved to disk: $Script:UserCachePath" "SUCCESS"
        Write-Log "Cache refreshed with $($finalUsers.Count) users." "INFO"
    }
    catch {
        Write-Log "Failed to write cache to CSV: $($_.Exception.Message)" "ERROR"
    }

    # 4. Reload into memory immediately
    Initialize-CACUserCache -Force $true
}

# ============================================================
# Get user details from in-memory cache
# ============================================================
function Get-CACUserDetailsFromStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputValue
    )

    Write-Log "Looking up user in cache: $InputValue" "DEBUG"

    # Ensure cache is loaded
    Initialize-CACUserCache

    if (-not $Script:UserCache) {
        Write-Log "User cache empty/missing. Returning basic object." "WARN"
        return [PSCustomObject]@{ Id = $null; UserName = $InputValue; FullName = "Unknown" }
    }

    # Search Logic (ID vs Name)
    $searchById = $InputValue -match '^\d+$'
    $match = $null

    if ($searchById) {
        $match = $Script:UserCache | Where-Object { $_.Id -eq $InputValue }
    }
    else {
        $match = $Script:UserCache | Where-Object { 
            $_.UserName -eq $InputValue -or $_.FullName -like "*$InputValue*" 
        } | Select-Object -First 1
    }

    if (-not $match) {
        Write-Log "User not found in cache: $InputValue" "WARN"
        # Return a shell object so scripts don't break on $null
        return [PSCustomObject]@{ 
            Id = "N/A"
            UserName = $InputValue
            FullName = "Not Found" 
        }
    }

    # Return the mapped object
    # Note: CSV Import creates strings, so we return them as-is
    return [PSCustomObject]@{
        Id           = $match.Id
        UserName     = $match.UserName
        FullName     = $match.FullName
        Email        = $match.Email
        Phone        = $match.Phone
        Department   = $match.Department
        Title        = $match.Title
        Status       = $match.Status
        LastLogon    = $match.LastLogon
    }
}

# ============================================================
# Get group members (Only Id and UserName)
# ============================================================
function Get-CACGroupUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    Write-Log "Fetching members for group: $GroupName" "INFO"

    try {
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true
    }
    catch {
        Write-Log "Group fetch failed: $($_.Exception.Message)" "ERROR"
        return $null
    }

    if (-not $group.Members) {
        Write-Log "Group '$GroupName' has no members" "WARN"
        return $null
    }

    # Return lightweight objects
    $output = @()
    foreach ($m in $group.Members) {
        $output += [PSCustomObject]@{
            Id       = $m.Id
            UserName = $m.UserName
        }
    }

    Write-Log "Retrieved $($output.Count) members from $GroupName" "DEBUG"
    return $output
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Initialize-CACUserCache, `
    New-CACUserStore, `
    Get-CACUserDetailsFromStore, `
    Get-CACGroupUsers
