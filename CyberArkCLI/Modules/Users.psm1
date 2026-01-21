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
        
        $offset = 0
        $limit = 100
        $totalFetched = 0

        # Paginate through all users
        do {
            $endpoint = "/API/Users?limit=$limit&offset=$offset"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
            
            $users = ConvertTo-CACResponseArray -Response $response -PropertyName "Users"
            
            if ($users.Count -eq 0) { break }
            
            foreach ($user in $users) {
                $allUsers.Add($user)
            }
            
            $totalFetched = $allUsers.Count
            $offset += $limit
            
            Write-Progress -Activity "User Cache Refresh" -Status "Fetched $totalFetched users..." -PercentComplete 50
        } while ($users.Count -eq $limit)

        if ($allUsers.Count -eq 0) {
            Write-Log "No users returned from Vault" "WARN"
            Write-Host "No users found in Vault." -ForegroundColor Yellow
            Write-Progress -Activity "User Cache Refresh" -Completed
            return
        }

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
        Write-Progress -Activity "User Cache Refresh" -Status "Processing $counter of $total : $($u.username)" -PercentComplete $percent

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
        -Status $match.Status
}

# ============================================================
# GROUPS - Get Group Members (Core function)
# ============================================================
function Get-CACGroupUsers {
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
# GROUPS - Get Group Members (Interactive)
# ============================================================
function Get-CACGroupMembers {
    <#
    .SYNOPSIS
        Retrieves and displays members of a specific group (interactive).
    .PARAMETER GroupName
        Name of the group. If not provided, prompts for input.
    #>
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

        # Use the core function
        $members = Get-CACGroupUsers -GroupName $GroupName

        if ($null -eq $members) {
            Write-Host "Group '$GroupName' not found." -ForegroundColor Yellow
            return
        }

        if ($members.Count -eq 0) {
            Write-Host "Group '$GroupName' has no members." -ForegroundColor Yellow
            return
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
# GROUPS - Get All Groups
# ============================================================
function Get-CACAllGroups {
    <#
    .SYNOPSIS
        Retrieves all groups from CyberArk with optional filtering.
    .PARAMETER GroupType
        Filter by group type: All, Vault, or Directory.
    .PARAMETER IncludeMembers
        Include member details in the response.
    .PARAMETER ExportToCSV
        Export results to CSV file.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("All", "Vault", "Directory")]
        [string]$GroupType = "All",

        [switch]$IncludeMembers,

        [bool]$ExportToCSV = $true
    )

    Write-Log "Started Get-CACAllGroups()" "DEBUG"

    try {
        Write-Host "Fetching groups from CyberArk..." -ForegroundColor Cyan

        # Use List<T> for better performance
        $allGroups = [System.Collections.Generic.List[object]]::new()
        $offset = 0
        $limit = 100

        # Paginate through all groups
        do {
            $queryParams = @("limit=$limit", "offset=$offset")
            
            if ($GroupType -ne "All") {
                $queryParams += "filter=groupType eq $GroupType"
            }
            
            if ($IncludeMembers) {
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
            
            Write-Progress -Activity "Fetching Groups" -Status "Retrieved $($allGroups.Count) groups..." -PercentComplete 50
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
            Write-Progress -Activity "Processing Groups" -Status "$counter of $($allGroups.Count)" -PercentComplete (($counter / $allGroups.Count) * 100)

            $groupRecord = New-CACGroupObject `
                -Id $group.id `
                -GroupName $group.groupName `
                -Description $group.description `
                -GroupType $group.groupType `
                -Directory $group.directory `
                -MemberCount $(if ($group.members) { $group.members.Count } else { 0 })

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

        $formattedGroups | Format-Table GroupName, GroupType, Description, MemberCount -AutoSize

        if ($ExportToCSV) {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/groups_$timestamp.csv"

            $formattedGroups | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedGroups.ToArray()
    }
    catch {
        Write-Log "Error in Get-CACAllGroups(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# GROUPS - Remove Single Group (Manual)
# ============================================================
function Remove-CACGroup {
    [CmdletBinding()]
    param(
        [string]$GroupName
    )

    Write-Log "Started Remove-CACGroup()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            $GroupName = Read-Host "Enter Group Name to delete"
            if ([string]::IsNullOrWhiteSpace($GroupName)) {
                Write-Host "Group name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Searching for group: $GroupName..." -ForegroundColor Cyan

        # Find the group
        $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
        $groups = ConvertTo-CACResponseArray -Response $response
        $group = $groups | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1

        if (-not $group) {
            Write-Log "Group '$GroupName' not found" "WARN"
            Write-Host "Group '$GroupName' not found." -ForegroundColor Yellow
            return
        }

        # Display confirmation
        Write-Host ""
        Write-Host "===== Delete Group Confirmation =====" -ForegroundColor Red
        Write-Host "Group ID:    $($group.id)"
        Write-Host "Group Name:  $($group.groupName)"
        Write-Host "Group Type:  $($group.groupType)"
        Write-Host "Description: $($group.description)"
        Write-Host ""
        Write-Host "WARNING: This action cannot be undone." -ForegroundColor Red

        $confirm = Read-Host "Are you sure you want to PERMANENTLY DELETE this group? (Y/N)"

        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Log "Delete cancelled by user" "INFO"
            Write-Host "Delete cancelled." -ForegroundColor Yellow
            return
        }

        Write-Log "User confirmed; deleting group: $($group.id)" "WARN"

        # Delete the group
        Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$($group.id)"

        Write-Log "Group deleted successfully: $GroupName (ID: $($group.id))" "SUCCESS"
        Write-Host "Group deleted successfully." -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Remove-CACGroup(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# GROUPS - Batch Delete Groups (CSV)
# ============================================================
function Invoke-CACBatchGroupDeletion {
    <#
    .SYNOPSIS
        Delete multiple groups by name or from CSV.
    .DESCRIPTION
        Supports manual single deletion or batch CSV processing.
        Output CSV preserves all input columns and adds DeletionStatus and Message.
    #>
    [CmdletBinding()]
    param()

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/GroupDeletion_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    Write-Log "Started Invoke-CACBatchGroupDeletion()" "DEBUG"

    $itemsToProcess = @()
    $GroupName = $null
    $CsvPath = $null

    # Interactive mode selection
    Write-Host "Select Deletion Mode:" -ForegroundColor Cyan
    Write-Host "1. Single Group Name"
    Write-Host "2. Batch CSV File"
    
    $mode = Read-Host "Mode (1/2)"
    if ($mode -eq '1') {
        $val = Read-Host "Enter Group Name"
        if (-not [string]::IsNullOrWhiteSpace($val)) { $GroupName = $val }
    }
    elseif ($mode -eq '2') {
        $val = Read-Host "Enter CSV Path"
        if (-not [string]::IsNullOrWhiteSpace($val)) { $CsvPath = $val }
    }
    else {
        Write-Warning "Invalid selection."
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        Write-Log "Processing single group: $GroupName" "INFO"
        $itemsToProcess += [PSCustomObject]@{
            GroupName     = $GroupName
            ProcessSource = "ManualInput"
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        if (-not (Test-Path $CsvPath)) {
            Write-Error "CSV file not found: $CsvPath"
            return
        }
        Write-Log "Processing CSV: $CsvPath" "INFO"
        $itemsToProcess = Import-Csv $CsvPath
    }
    else {
        Write-Error "No valid group name or CSV path provided."
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Warning "No items to process."
        return
    }

    # Process deletions
    $results = @()
    $total = $itemsToProcess.Count
    $current = 0

    foreach ($item in $itemsToProcess) {
        $current++
        $resObj = $item | Select-Object *
        
        # Get group name from either GroupName or groupName column
        $groupNameVal = if ($item.PSObject.Properties['GroupName']) { $item.GroupName } 
        elseif ($item.PSObject.Properties['groupName']) { $item.groupName } 
        else { $null }

        if (-not $groupNameVal) {
            Write-Host "Row $current : Missing 'GroupName' column. Skipping." -ForegroundColor Yellow
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Skipped" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Missing 'GroupName' column" -Force
            $results += $resObj
            continue
        }

        Write-Progress -Activity "Deleting Groups (Batch)" -Status "Processing: $groupNameVal" -PercentComplete (($current / $total) * 100)
        Write-Host "[$current/$total] Deleting Group: $groupNameVal ... " -NoNewline

        try {
            # Find the group first
            $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($groupNameVal))"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
            $groups = ConvertTo-CACResponseArray -Response $response
            $group = $groups | Where-Object { $_.groupName -eq $groupNameVal } | Select-Object -First 1

            if (-not $group) {
                Write-Host "Not Found" -ForegroundColor Yellow
                $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Failed" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Group not found" -Force
                Write-Log "Group not found: $groupNameVal" "WARN"
            }
            else {
                # Delete the group
                Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$($group.id)"
                
                Write-Host "Success" -ForegroundColor Green
                $resObj | Add-Member -MemberType NoteProperty -Name "GroupId" -Value $group.id -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Success" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Deleted" -Force
                Write-Log "Deleted Group: $groupNameVal (ID: $($group.id))" "SUCCESS"
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "Failed ($errMsg)" -ForegroundColor Red
            
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Failed" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value $errMsg -Force
            Write-Log "Failed to delete $groupNameVal : $errMsg" "ERROR"
        }

        $results += $resObj
    }
    Write-Progress -Activity "Deleting Groups (Batch)" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch Group Deletion Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Batch Group Deletion Complete. Results saved to $OutputCsvPath" "INFO"
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
    Get-CACGroupUsers, `
    Remove-CACGroup, `
    Invoke-CACBatchGroupDeletion
