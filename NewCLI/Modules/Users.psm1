# ============================================================================
# MODULE: Users.psm1
# DESCRIPTION: User and Group operations using raw CyberArk REST API
# ============================================================================

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"
$Script:UserCache = $null
$Script:UserCacheLoadTime = $null

# ============================================================
# USER CACHE - Initialize
# ============================================================
function Initialize-CACUserCache {
    param([bool]$Force = $false)

    Write-Log "Initializing user cache (Force: $Force)" "DEBUG"

    $config = Get-CACConfig
    $cacheExpireMinutes = if ($config.UserCacheTTL) { [int]$config.UserCacheTTL } else { 30 }

    # Check if cache is still valid
    if (-not $Force -and $Script:UserCache -and $Script:UserCacheLoadTime) {
        $elapsed = (Get-Date) - $Script:UserCacheLoadTime
        if ($elapsed.TotalMinutes -lt $cacheExpireMinutes) {
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
# USER CACHE - Refresh from CyberArk
# ============================================================
function New-CACUserStore {
    [CmdletBinding()]
    param()

    Write-Log "Starting User Cache Refresh (Querying Vault...)" "INFO"
    Write-Host "Refreshing user cache from CyberArk..." -ForegroundColor Cyan

    try {
        Write-Progress -Activity "User Cache Refresh" -Status "Fetching user list..." -PercentComplete 0
        
        $allUsers = @()
        $offset = 0
        $limit = 100

        # Paginate through all users
        do {
            $endpoint = "/API/Users?limit=$limit&offset=$offset"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
            
            $users = @()
            if ($response.Users) { $users = @($response.Users) }
            elseif ($response.value) { $users = @($response.value) }
            
            if ($users.Count -eq 0) { break }
            
            $allUsers += $users
            $offset += $limit
            
            Write-Progress -Activity "User Cache Refresh" -Status "Fetched $($allUsers.Count) users..." -PercentComplete 50
        } while ($users.Count -eq $limit)

        if ($allUsers.Count -eq 0) {
            Write-Log "No users returned from Vault" "WARN"
            Write-Progress -Activity "User Cache Refresh" -Completed
            return
        }

        Write-Log "Found $($allUsers.Count) users. Processing..." "INFO"
    }
    catch {
        Write-Log "Failed fetching users: $($_.Exception.Message)" "ERROR"
        Write-Host "Error fetching users: $($_.Exception.Message)" -ForegroundColor Red
        Write-Progress -Activity "User Cache Refresh" -Completed
        return
    }

    $finalUsers = @()
    $counter = 0
    $total = $allUsers.Count

    foreach ($u in $allUsers) {
        $counter++
        $percent = ($counter / $total) * 100
        Write-Progress -Activity "User Cache Refresh" -Status "Processing $counter of $total : $($u.username)" -PercentComplete $percent

        # Fetch full details for specific user
        $userDetails = $u
        try { 
            $userDetails = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users/$($u.id)"
        } 
        catch { 
            Write-Log "Could not fetch details for user $($u.username). Using basic info. Error: $($_.Exception.Message)" "WARN"
        }

        # Build flattened user object
        $fullName = ""
        if ($userDetails.personalDetails) {
            $first = $userDetails.personalDetails.firstName
            $last = $userDetails.personalDetails.lastName
            $fullName = "$first $last".Trim()
        }
        if (-not $fullName) { $fullName = $userDetails.username }

        $statusStr = if ($userDetails.suspended -eq $true) { "Suspended" } else { "Active" }

        $userObj = New-CACUserObject `
            -Id $userDetails.id `
            -UserName $userDetails.username `
            -FullName $fullName `
            -Email $(if ($userDetails.internet) { $userDetails.internet.businessEmail } else { "" }) `
            -Phone $(if ($userDetails.phones) { $userDetails.phones.cellularNumber } else { "" }) `
            -Department $(if ($userDetails.personalDetails) { $userDetails.personalDetails.department } else { "" }) `
            -Title $(if ($userDetails.personalDetails) { $userDetails.personalDetails.title } else { "" }) `
            -Organization $(if ($userDetails.personalDetails) { $userDetails.personalDetails.organization } else { "" }) `
            -Source $userDetails.source `
            -UserType $userDetails.userType `
            -Status $statusStr

        $finalUsers += $userObj
    }

    Write-Progress -Activity "User Cache Refresh" -Completed

    # Save to disk
    $dataFolder = "$PSScriptRoot/../Data"
    if (-not (Test-Path $dataFolder)) { New-Item -ItemType Directory -Path $dataFolder | Out-Null }
    
    $Script:UserCachePath = "$dataFolder/users_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    try {
        $finalUsers | Export-Csv -Path $Script:UserCachePath -NoTypeInformation -Encoding UTF8
        Write-Log "User cache saved: $Script:UserCachePath" "SUCCESS"
        Write-Host "Cache saved: $Script:UserCachePath ($($finalUsers.Count) users)" -ForegroundColor Green
    }
    catch {
        Write-Log "Failed to write cache: $($_.Exception.Message)" "ERROR"
    }

    # Reload into memory
    Initialize-CACUserCache -Force $true
}

# ============================================================
# USER CACHE - Get User Details
# ============================================================
function Get-CACUserDetailsFromStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputValue
    )

    Write-Log "Looking up user in cache: $InputValue" "DEBUG"

    Initialize-CACUserCache

    if (-not $Script:UserCache) {
        Write-Log "User cache empty/missing" "WARN"
        return New-CACUserObject -UserName $InputValue -FullName "Unknown"
    }

    # Search by ID or Name
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
        return New-CACUserObject -Id "N/A" -UserName $InputValue -FullName "Not Found"
    }

    return New-CACUserObject `
        -Id $match.Id `
        -UserName $match.UserName `
        -FullName $match.FullName `
        -Email $match.Email `
        -Phone $match.Phone `
        -Department $match.Department `
        -Title $match.Title `
        -Status $match.Status
}

# ============================================================
# GROUPS - Get All Groups
# ============================================================
function Get-CACAllGroups {
    [CmdletBinding()]
    param(
        [ValidateSet("All", "Vault", "Directory")]
        [string]$GroupType = "All",

        [switch]$IncludeMembers,

        [bool]$ExportToCSV = $true
    )

    Write-Log "Started Get-CACAllGroups()" "DEBUG"

    try {
        $queryParams = @()
        
        if ($GroupType -ne "All") {
            $queryParams += "filter=groupType eq $GroupType"
        }
        
        if ($IncludeMembers) {
            $queryParams += "includeMembers=true"
        }

        $endpoint = "/API/UserGroups/"
        if ($queryParams.Count -gt 0) {
            $endpoint += "?" + ($queryParams -join "&")
        }

        Write-Host "Fetching groups from CyberArk..." -ForegroundColor Cyan

        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $groups = @()
        if ($response.value) { $groups = @($response.value) }
        elseif ($response -is [array]) { $groups = @($response) }
        else { $groups = @($response) }

        if ($groups.Count -eq 0) {
            Write-Host "No groups found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($groups.Count) groups" "INFO"

        $formattedGroups = @()
        $counter = 0

        foreach ($group in $groups) {
            $counter++
            Write-Progress -Activity "Processing Groups" -Status "$counter of $($groups.Count)" -PercentComplete (($counter / $groups.Count) * 100)

            $groupRecord = New-CACGroupObject `
                -Id $group.id `
                -GroupName $group.groupName `
                -Description $group.description `
                -GroupType $group.groupType `
                -Directory $group.directory `
                -MemberCount $(if ($group.members) { $group.members.Count } else { 0 })

            $formattedGroups += $groupRecord
        }

        Write-Progress -Activity "Processing Groups" -Completed

        # Display summary
        Write-Host ""
        Write-Host "===== Groups Summary =====" -ForegroundColor Cyan
        Write-Host "Total Groups: $($formattedGroups.Count)"
        
        $vaultCount = ($formattedGroups | Where-Object { $_.GroupType -eq "Vault" }).Count
        $directoryCount = ($formattedGroups | Where-Object { $_.GroupType -eq "Directory" }).Count
        
        Write-Host "  Vault (Internal): $vaultCount"
        Write-Host "  Directory (LDAP): $directoryCount"
        Write-Host ""

        $formattedGroups | Format-Table GroupName, GroupType, Description, MemberCount -AutoSize

        if ($ExportToCSV) {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/groups_$timestamp.csv"

            $formattedGroups | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedGroups
    }
    catch {
        Write-Log "Error in Get-CACAllGroups(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# GROUPS - Get Group Members
# ============================================================
function Get-CACGroupMembers {
    [CmdletBinding()]
    param(
        [string]$GroupName
    )

    Write-Log "Started Get-CACGroupMembers()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            $GroupName = Read-Host "Enter Group Name"
            if ([string]::IsNullOrWhiteSpace($GroupName)) {
                Write-Host "Group name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Fetching members for group: $GroupName..." -ForegroundColor Cyan

        $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))&includeMembers=true"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $groups = @()
        if ($response.value) { $groups = @($response.value) }
        elseif ($response -is [array]) { $groups = @($response) }
        else { $groups = @($response) }

        $matchingGroup = $groups | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1

        if (-not $matchingGroup) {
            Write-Host "Group '$GroupName' not found." -ForegroundColor Yellow
            return
        }

        if (-not $matchingGroup.members -or $matchingGroup.members.Count -eq 0) {
            Write-Host "Group '$GroupName' has no members." -ForegroundColor Yellow
            return
        }

        $members = $matchingGroup.members | ForEach-Object {
            [PSCustomObject]@{
                UserID   = $_.id
                UserName = $_.userName
            }
        }

        Write-Host ""
        Write-Host "===== Members of '$GroupName' =====" -ForegroundColor Cyan
        Write-Host "Total Members: $($members.Count)"
        Write-Host ""

        $members | Format-Table -AutoSize

        return $members
    }
    catch {
        Write-Log "Error in Get-CACGroupMembers(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# GROUPS - Get Group Users (Lightweight)
# ============================================================
function Get-CACGroupUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    Write-Log "Fetching members for group: $GroupName" "INFO"

    try {
        $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))&includeMembers=true"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $groups = @()
        if ($response.value) { $groups = @($response.value) }
        elseif ($response -is [array]) { $groups = @($response) }

        $group = $groups | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1

        if (-not $group -or -not $group.members) {
            Write-Log "Group '$GroupName' has no members" "WARN"
            return $null
        }

        # Return lightweight objects
        $output = @()
        foreach ($m in $group.members) {
            $output += [PSCustomObject]@{
                Id       = $m.id
                UserName = $m.userName
            }
        }

        Write-Log "Retrieved $($output.Count) members from $GroupName" "DEBUG"
        return $output
    }
    catch {
        Write-Log "Group fetch failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Initialize-CACUserCache, `
    New-CACUserStore, `
    Get-CACUserDetailsFromStore, `
    Get-CACAllGroups, `
    Get-CACGroupMembers, `
    Get-CACGroupUsers
