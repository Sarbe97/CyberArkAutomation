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
    <#
    .SYNOPSIS
        Refreshes the user cache by querying all users from CyberArk Vault.
    .PARAMETER Force
        Skip confirmation prompt and force refresh.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    Write-Log "Starting User Cache Refresh (Querying Vault...)" "INFO"
    Write-Host "Refreshing user cache from CyberArk..." -ForegroundColor Cyan

    # Use List<T> for better performance
    $allUsers = [System.Collections.Generic.List[object]]::new()

    try {
        Write-Progress -Activity "User Cache Refresh" -Status "Fetching user list..." -PercentComplete 0
        Write-Host "  Fetching user list..." -ForegroundColor DarkGray
        
        $offset = 0
        $limit = 100
        $pageNum = 0

        # Paginate through all users
        do {
            $pageNum++
            $endpoint = "/API/Users?limit=$limit&offset=$offset"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
            
            $users = ConvertTo-CACResponseArray -Response $response -PropertyName "Users"
            
            if ($users.Count -eq 0) { break }
            
            foreach ($user in $users) {
                $allUsers.Add($user)
            }
            
            $offset += $limit
            
            Write-Progress -Activity "User Cache Refresh" -Status "Fetched $($allUsers.Count) users (page $pageNum)..." -PercentComplete 50
            Write-Host "  Page $pageNum - Fetched $($allUsers.Count) users so far" -ForegroundColor DarkGray
        } while ($users.Count -eq $limit)

        if ($allUsers.Count -eq 0) {
            Write-Log "No users returned from Vault" "WARN"
            Write-Host "No users found in Vault." -ForegroundColor Yellow
            Write-Progress -Activity "User Cache Refresh" -Completed
            return
        }

        Write-Host "  Found $($allUsers.Count) users. Fetching details..." -ForegroundColor Cyan
        Write-Log "Found $($allUsers.Count) users. Processing details..." "INFO"
    }
    catch {
        Write-Log "Failed fetching users: $($_.Exception.Message)" "ERROR"
        Write-Host "Error fetching users: $($_.Exception.Message)" -ForegroundColor Red
        Write-Progress -Activity "User Cache Refresh" -Completed
        return
    }

    # Process each user and fetch details
    $finalUsers = [System.Collections.Generic.List[object]]::new()
    $counter = 0
    $total = $allUsers.Count
    $errorCount = 0

    foreach ($u in $allUsers) {
        $counter++
        $percent = [Math]::Round(($counter / $total) * 100, 0)
        Write-Progress -Activity "User Cache Refresh" -Status "[$counter/$total] $($u.username)" -PercentComplete $percent
        if ($counter % 25 -eq 0 -or $counter -eq $total) {
            Write-Host "  [$counter/$total] Processing user details... ($percent%)" -ForegroundColor DarkGray
        }

        # Fetch full details for specific user
        $userDetails = $u
        try { 
            $userDetails = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users/$($u.id)"
        } 
        catch { 
            $errorCount++
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
            -enableUser $userDetails.enableUser `
            -Suspended $userDetails.suspended `
            -LastSuccessfulLoginDate (Convert-CACTimestamp $userDetails.lastSuccessfulLoginDate) `
            -ExpiryDate (Convert-CACTimestamp $userDetails.expiryDate)

        $finalUsers.Add($userObj)
    }

    Write-Progress -Activity "User Cache Refresh" -Completed

    # Save to disk
    $dataFolder = "$PSScriptRoot/../Data"
    if (-not (Test-Path $dataFolder)) { 
        New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null 
    }
    
    $Script:UserCachePath = "$dataFolder/users_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    try {
        $finalUsers | Export-Csv -Path $Script:UserCachePath -NoTypeInformation -Encoding UTF8
        Write-Log "User cache saved: $Script:UserCachePath" "SUCCESS"
        Write-Host ""
        Write-Host "===== User Cache Refresh Complete =====" -ForegroundColor Cyan
        Write-Host "  Total Users: $($finalUsers.Count)" -ForegroundColor White
        Write-Host "  Errors:      $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Yellow" } else { "White" })
        Write-Host "  Cache File:  $Script:UserCachePath" -ForegroundColor Green
        Write-Host ""
    }
    catch {
        Write-Log "Failed to write cache: $($_.Exception.Message)" "ERROR"
        Write-Host "Error saving cache: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Reload into memory
    Initialize-CACUserCache -Force $true
}

# ============================================================
# USER CACHE - Get User Details
# ============================================================
function Get-CACUserDetailsFromStore {
    <#
    .SYNOPSIS
        Looks up a user in the local cache by ID or username.
    .PARAMETER InputValue
        User ID (numeric) or username/name to search for.
    #>
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
        -enableUser $match.enableUser `
        -Suspended $match.Suspended `
        -LastSuccessfulLoginDate $match.LastSuccessfulLoginDate `
        -ExpiryDate $match.ExpiryDate
}

# ============================================================
# GROUPS - Get Group Members (Core function)
# ============================================================
function Get-CACMembersOfGroup {
    <#
    .SYNOPSIS
        Retrieves members of a specific group (programmatic/lightweight).
    .PARAMETER GroupName
        Name of the group to fetch members for.
    .OUTPUTS
        Array of PSCustomObjects with Id and UserName properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    Write-Log "Fetching members for group: $GroupName" "DEBUG"

    try {
        $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))&includeMembers=true"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $groups = ConvertTo-CACResponseArray -Response $response
        $group = $groups | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1

        if (-not $group) {
            Write-Log "Group '$GroupName' not found" "WARN"
            return $null
        }

        if (-not $group.members -or $group.members.Count -eq 0) {
            Write-Log "Group '$GroupName' has no members" "WARN"
            return @()
        }

        # Build output using List<T>
        $output = [System.Collections.Generic.List[object]]::new()
        foreach ($m in $group.members) {
            $output.Add([PSCustomObject]@{
                    Id       = $m.id
                    UserName = $m.userName
                })
        }

        Write-Log "Retrieved $($output.Count) members from $GroupName" "DEBUG"
        return $output.ToArray()
    }
    catch {
        Write-Log "Group fetch failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}


# ============================================================
# USERS - Get User's Group Memberships
# ============================================================
function Get-CACGroupsOfUser {
    <#
    .SYNOPSIS
        Retrieves and displays the groups a user belongs to.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACUserGroups()" "DEBUG"

    try {
        # Prompt for username
        $userName = Read-Host "Enter Username"
        if ([string]::IsNullOrWhiteSpace($userName)) {
            Write-Host "Username cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Searching for user: $userName..." -ForegroundColor Cyan

        # First, search for the user to get their ID
        $searchEndpoint = "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($userName))"
        $searchResponse = Invoke-CACAPIRequest -Method GET -Endpoint $searchEndpoint

        $users = ConvertTo-CACResponseArray -Response $searchResponse -PropertyName "Users"
        
        if (-not $users -or $users.Count -eq 0) {
            Write-Host "User '$userName' not found." -ForegroundColor Yellow
            return
        }

        # Find exact match or first result
        $user = $users | Where-Object { $_.username -eq $userName } | Select-Object -First 1
        if (-not $user) {
            $user = $users | Select-Object -First 1
            Write-Host "Exact match not found. Using closest match: $($user.username)" -ForegroundColor Yellow
        }

        Write-Host "Found user: $($user.username) (ID: $($user.id))" -ForegroundColor Green

        # Get full user details including group memberships
        $detailsEndpoint = "/API/Users/$($user.id)"
        $userDetails = Invoke-CACAPIRequest -Method GET -Endpoint $detailsEndpoint

        # Extract group memberships
        $groups = $userDetails.groupsMembership

        if (-not $groups -or $groups.Count -eq 0) {
            Write-Host ""
            Write-Host "User '$($user.username)' is not a member of any groups." -ForegroundColor Yellow
            return
        }

        # Display results
        Write-Host ""
        Write-Host "===== Groups for User: $($user.username) =====" -ForegroundColor Cyan
        Write-Host "Total Groups: $($groups.Count)"
        Write-Host ""

        # Format and display
        $groupList = $groups | ForEach-Object {
            [PSCustomObject]@{
                GroupID   = $_.groupID
                GroupName = $_.groupName
            }
        }

        $groupList | Format-Table -AutoSize

        Write-Log "Retrieved $($groups.Count) groups for user $($user.username)" "INFO"
        return $groupList
    }
    catch {
        Write-Log "Error in Get-CACUserGroups(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# GROUPS - Get All Groups
# ============================================================
function Get-CACAllGroups {
    <#
    .SYNOPSIS
        Retrieves all groups from CyberArk with optional filtering and member display.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAllGroups()" "DEBUG"

    try {
        # Interactive prompt
        $includeMembersChoice = Read-Host "Include group members in output? (Y/N)"
        $includeMembers = ($includeMembersChoice -match '^[Yy]$')

        Write-Host "Fetching groups from CyberArk..." -ForegroundColor Cyan

        # Use List<T> for better performance
        $allGroups = [System.Collections.Generic.List[object]]::new()
        $offset = 0
        $limit = 100
        $pageNum = 0

        # Paginate through all groups
        do {
            $pageNum++
            $queryParams = @("limit=$limit", "offset=$offset")
            
            if ($includeMembers) {
                $queryParams += "includeMembers=true"
            }

            $endpoint = "/API/UserGroups/?" + ($queryParams -join "&")
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

            $groups = ConvertTo-CACResponseArray -Response $response
            
            if ($groups.Count -eq 0) { break }
            
            foreach ($group in $groups) {
                $allGroups.Add($group)
            }
            
            $offset += $limit
            
            Write-Progress -Activity "Fetching Groups" -Status "Page $pageNum - Retrieved $($allGroups.Count) groups" -PercentComplete 50
            Write-Host "  Page $pageNum - Retrieved $($allGroups.Count) groups" -ForegroundColor DarkGray
        } while ($groups.Count -eq $limit)

        Write-Progress -Activity "Fetching Groups" -Completed

        if ($allGroups.Count -eq 0) {
            Write-Host "No groups found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($allGroups.Count) groups" "INFO"

        # Process groups
        $formattedGroups = [System.Collections.Generic.List[object]]::new()
        $counter = 0

        foreach ($group in $allGroups) {
            $counter++
            $percent = [Math]::Round(($counter / $allGroups.Count) * 100, 0)
            Write-Progress -Activity "Processing Groups" -Status "[$counter/$($allGroups.Count)] $($group.groupName)" -PercentComplete $percent
            if ($counter % 50 -eq 0 -or $counter -eq $allGroups.Count) {
                Write-Host "  [$counter/$($allGroups.Count)] Processing groups... ($percent%)" -ForegroundColor DarkGray
            }

            # Format members as "Id:UserName" comma-separated
            $membersStr = ""
            if ($includeMembers -and $group.members -and $group.members.Count -gt 0) {
                $membersStr = ($group.members | ForEach-Object { "$($_.id):$($_.userName)" }) -join ", "
            }

            $groupRecord = [PSCustomObject]@{
                Id          = $group.id
                GroupName   = $group.groupName
                Description = $group.description
                GroupType   = $group.groupType
                Directory   = $group.directory
                MemberCount = $(if ($group.members) { $group.members.Count } else { 0 })
                Members     = $membersStr
            }

            $formattedGroups.Add($groupRecord)
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

        if ($includeMembers) {
            $formattedGroups | Format-Table GroupName, GroupType, MemberCount, Members -AutoSize -Wrap
        }
        else {
            $formattedGroups | Format-Table GroupName, GroupType, Description, MemberCount -AutoSize
        }

        # Always export to CSV
        $outputDir = Get-CACOutputDir
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFile = "$outputDir/groups_$timestamp.csv"

        $formattedGroups | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        Write-Host "Export File: $outputFile" -ForegroundColor Green

        return $formattedGroups.ToArray()
    }
    catch {
        Write-Log "Error in Get-CACAllGroups(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# INTERACTIVE - Lookup User from Cache
# ============================================================
function Invoke-CACUserLookup {
    <#
    .SYNOPSIS
        Interactive wrapper: prompts for username/ID and displays user details from cache.
    #>
    [CmdletBinding()]
    param()

    $inputVal = Read-Host "Enter Username or ID"
    if ([string]::IsNullOrWhiteSpace($inputVal)) {
        Write-Host "Input cannot be empty." -ForegroundColor Yellow
        return
    }

    Write-Host "Searching cache for: $inputVal ..." -ForegroundColor Cyan
    $result = Get-CACUserDetailsFromStore -InputValue $inputVal

    if (-not $result -or $result.FullName -eq "Not Found") {
        Write-Host "User '$inputVal' not found in cache." -ForegroundColor Yellow
        Write-Host "Tip: Run 'Refresh User Cache' to pull the latest data." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "===== User Details =====" -ForegroundColor Cyan
    Write-Host "  ID:                     $($result.Id)" -ForegroundColor White
    Write-Host "  Username:               $($result.UserName)" -ForegroundColor White
    Write-Host "  Full Name:              $($result.FullName)" -ForegroundColor White
    Write-Host "  Email:                  $($result.Email)" -ForegroundColor White
    Write-Host "  Phone:                  $($result.Phone)" -ForegroundColor White
    Write-Host "  Department:             $($result.Department)" -ForegroundColor White
    Write-Host "  Title:                  $($result.Title)" -ForegroundColor White
    Write-Host "  enableUser:             $($result.enableUser)" -ForegroundColor White
    Write-Host "  Suspended:              $($result.Suspended)" -ForegroundColor White
    Write-Host "  Last Successful Login:  $($result.LastSuccessfulLoginDate)" -ForegroundColor White
    Write-Host "  Expiry Date:            $($result.ExpiryDate)" -ForegroundColor White
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# INTERACTIVE - Get Members of a Group
# ============================================================
function Invoke-CACGroupMembersLookup {
    <#
    .SYNOPSIS
        Interactive wrapper: prompts for group name and displays members.
    #>
    [CmdletBinding()]
    param()

    $groupName = Read-Host "Enter Group Name"
    if ([string]::IsNullOrWhiteSpace($groupName)) {
        Write-Host "Group name cannot be empty." -ForegroundColor Yellow
        return
    }

    Write-Host "Fetching members for group: $groupName ..." -ForegroundColor Cyan
    $members = Get-CACMembersOfGroup -GroupName $groupName

    if ($null -eq $members) {
        Write-Host "Group '$groupName' not found." -ForegroundColor Yellow
        return
    }

    if ($members.Count -eq 0) {
        Write-Host "Group '$groupName' has no members." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "===== Members of '$groupName' =====" -ForegroundColor Cyan
    Write-Host "Total Members: $($members.Count)"
    Write-Host ""
    $members | Format-Table -AutoSize
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Initialize-CACUserCache, `
    New-CACUserStore, `
    Get-CACUserDetailsFromStore, `
    Invoke-CACUserLookup, `
    Get-CACAllGroups, `
    Get-CACMembersOfGroup, `
    Invoke-CACGroupMembersLookup, `
    Get-CACGroupsOfUser
