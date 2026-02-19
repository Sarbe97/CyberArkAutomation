# =============================================================================
# MODULE: UserManagement.psm1
# DESCRIPTION: Group & User Management - Create/Delete Groups, Add Users, Reset Passwords
# =============================================================================

# ============================================================
# 1. BATCH GROUP CREATION (Manual or CSV)
# Creates groups and optionally adds users to them
# ============================================================
function Invoke-CACBatchGroupCreation {
    <#
    .SYNOPSIS
        Create groups and optionally add users. Supports manual input or CSV.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$WhatIf
    )

    Write-Log "Started Invoke-CACBatchGroupCreation() - WhatIf: $WhatIf" "DEBUG"

    if ($WhatIf) {
        Write-Host ""
        Write-Host "!!! RUNNING IN WHAT-IF MODE (DRY RUN) !!!" -ForegroundColor Magenta
        Write-Host "No changes will be made to CyberArk." -ForegroundColor Magenta
        Write-Host ""
    }

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/GroupCreation_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    $itemsToProcess = @()

    # Mode selection
    Write-Host "Select Input Mode:" -ForegroundColor Cyan
    Write-Host "1. Manual Input (Single Group)"
    Write-Host "2. CSV File (Batch)"

    $mode = Read-Host "Mode (1/2)"

    if ($mode -eq '1') {
        $groupName = Read-Host "Enter Group Name"
        if ([string]::IsNullOrWhiteSpace($groupName)) {
            Write-Warning "Group name cannot be empty."
            return
        }

        $description = Read-Host "Enter Group Description (optional, press Enter to skip)"
        $membersInput = Read-Host "Enter usernames to add (comma-separated, or press Enter to skip)"

        $itemsToProcess += [PSCustomObject]@{
            GroupName    = $groupName.Trim()
            Description  = $description.Trim()
            GroupMembers = $membersInput.Trim()
        }
    }
    elseif ($mode -eq '2') {
        $CsvPath = Get-CACFilePath -Title "Select Group Creation CSV" -Filter "CSV Files (*.csv)|*.csv"

        if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path $CsvPath)) {
            Write-Host "CSV file not found." -ForegroundColor Red
            return
        }

        Write-Log "Processing CSV: $CsvPath" "INFO"
        $itemsToProcess = Import-Csv $CsvPath
    }
    else {
        Write-Warning "Invalid selection."
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Warning "No items to process."
        return
    }

    # --- SUMMARY CONFIRMATION ---
    Write-Host ""
    Write-Host "===== GROUP CREATION SUMMARY =====" -ForegroundColor Cyan
    Write-Host "Total Groups to Create: $($itemsToProcess.Count)"
    if ($itemsToProcess.Count -lt 11) {
        $itemsToProcess | ForEach-Object {
            $disp = if ($_.GroupName) { $_.GroupName } else { "Unknown" }
            Write-Host " - Group: $disp" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host " - $($itemsToProcess[0].GroupName)" -ForegroundColor DarkGray
        Write-Host " - ..." -ForegroundColor DarkGray
        Write-Host " ... and $($itemsToProcess.Count - 1) more." -ForegroundColor DarkGray
    }
    Write-Host "==================================" -ForegroundColor Cyan

    if (-not $WhatIf) {
        $confirm = Read-Host "Proceed with group creation? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
    }
    else {
        Write-Host "What-If Mode: Skipping confirmation prompt." -ForegroundColor Cyan
    }

    $results = @()
    $i = 0

    foreach ($item in $itemsToProcess) {
        $i++
        $gName = if ($item.GroupName) { $item.GroupName.Trim() } else { $null }
        $gDesc = if ($item.PSObject.Properties['Description']) { $item.Description.Trim() } else { "" }
        $gMembers = if ($item.PSObject.Properties['GroupMembers']) { $item.GroupMembers.Trim() } else { "" }

        if (-not $gName) {
            Write-Warning "Row $i missing 'GroupName'"
            continue
        }

        $resObj = [PSCustomObject]@{
            GroupName     = $gName
            Description   = $gDesc
            GroupStatus   = ""
            MembersAdded  = ""
            MembersFailed = ""
            Message       = ""
        }

        if ($WhatIf) {
            Write-Host "[$i/$($itemsToProcess.Count)] [WHAT-IF] Would create Group: $gName" -ForegroundColor Magenta
            Write-Log "[WHAT-IF] Would create Group: $gName" "INFO"
            Write-Progress -Activity "Creating Groups" -Status "[$i/$($itemsToProcess.Count)] [WHAT-IF] $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)
            $resObj.GroupStatus = "WhatIf-Success"
            $resObj.Message = "Group would be created"
            $results += $resObj
            continue
        }

        Write-Host "[$i/$($itemsToProcess.Count)] Creating Group: $gName ..." -NoNewline
        Write-Progress -Activity "Creating Groups" -Status "[$i/$($itemsToProcess.Count)] $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)
        Write-Log "Creating group: $gName" "INFO"

        $groupId = $null

        try {
            # Check if group already exists
            $searchRes = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gName))"
            $existingGroup = $searchRes.value | Where-Object { $_.groupName -eq $gName } | Select-Object -First 1

            if ($existingGroup) {
                $groupId = $existingGroup.id
                $resObj.GroupStatus = "Exists"
                Write-Host " [EXISTS]" -ForegroundColor Yellow
                Write-Log "Group already exists: $gName (ID: $groupId)" "INFO"
            }
            else {
                # Create group
                $groupBody = @{ groupName = $gName }
                if (-not [string]::IsNullOrWhiteSpace($gDesc)) {
                    $groupBody["description"] = $gDesc
                }

                Write-Log "POST /API/UserGroups - Body: $($groupBody | ConvertTo-Json -Compress)" "DEBUG"
                $newGroup = Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups" -Body $groupBody
                $groupId = $newGroup.id
                $resObj.GroupStatus = "Created"
                Write-Host " [CREATED]" -ForegroundColor Green
                Write-Log "Group created: $gName (ID: $groupId)" "SUCCESS"
            }
        }
        catch {
            $resObj.GroupStatus = "Failed"
            $resObj.Message = "Group creation failed: $($_.Exception.Message)"
            Write-Host " [FAILED]" -ForegroundColor Red
            Write-Log "Group creation failed: $($_.Exception.Message)" "ERROR"
            $results += $resObj
            continue
        }

        # Add members to group if specified
        if ($groupId -and -not [string]::IsNullOrWhiteSpace($gMembers)) {
            $members = $gMembers -split "[;,]" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $addedMembers = @()
            $failedMembers = @()

            Write-Host " -> Adding $($members.Count) users to group..." -ForegroundColor Cyan
            Write-Log "Adding $($members.Count) users to group $gName" "INFO"

            foreach ($member in $members) {
                Write-Host "    - $member..." -NoNewline
                Write-Log "Adding user to group: $member" "DEBUG"

                try {
                    $addMemberBody = @{
                        memberId   = $member
                        memberType = "Vault"
                    }

                    Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups/$groupId/Members" -Body $addMemberBody | Out-Null
                    $addedMembers += $member
                    Write-Host " [ADDED]" -ForegroundColor Green
                    Write-Log "User added to group: $member" "SUCCESS"
                }
                catch {
                    $errMsg = $_.Exception.Message

                    if ($errMsg -match "409|already exists|ITATS262E") {
                        $addedMembers += "$member(Exists)"
                        Write-Host " [ALREADY MEMBER]" -ForegroundColor Green
                        Write-Log "User already member: $member" "INFO"
                    }
                    else {
                        $failedMembers += "$member(Error)"
                        Write-Host " [FAILED: $errMsg]" -ForegroundColor Red
                        Write-Log "Failed to add user $member to group: $errMsg" "ERROR"
                    }
                }
            }
            $resObj.MembersAdded = $addedMembers -join ";"
            $resObj.MembersFailed = $failedMembers -join ";"
        }

        $results += $resObj
    }
    Write-Progress -Activity "Creating Groups" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nGroup Creation Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Group Creation Complete. Results saved to $OutputCsvPath" "INFO"
}


