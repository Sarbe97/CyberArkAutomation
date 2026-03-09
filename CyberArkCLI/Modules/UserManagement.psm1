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
    [CmdletBinding()]
    param()

    Write-Log "Started Invoke-CACBatchGroupCreation()" "DEBUG"

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
        Write-Host "CSV columns: GroupName (required), Description (optional), GroupMembers (optional - semicolon-separated usernames)" -ForegroundColor Yellow
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

    $confirm = Read-Host "Proceed with group creation? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
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
    [CmdletBinding()]
    param()

    Write-Log "Started Invoke-CACBatchAddUsersToGroup()" "DEBUG"

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/AddUsersToGroup_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    $itemsToProcess = @()

    # Mode selection
    Write-Host "Select Input Mode:" -ForegroundColor Cyan
    Write-Host "1. Manual Input"
    Write-Host "2. CSV File (Batch)"
    Write-Host "3. Download CSV Template"

    $mode = Read-Host "Mode (1/2/3)"

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
        Write-Host "CSV columns: GroupName (required), UserName (required - comma or semicolon-separated for multiple users), MemberType (optional - default: Vault)" -ForegroundColor Yellow
        $CsvPath = Get-CACFilePath -Title "Select Add Users to Group CSV" -Filter "CSV Files (*.csv)|*.csv"

        if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path $CsvPath)) {
            Write-Host "CSV file not found." -ForegroundColor Red
            return
        }

        Write-Log "Processing CSV: $CsvPath" "INFO"
        # Import and expand: a single UserName cell may contain comma/semicolon-separated names
        $rawCsvData = Import-Csv $CsvPath
        foreach ($row in $rawCsvData) {
            $csvMemberType = if ($row.PSObject.Properties['MemberType'] -and $row.MemberType) { $row.MemberType.Trim() } else { "Vault" }
            $usersInRow = $row.UserName -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($u in $usersInRow) {
                $itemsToProcess += [PSCustomObject]@{
                    GroupName  = $row.GroupName.Trim()
                    UserName   = $u
                    MemberType = $csvMemberType
                }
            }
        }
    }
    elseif ($mode -eq '3') {
        New-CACAddUsersToGroupTemplate
        return
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

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
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
# 3. DELETE GROUPS (Manual or CSV)
# Manual: search by name, handle ambiguity; CSV: requires GroupId
# ============================================================
function Invoke-CACGroupDeletion {
    <#
    .SYNOPSIS
        Delete one or more CyberArk groups.
    .DESCRIPTION
        Mode 1 - Manual: Enter one or more group names (comma or semicolon separated).
                         Each name is searched. If multiple groups match, you are prompted
                         to pick which one to delete or skip entirely.
        Mode 2 - CSV:    GroupId is mandatory (used for deletion). GroupName is optional
                         (displayed for reference only). Deletes by ID with no ambiguity.
        Mode 3 - Template: Downloads a sample CSV template.
    #>
    [CmdletBinding()]
    param()

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/GroupDeletion_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Write-Log "Started Invoke-CACGroupDeletion()" "DEBUG"

    # ---- Mode Selection ----
    Write-Host ""
    Write-Host "Select Deletion Mode:" -ForegroundColor Cyan
    Write-Host "1. Manual  - Enter group name(s); search + confirm each"
    Write-Host "2. CSV     - Provide CSV with GroupId (mandatory) + GroupName (optional, for display)"
    Write-Host "3. Template - Download sample CSV template"
    $mode = (Read-Host "Mode (1/2/3)").Trim()

    # ----------------------------------------------------------------
    # MODE 1 - MANUAL
    # ----------------------------------------------------------------
    if ($mode -eq '1') {
        $nameInput = Read-Host "Enter group name(s) to delete (comma or semicolon separated)"
        if ([string]::IsNullOrWhiteSpace($nameInput)) {
            Write-Warning "No group name provided."
            return
        }

        $names = $nameInput -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $resolved = [System.Collections.ArrayList]::new()

        foreach ($name in $names) {
            Write-Host ""
            Write-Host "Searching for: '$name'..." -ForegroundColor Cyan -NoNewline
            try {
                $res = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($name))"
                $searchResults = @($res.value | Where-Object { $_ })

                if ($searchResults.Count -eq 0) {
                    Write-Host " [NOT FOUND]" -ForegroundColor Yellow
                    Write-Log "Group not found: $name" "WARN"
                    continue
                }

                # Prefer exact name match
                $exact = @($searchResults | Where-Object { $_.groupName -ieq $name })

                if ($exact.Count -eq 1) {
                    Write-Host " [FOUND]" -ForegroundColor Green
                    [void]$resolved.Add($exact[0])
                }
                elseif ($exact.Count -eq 0 -and $searchResults.Count -eq 1) {
                    # Only one result, not exact - show and confirm
                    Write-Host " [1 result found]" -ForegroundColor Green
                    Write-Host "  Group: $($searchResults[0].groupName) | ID: $($searchResults[0].id) | Type: $($searchResults[0].groupType)"
                    $c = Read-Host "  Include this group for deletion? (Y/N)"
                    if ($c -match '^[Yy]$') { [void]$resolved.Add($searchResults[0]) }
                }
                else {
                    # Multiple matches - let user pick
                    Write-Host " [$($searchResults.Count) matches]" -ForegroundColor Yellow
                    Write-Host "  Multiple groups found for '$name':" -ForegroundColor Yellow
                    for ($j = 0; $j -lt $searchResults.Count; $j++) {
                        Write-Host "  [$($j+1)] $($searchResults[$j].groupName) | ID: $($searchResults[$j].id) | Type: $($searchResults[$j].groupType)"
                    }
                    Write-Host "  [S] Skip"
                    $pick = Read-Host "  Select a number to delete, or S to skip"
                    if ($pick -match '^\d+$') {
                        $idx = [int]$pick - 1
                        if ($idx -ge 0 -and $idx -lt $searchResults.Count) {
                            [void]$resolved.Add($searchResults[$idx])
                        }
                        else { Write-Host "  Invalid selection - skipped." -ForegroundColor Yellow }
                    }
                    else { Write-Host "  Skipped." -ForegroundColor Gray }
                }
            }
            catch {
                Write-Host " [ERROR: $($_.Exception.Message)]" -ForegroundColor Red
                Write-Log "Search failed for '$name': $($_.Exception.Message)" "ERROR"
            }
        }

        if ($resolved.Count -eq 0) {
            Write-Host "No groups resolved for deletion." -ForegroundColor Yellow
            return
        }

        # Confirmation summary
        Write-Host ""
        Write-Host "===== DELETION SUMMARY =====" -ForegroundColor Red
        $resolved | ForEach-Object { Write-Host "  - $($_.groupName) (ID: $($_.id))" -ForegroundColor DarkGray }
        Write-Host "============================" -ForegroundColor Red
        $confirm = Read-Host "PERMANENTLY DELETE the above $($resolved.Count) group(s)? (Y/N)"
        if ($confirm -notmatch '^[Yy]$') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        $results = @()
        $i = 0
        foreach ($grp in $resolved) {
            $i++
            Write-Host "[$i/$($resolved.Count)] Deleting '$($grp.groupName)' (ID: $($grp.id))..." -NoNewline
            $row = [PSCustomObject]@{ GroupName = $grp.groupName; GroupId = $grp.id; DeletionStatus = ""; Message = "" }
            try {
                Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$($grp.id)"
                Write-Host " [DELETED]" -ForegroundColor Green
                $row.DeletionStatus = "Deleted"
                $row.Message = "Success"
                Write-Log "Deleted group '$($grp.groupName)' (ID: $($grp.id))" "SUCCESS"
            }
            catch {
                Write-Host " [FAILED]" -ForegroundColor Red
                $row.DeletionStatus = "Failed"
                $row.Message = $_.Exception.Message
                Write-Log "Failed to delete '$($grp.groupName)': $($_.Exception.Message)" "ERROR"
            }
            $results += $row
        }

        $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "`nDone. Results: $OutputCsvPath" -ForegroundColor Green
    }

    # ----------------------------------------------------------------
    # MODE 2 - CSV  (GroupId mandatory, GroupName optional for display)
    # ----------------------------------------------------------------
    elseif ($mode -eq '2') {
        Write-Host "CSV columns: GroupId (REQUIRED - used for deletion), GroupName (optional - display only)" -ForegroundColor Yellow
        $CsvPath = Get-CACFilePath -Title "Select Group Deletion CSV" -Filter "CSV Files (*.csv)|*.csv"

        if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path $CsvPath)) {
            Write-Host "CSV file not found." -ForegroundColor Red
            return
        }

        $csvData = Import-Csv $CsvPath
        if ($csvData.Count -eq 0) { Write-Warning "CSV is empty."; return }

        # Validate GroupId column exists
        $sample = $csvData[0]
        if (-not $sample.PSObject.Properties['GroupId']) {
            Write-Host "ERROR: CSV must contain a 'GroupId' column." -ForegroundColor Red
            return
        }

        # Summary
        Write-Host ""
        Write-Host "===== DELETION SUMMARY =====" -ForegroundColor Red
        Write-Host "Total rows: $($csvData.Count)"
        if ($csvData.Count -lt 11) {
            $csvData | ForEach-Object {
                $disp = if ($_.PSObject.Properties['GroupName'] -and $_.GroupName) { "$($_.GroupName) (ID: $($_.GroupId))" } else { "ID: $($_.GroupId)" }
                Write-Host "  - $disp" -ForegroundColor DarkGray
            }
        }
        else {
            $first = if ($csvData[0].GroupName) { "$($csvData[0].GroupName) (ID: $($csvData[0].GroupId))" } else { "ID: $($csvData[0].GroupId)" }
            Write-Host "  - $first" -ForegroundColor DarkGray
            Write-Host "  - ... and $($csvData.Count - 1) more." -ForegroundColor DarkGray
        }
        Write-Host "============================" -ForegroundColor Red

        $confirm = Read-Host "PERMANENTLY DELETE these $($csvData.Count) group(s) by ID? (Y/N)"
        if ($confirm -notmatch '^[Yy]$') { Write-Host "Cancelled." -ForegroundColor Yellow; return }

        $results = @()
        $i = 0
        foreach ($row in $csvData) {
            $i++
            $groupId = $row.GroupId.Trim()
            $groupName = if ($row.PSObject.Properties['GroupName'] -and $row.GroupName) { $row.GroupName } else { "ID $groupId" }

            if ([string]::IsNullOrWhiteSpace($groupId)) {
                Write-Warning "Row $i - GroupId is empty - skipped."
                continue
            }

            Write-Host "[$i/$($csvData.Count)] Deleting '$groupName' (ID: $groupId)..." -NoNewline
            Write-Progress -Activity "Deleting Groups" -Status "[$i/$($csvData.Count)] $groupName" -PercentComplete (($i / $csvData.Count) * 100)

            $resObj = $row | Select-Object *
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message"        -Value "" -Force

            try {
                Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$groupId"
                Write-Host " [DELETED]" -ForegroundColor Green
                $resObj.DeletionStatus = "Deleted"
                $resObj.Message = "Success"
                Write-Log "Deleted group '$groupName' (ID: $groupId)" "SUCCESS"
            }
            catch {
                $err = $_.Exception.Message
                Write-Host " [FAILED]" -ForegroundColor Red
                $resObj.DeletionStatus = "Failed"
                $resObj.Message = $err
                Write-Log "Failed to delete '$groupName' (ID: $groupId): $err" "ERROR"
            }
            $results += $resObj
        }
        Write-Progress -Activity "Deleting Groups" -Completed

        $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "`nDone. Results: $OutputCsvPath" -ForegroundColor Green
        Write-Log "Group Deletion complete. Results: $OutputCsvPath" "INFO"
    }

    # ----------------------------------------------------------------
    # MODE 3 - TEMPLATE DOWNLOAD
    # ----------------------------------------------------------------
    elseif ($mode -eq '3') {
        $templatePath = Join-Path (Get-CACOutputDir) "GroupDeletion_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        @(
            [pscustomobject][ordered]@{ GroupId = "12345"; GroupName = "MyGroup_RW" },
            [pscustomobject][ordered]@{ GroupId = "67890"; GroupName = "MyGroup_R" }
        ) | Export-Csv -Path $templatePath -NoTypeInformation -Encoding UTF8
        Write-Host "Template created: $templatePath" -ForegroundColor Green
        Write-Host "Note: GroupId is MANDATORY. GroupName is optional and used for display only." -ForegroundColor Yellow
    }
    else {
        Write-Warning "Invalid selection."
    }
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
# TEMPLATE: Add Users to Group
# ============================================================
function New-CACAddUsersToGroupTemplate {
    <#
    .SYNOPSIS
        Generate a CSV template for Invoke-CACBatchAddUsersToGroup.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "AddUsersToGroup_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $rows = @(
        [pscustomobject][ordered]@{ GroupName = "MyGroup"; UserName = "user1;user2;user3"; MemberType = "Vault" },
        [pscustomobject][ordered]@{ GroupName = "AnotherGroup"; UserName = "alice"; MemberType = "Vault" }
    )

    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host "Tip: Multiple users per row - separate with comma or semicolon in the UserName column." -ForegroundColor Yellow
    Write-Host "MemberType options: Vault (default)" -ForegroundColor Gray
    return $Path
}


# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Invoke-CACBatchGroupCreation, `
    Invoke-CACBatchAddUsersToGroup, `
    Invoke-CACGroupDeletion, `
    Reset-CACUserPassword, `
    New-CACAddUsersToGroupTemplate