# ============================================================
# 2. BATCH ADD USERS TO GROUP (Manual or CSV)
# Adds users to existing groups
# ============================================================
function Invoke-CACBatchAddUsersToGroup {
    <#
    .SYNOPSIS
        Add users to existing groups. Supports manual input or CSV.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$WhatIf
    )

    Write-Log "Started Invoke-CACBatchAddUsersToGroup() - WhatIf: $WhatIf" "DEBUG"

    if ($WhatIf) {
        Write-Host ""
        Write-Host "!!! RUNNING IN WHAT-IF MODE (DRY RUN) !!!" -ForegroundColor Magenta
        Write-Host "No changes will be made to CyberArk." -ForegroundColor Magenta
        Write-Host ""
    }

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/AddUsersToGroup_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    $itemsToProcess = @()

    # Mode selection
    Write-Host "Select Input Mode:" -ForegroundColor Cyan
    Write-Host "1. Manual Input"
    Write-Host "2. CSV File (Batch)"

    $mode = Read-Host "Mode (1/2)"

    if ($mode -eq '1') {
        $groupName = Read-Host "Enter Group Name"
        if ([string]::IsNullOrWhiteSpace($groupName)) {
            Write-Warning "Group name cannot be empty."
            return
        }

        $usersInput = Read-Host "Enter usernames to add (comma-separated)"
        if ([string]::IsNullOrWhiteSpace($usersInput)) {
            Write-Warning "No usernames provided."
            return
        }

        $userNames = $usersInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($u in $userNames) {
            $itemsToProcess += [PSCustomObject]@{
                GroupName  = $groupName.Trim()
                UserName   = $u
                MemberType = "Vault"
            }
        }
    }
    elseif ($mode -eq '2') {
        $CsvPath = Get-CACFilePath -Title "Select Add Users to Group CSV" -Filter "CSV Files (*.csv)|*.csv"

        if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path $CsvPath)) {
            Write-Host "CSV file not found." -ForegroundColor Red
            return
        }

        Write-Log "Processing CSV: $CsvPath" "INFO"
        $itemsToProcess = Import-Csv $CsvPath
    }
    else {
        Write-Warning "Invalid selection."
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Warning "No items to process."
        return
    }

    # --- SUMMARY ---
    Write-Host ""
    Write-Host "===== ADD USERS TO GROUP SUMMARY =====" -ForegroundColor Cyan
    Write-Host "Total Entries: $($itemsToProcess.Count)"

    # Group by group name for display
    $groupedDisplay = $itemsToProcess | Group-Object -Property GroupName
    foreach ($g in $groupedDisplay) {
        Write-Host " - Group: $($g.Name) ($($g.Count) user(s))" -ForegroundColor DarkGray
    }
    Write-Host "======================================" -ForegroundColor Cyan

    if (-not $WhatIf) {
        $confirm = Read-Host "Proceed? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
    }
    else {
        Write-Host "What-If Mode: Skipping confirmation prompt." -ForegroundColor Cyan
    }

    # Cache group IDs to avoid repeated lookups
    $groupIdCache = @{}
    $results = @()
    $i = 0

    foreach ($item in $itemsToProcess) {
        $i++
        $gName = if ($item.GroupName) { $item.GroupName.Trim() } else { $null }
        $userName = if ($item.UserName) { $item.UserName.Trim() } else { $null }
        $memberType = if ($item.PSObject.Properties['MemberType'] -and $item.MemberType) { $item.MemberType.Trim() } else { "Vault" }

        if (-not $gName -or -not $userName) {
            Write-Warning "Row $i missing 'GroupName' or 'UserName'"
            continue
        }

        $resObj = [PSCustomObject]@{
            GroupName  = $gName
            UserName   = $userName
            MemberType = $memberType
            Status     = ""
            Message    = ""
        }

        if ($WhatIf) {
            Write-Host "[$i/$($itemsToProcess.Count)] [WHAT-IF] Would add '$userName' to group '$gName'" -ForegroundColor Magenta
            Write-Log "[WHAT-IF] Would add $userName to $gName" "INFO"
            Write-Progress -Activity "Adding Users to Groups" -Status "[$i/$($itemsToProcess.Count)] [WHAT-IF] $userName -> $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)
            $resObj.Status = "WhatIf-Success"
            $resObj.Message = "User would be added"
            $results += $resObj
            continue
        }

        Write-Host "[$i/$($itemsToProcess.Count)] Adding '$userName' to group '$gName' ..." -NoNewline
        Write-Progress -Activity "Adding Users to Groups" -Status "[$i/$($itemsToProcess.Count)] $userName -> $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)

        # Resolve group ID (with caching)
        $groupId = $null
        if ($groupIdCache.ContainsKey($gName)) {
            $groupId = $groupIdCache[$gName]
        }
        else {
            try {
                $searchRes = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gName))"
                $group = $searchRes.value | Where-Object { $_.groupName -eq $gName } | Select-Object -First 1

                if ($group) {
                    $groupId = $group.id
                    $groupIdCache[$gName] = $groupId
                }
            }
            catch {
                Write-Log "Error searching for group $gName : $($_.Exception.Message)" "ERROR"
            }
        }

        if (-not $groupId) {
            $resObj.Status = "Failed"
            $resObj.Message = "Group '$gName' not found"
            Write-Host " [GROUP NOT FOUND]" -ForegroundColor Red
            Write-Log "Group not found: $gName" "WARN"
            $results += $resObj
            continue
        }

        # Add user to group
        try {
            $addMemberBody = @{
                memberId   = $userName
                memberType = $memberType
            }

            Write-Log "POST /API/UserGroups/$groupId/Members - Body: $($addMemberBody | ConvertTo-Json -Compress)" "DEBUG"
            Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups/$groupId/Members" -Body $addMemberBody | Out-Null
            $resObj.Status = "Added"
            Write-Host " [ADDED]" -ForegroundColor Green
            Write-Log "User $userName added to group $gName" "SUCCESS"
        }
        catch {
            $errMsg = $_.Exception.Message

            if ($errMsg -match "409|already exists|ITATS262E") {
                $resObj.Status = "AlreadyMember"
                $resObj.Message = "User is already a member"
                Write-Host " [ALREADY MEMBER]" -ForegroundColor Green
                Write-Log "User $userName already member of $gName" "INFO"
            }
            else {
                $resObj.Status = "Failed"
                $resObj.Message = $errMsg
                Write-Host " [FAILED: $errMsg]" -ForegroundColor Red
                Write-Log "Failed to add $userName to $gName : $errMsg" "ERROR"
            }
        }

        $results += $resObj
    }
    Write-Progress -Activity "Adding Users to Groups" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nAdd Users to Group Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Add Users to Group Complete. Results saved to $OutputCsvPath" "INFO"
}


# ============================================================
# 3. DELETE SINGLE GROUP (Manual)
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
# 4. BATCH DELETE GROUPS (Manual or CSV)
# ============================================================
function Invoke-CACBatchGroupDeletion {
    <#
    .SYNOPSIS
        Delete multiple groups by name or from CSV.
    .DESCRIPTION
        Supports manual single deletion or batch CSV processing.
        Output CSV preserves all input columns and adds DeletionStatus and Message.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$WhatIf
    )

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/GroupDeletion_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    Write-Log "Started Invoke-CACBatchGroupDeletion() - WhatIf: $WhatIf" "DEBUG"

    if ($WhatIf) {
        Write-Host ""
        Write-Host "!!! RUNNING IN WHAT-IF MODE (DRY RUN) !!!" -ForegroundColor Magenta
        Write-Host "No changes will be made to CyberArk." -ForegroundColor Magenta
        Write-Host ""
    }

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
        $CsvPath = Get-CACFilePath -Title "Select Group Deletion CSV" -Filter "CSV Files (*.csv)|*.csv"
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
        
        # Import CSV - handle different possible headers
        $csvData = Import-Csv $CsvPath
        $itemsToProcess = $csvData
    }
    else {
        Write-Warning "No input provided."
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Warning "No items to process."
        return
    }

    # --- SUMMARY CONFIRMATION ---
    Write-Host ""
    Write-Host "===== DELETION SUMMARY =====" -ForegroundColor Red
    Write-Host "Total Groups to Delete: $($itemsToProcess.Count)"
    if ($itemsToProcess.Count -lt 11) {
        $itemsToProcess | ForEach-Object { 
            $disp = if ($_.GroupName) { $_.GroupName } else { "Unknown" }
            Write-Host " - Group: $disp" -ForegroundColor DarkGray 
        }
    }
    else {
        Write-Host " - $(($itemsToProcess[0].GroupName))" -ForegroundColor DarkGray
        Write-Host " - ..." -ForegroundColor DarkGray
        Write-Host " ... and $(($itemsToProcess.Count - 1)) more." -ForegroundColor DarkGray
    }
    Write-Host "============================" -ForegroundColor Red
    
    if (-not $WhatIf) {
        $confirm = Read-Host "Are you sure you want to PERMANENTLY DELETE these groups? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
    }
    else {
        Write-Host "What-If Mode: Skipping confirmation prompt." -ForegroundColor Cyan
    }

    $results = @()
    $i = 0
    foreach ($item in $itemsToProcess) {
        $i++
        # Resolve group name from possible headers
        $gName = if ($item.GroupName) { $item.GroupName } elseif ($item.BatchGroupName) { $item.BatchGroupName } else { $null }

        if (-not $gName) {
            Write-Warning "Row $i missing 'GroupName'"
            continue
        }

        if ($WhatIf) {
            Write-Host "[$i/$($itemsToProcess.Count)] [WHAT-IF] Would delete Group: $gName" -ForegroundColor Magenta
            Write-Log "[WHAT-IF] Would delete Group: $gName" "INFO"
            Write-Progress -Activity "Deleting Groups" -Status "[$i/$($itemsToProcess.Count)] [WHAT-IF] $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)
        
            # Simulated result object
            $resObject = $item | Select-Object *
            $resObject | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "WhatIf-Success" -Force
            $resObject | Add-Member -MemberType NoteProperty -Name "Message" -Value "Group would be deleted" -Force
            $results += $resObject
            continue
        }

        Write-Host "[$i/$($itemsToProcess.Count)] Deleting Group: $gName ..." -NoNewline
        Write-Progress -Activity "Deleting Groups" -Status "[$i/$($itemsToProcess.Count)] $gName" -PercentComplete (($i / $itemsToProcess.Count) * 100)

        # Build result object
        $resObj = $item | Select-Object *
        $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "" -Force
        $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "" -Force

        try {
            # 1. Search for Group ID
            $searchRes = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gName))"
            $targetGroup = $null
            if ($searchRes.value) {
                # Exact match check
                $targetGroup = $searchRes.value | Where-Object { $_.groupName -eq $gName } | Select-Object -First 1
            }

            if ($targetGroup) {
                # 2. Delete Group
                Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$($targetGroup.id)"
                $resObj.DeletionStatus = "Success"
                $resObj.Message = "Deleted"
                Write-Host " [OK]" -ForegroundColor Green
                Write-Log "Deleted group $gName" "SUCCESS"
            }
            else {
                $resObj.DeletionStatus = "NotFound"
                $resObj.Message = "Group not found"
                Write-Host " [NOT FOUND]" -ForegroundColor Yellow
                Write-Log "Group not found: $gName" "WARN"
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host " [FAILED] $errMsg" -ForegroundColor Red
            
            $resObj.DeletionStatus = "Failed"
            $resObj.Message = $errMsg
            Write-Log "Failed to delete $gName : $errMsg" "ERROR"
        }

        $results += $resObj
    }
    Write-Progress -Activity "Deleting Groups" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch Group Deletion Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Batch Group Deletion Complete. Results saved to $OutputCsvPath" "INFO"
}


# ============================================================
# 5. RESET USER PASSWORD
# ============================================================
function Reset-CACUserPassword {
    <#
    .SYNOPSIS
        Resets a Vault user's password.
    .DESCRIPTION
        Prompts for username, searches for the user, and resets their password.
        Requires "Audit users" and "Reset Users' Passwords" permissions.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Reset-CACUserPassword()" "DEBUG"

    try {
        # Prompt for username
        $userName = Read-Host "Enter Username to reset password"
        if ([string]::IsNullOrWhiteSpace($userName)) {
            Write-Host "Username cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Searching for user: $userName..." -ForegroundColor Cyan

        # Search for the user to get their ID
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

        Write-Host ""
        Write-Host "===== User Found =====" -ForegroundColor Cyan
        Write-Host "User ID:   $($user.id)"
        Write-Host "Username:  $($user.username)"
        Write-Host "Source:    $($user.source)"
        Write-Host ""

        # Confirm action
        $confirm = Read-Host "Reset password for this user? (Y/N)"
        if ($confirm -notmatch '^[Yy]$') {
            Write-Host "Password reset cancelled." -ForegroundColor Yellow
            return
        }

        # Prompt for new password (masked input)
        Write-Host ""
        Write-Host "Enter new password (max 39 characters, must meet policy requirements):" -ForegroundColor Cyan
        $securePassword = Read-Host -AsSecureString "New Password"
        
        # Convert secure string to plain text for API
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $newPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if ([string]::IsNullOrWhiteSpace($newPassword)) {
            Write-Host "Password cannot be empty." -ForegroundColor Yellow
            return
        }

        if ($newPassword.Length -gt 39) {
            Write-Host "Password exceeds maximum length of 39 characters." -ForegroundColor Yellow
            return
        }

        # Confirm password
        $secureConfirm = Read-Host -AsSecureString "Confirm New Password"
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureConfirm)
        $confirmPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if ($newPassword -ne $confirmPassword) {
            Write-Host "Passwords do not match." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "Resetting password..." -ForegroundColor Cyan

        # Build request body
        $body = @{
            id          = $user.id
            newPassword = $newPassword
        }

        # Call the API
        $endpoint = "/API/Users/$($user.id)/ResetPassword/"
        $response = Invoke-CACAPIRequest -Method POST -Endpoint $endpoint -Body $body

        Write-Host ""
        Write-Host "Password reset successful for user: $($user.username)" -ForegroundColor Green
        Write-Log "Password reset successful for user: $($user.username) (ID: $($user.id))" "SUCCESS"
    }
    catch {
        Write-Log "Error in Reset-CACUserPassword(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}


# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Invoke-CACBatchGroupCreation, `
    Invoke-CACBatchAddUsersToGroup, `
    Remove-CACGroup, `
    Invoke-CACBatchGroupDeletion, `
    Reset-CACUserPassword
