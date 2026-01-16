# =============================================================================
# SafeActions.psm1
# Description: Safe Operations - Create and Rename (Batch from CSV)
# =============================================================================

# =============================================================================
# 1. BATCH SAFE CREATION
# =============================================================================
function Invoke-CACBatchSafeCreation {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    Write-Log "Started Invoke-CACBatchSafeCreation()" "DEBUG"

    # Prompt for template if needed
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        Write-Host "Would you like to download a sample CSV template first?" -ForegroundColor Cyan
        $templateChoice = Read-Host "(Y)es / (N)o, I have my CSV ready"
        
        if ($templateChoice -eq 'Y' -or $templateChoice -eq 'y') {
            New-CACSafeCreationTemplate
            return
        }

        $CsvPath = Read-Host "Enter CSV Path"
    }

    if (-not (Test-Path $CsvPath)) { 
        Write-Host "CSV not found: $CsvPath" -ForegroundColor Red
        return 
    }

    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeCreation_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["Write-Log:LogName"] = "SafeCreation"

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = [System.Collections.ArrayList]::new()
    $data = Import-Csv $CsvPath

    Write-Log "Processing $($data.Count) rows from CSV" "INFO"

    foreach ($row in $data) {
        $safeName = $row.SafeName.Trim()
        $safeMember = if ($row.PSObject.Properties['SafeMember']) { $row.SafeMember.Trim() } else { "" }
        $memberType = if ($row.PSObject.Properties['MemberType']) { $row.MemberType.Trim() } else { "Group" }
        $groupMembers = if ($row.PSObject.Properties['GroupMembers']) { $row.GroupMembers.Trim() } else { "" }

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING: Safe [$safeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        $result = [ordered]@{
            SafeName      = $safeName
            SafeStatus    = "Unknown"
            SafeMember    = $safeMember
            MemberType    = $memberType
            MemberStatus  = "N/A"
            MembersAdded  = ""
            MembersFailed = ""
            OverallStatus = "FAILED"
            Message       = ""
        }

        # --- 1. SAFE CHECK / CREATE ---
        $safeReady = $false
        Write-Host " -> Checking Safe..." -NoNewline
        try {
            $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))" -ErrorAction SilentlyContinue
            if ($safe) {
                $safeReady = $true
                $result.SafeStatus = "Exists"
                Write-Host " [EXISTS]" -ForegroundColor Green
            }
        }
        catch {
            # Safe doesn't exist, create it
            try {
                $safeBody = @{ safeName = $safeName }
                if (-not [string]::IsNullOrWhiteSpace($row.SafeDescription)) { $safeBody["description"] = $row.SafeDescription }
                if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $safeBody["managingCPM"] = $row.ManagingCPM }
                if ($row.NumberOfDaysRetention) { $safeBody["numberOfDaysRetention"] = [int]$row.NumberOfDaysRetention }
                if ($row.NumberOfVersionsRetention) { $safeBody["numberOfVersionsRetention"] = [int]$row.NumberOfVersionsRetention }

                Write-Host " Creating..." -NoNewline
                Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes" -Body $safeBody | Out-Null
                $safeReady = $true
                $result.SafeStatus = "Created"
                Write-Host " [CREATED]" -ForegroundColor Green
            }
            catch {
                $result.SafeStatus = "Failed"
                $result.Message = "Safe creation failed: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
            }
        }

        if (-not $safeReady) { 
            [void]$results.Add([pscustomobject]$result)
            continue 
        }

        # Skip if no member specified
        if ([string]::IsNullOrWhiteSpace($safeMember)) {
            $result.OverallStatus = "SUCCESS"
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 2. HANDLE MEMBER (Group or User) ---
        $memberReady = $false
        $groupId = $null

        if ($memberType -eq "Group") {
            # Check/Create Group
            Write-Host " -> Checking Group [$safeMember]..." -NoNewline
            try {
                $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($safeMember))"
                $existingGroup = $groups.value | Where-Object { $_.groupName -eq $safeMember } | Select-Object -First 1
                
                if ($existingGroup) {
                    $memberReady = $true
                    $groupId = $existingGroup.id
                    $result.MemberStatus = "Exists"
                    Write-Host " [EXISTS]" -ForegroundColor Green
                }
                else {
                    Write-Host " Creating..." -NoNewline
                    $newGroup = Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups" -Body @{ groupName = $safeMember }
                    $memberReady = $true
                    $groupId = $newGroup.id
                    $result.MemberStatus = "Created"
                    Write-Host " [CREATED]" -ForegroundColor Green
                }
            }
            catch {
                $result.MemberStatus = "Failed"
                $result.Message += " Group error: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
            }

            # Add users to group if specified
            if ($memberReady -and -not [string]::IsNullOrWhiteSpace($groupMembers)) {
                $members = $groupMembers -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                $addedMembers = @()
                $failedMembers = @()

                Write-Host " -> Adding users to group..." -ForegroundColor Cyan
                foreach ($member in $members) {
                    Write-Host "    - $member..." -NoNewline
                    try {
                        $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($member))"
                        $user = $users.Users | Where-Object { $_.username -eq $member } | Select-Object -First 1
                        
                        if ($user) {
                            Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups/$groupId/Members" -Body @{ memberId = $user.id } | Out-Null
                            $addedMembers += $member
                            Write-Host " [ADDED]" -ForegroundColor Green
                        }
                        else {
                            $failedMembers += "$member(NotFound)"
                            Write-Host " [NOT FOUND]" -ForegroundColor Yellow
                        }
                    }
                    catch {
                        if ($_.Exception.Message -match "409|already exists") {
                            $addedMembers += "$member(Exists)"
                            Write-Host " [ALREADY MEMBER]" -ForegroundColor Green
                        }
                        else {
                            $failedMembers += "$member(Error)"
                            Write-Host " [FAILED]" -ForegroundColor Red
                        }
                    }
                }
                $result.MembersAdded = $addedMembers -join ";"
                $result.MembersFailed = $failedMembers -join ";"
            }
        }
        else {
            # User - just validate exists
            Write-Host " -> Checking User [$safeMember]..." -NoNewline
            try {
                $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($safeMember))"
                $user = $users.Users | Where-Object { $_.username -eq $safeMember } | Select-Object -First 1
                
                if ($user) {
                    $memberReady = $true
                    $result.MemberStatus = "Exists"
                    Write-Host " [EXISTS]" -ForegroundColor Green
                }
                else {
                    $result.MemberStatus = "NotFound"
                    Write-Host " [NOT FOUND]" -ForegroundColor Red
                }
            }
            catch {
                $result.MemberStatus = "Failed"
                $result.Message += " User lookup error: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
            }
        }

        if (-not $memberReady) {
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 3. ADD MEMBER TO SAFE ---
        Write-Host " -> Adding $memberType to Safe..." -NoNewline
        
        # Build permissions
        $permSource = if ($row.Permissions) { 
            $row.Permissions -split ";" | ForEach-Object { $_.Trim() } 
        }
        else { 
            $permissionSets.$($row.PermissionKey) 
        }

        $validPerms = @("useAccounts", "retrieveAccounts", "listAccounts", "addAccounts",
            "updateAccountContent", "updateAccountProperties", 
            "initiateCPMAccountManagementOperations", "specifyNextAccountContent",
            "renameAccounts", "deleteAccounts", "unlockAccounts",
            "manageSafe", "manageSafeMembers", "backupSafe",
            "viewAuditLog", "viewSafeMembers", "accessWithoutConfirmation",
            "createFolders", "deleteFolders", "moveAccountsAndFolders",
            "requestsAuthorizationLevel1", "requestsAuthorizationLevel2")
        
        $permissions = @{}
        foreach ($p in $validPerms) { $permissions[$p] = $false }
        foreach ($p in $permSource) {
            $match = $validPerms | Where-Object { $_ -eq $p } | Select-Object -First 1
            if ($match) { $permissions[$match] = $true }
        }

        try {
            Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members" -Body @{
                memberName  = $safeMember
                permissions = $permissions
            } | Out-Null
            Write-Host " [ADDED]" -ForegroundColor Green
            $result.OverallStatus = "SUCCESS"
        }
        catch {
            if ($_.Exception.Message -match "409|already exists") {
                try {
                    Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members/$([System.Web.HttpUtility]::UrlEncode($safeMember))" -Body @{ permissions = $permissions } | Out-Null
                    Write-Host " [UPDATED]" -ForegroundColor Green
                    $result.OverallStatus = "SUCCESS"
                }
                catch {
                    Write-Host " [FAILED]" -ForegroundColor Red
                    $result.Message += " Safe member update failed."
                }
            }
            else {
                Write-Host " [FAILED]" -ForegroundColor Red
                $result.Message += " Safe member add failed: $($_.Exception.Message)"
            }
        }

        [void]$results.Add([pscustomobject]$result)
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Log "Safe Creation Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
}

# =============================================================================
# 2. BATCH SAFE RENAME
# =============================================================================
function Invoke-CACBatchSafeRename {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    Write-Log "Started Invoke-CACBatchSafeRename()" "DEBUG"

    # Prompt for template if needed
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        Write-Host "Would you like to download a sample CSV template first?" -ForegroundColor Cyan
        $templateChoice = Read-Host "(Y)es / (N)o, I have my CSV ready"
        
        if ($templateChoice -eq 'Y' -or $templateChoice -eq 'y') {
            New-CACSafeRenameTemplate
            return
        }

        $CsvPath = Read-Host "Enter CSV Path"
    }

    if (-not (Test-Path $CsvPath)) { 
        Write-Host "CSV not found: $CsvPath" -ForegroundColor Red
        return 
    }

    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeRename_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["Write-Log:LogName"] = "SafeRename"

    $results = [System.Collections.ArrayList]::new()
    $data = Import-Csv $CsvPath

    Write-Log "Processing $($data.Count) rows from CSV" "INFO"

    foreach ($row in $data) {
        $oldSafeName = $row.OldSafeName.Trim()
        $newSafeName = $row.SafeName.Trim()
        $oldGroupName = if ($row.PSObject.Properties['OldGroupName']) { $row.OldGroupName.Trim() } else { "" }
        $newGroupName = if ($row.PSObject.Properties['GroupName']) { $row.GroupName.Trim() } else { "" }

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " RENAMING: [$oldSafeName] -> [$newSafeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        $result = [ordered]@{
            OldSafeName   = $oldSafeName
            NewSafeName   = $newSafeName
            SafeStatus    = "Unknown"
            OldGroupName  = $oldGroupName
            NewGroupName  = $newGroupName
            GroupStatus   = "N/A"
            OverallStatus = "FAILED"
            Message       = ""
        }

        # --- 1. CHECK IF NEW SAFE ALREADY EXISTS ---
        Write-Host " -> Checking if [$newSafeName] exists..." -NoNewline
        try {
            $existingSafe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))" -ErrorAction SilentlyContinue
            if ($existingSafe) {
                $result.SafeStatus = "AlreadyExists"
                $result.Message = "Target safe name already exists"
                Write-Host " [ALREADY EXISTS - SKIP]" -ForegroundColor Yellow
                [void]$results.Add([pscustomobject]$result)
                continue
            }
        }
        catch {
            Write-Host " [OK]" -ForegroundColor Green
        }

        # --- 2. CHECK IF OLD SAFE EXISTS ---
        Write-Host " -> Checking if [$oldSafeName] exists..." -NoNewline
        try {
            $oldSafe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($oldSafeName))" -ErrorAction SilentlyContinue
            if (-not $oldSafe) {
                $result.SafeStatus = "NotFound"
                $result.Message = "Source safe not found"
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                [void]$results.Add([pscustomobject]$result)
                continue
            }
            Write-Host " [FOUND]" -ForegroundColor Green
        }
        catch {
            $result.SafeStatus = "NotFound"
            $result.Message = "Source safe not found"
            Write-Host " [NOT FOUND]" -ForegroundColor Red
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 3. RENAME SAFE ---
        Write-Host " -> Renaming Safe..." -NoNewline
        try {
            $updateBody = @{ safeName = $newSafeName }
            if (-not [string]::IsNullOrWhiteSpace($row.SafeDescription)) { $updateBody["description"] = $row.SafeDescription }
            if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $updateBody["managingCPM"] = $row.ManagingCPM }

            Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($oldSafeName))" -Body $updateBody | Out-Null
            $result.SafeStatus = "Renamed"
            Write-Host " [RENAMED]" -ForegroundColor Green
        }
        catch {
            $result.SafeStatus = "Failed"
            $result.Message = "Safe rename failed: $($_.Exception.Message)"
            Write-Host " [FAILED]" -ForegroundColor Red
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 4. RENAME GROUP (if specified) ---
        if (-not [string]::IsNullOrWhiteSpace($oldGroupName) -and -not [string]::IsNullOrWhiteSpace($newGroupName)) {
            Write-Host " -> Renaming Group [$oldGroupName] -> [$newGroupName]..." -NoNewline
            try {
                $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($oldGroupName))"
                $srcGroup = $groups.value | Where-Object { $_.groupName -eq $oldGroupName } | Select-Object -First 1
                
                if (-not $srcGroup) {
                    $result.GroupStatus = "NotFound"
                    Write-Host " [SOURCE NOT FOUND]" -ForegroundColor Yellow
                }
                else {
                    # Check if target group already exists
                    $targetGroups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($newGroupName))"
                    $tgtGroup = $targetGroups.value | Where-Object { $_.groupName -eq $newGroupName } | Select-Object -First 1
                    
                    if ($tgtGroup) {
                        $result.GroupStatus = "TargetExists"
                        Write-Host " [TARGET ALREADY EXISTS]" -ForegroundColor Yellow
                    }
                    else {
                        Invoke-CACAPIRequest -Method PUT -Endpoint "/API/UserGroups/$($srcGroup.id)" -Body @{ groupName = $newGroupName } | Out-Null
                        $result.GroupStatus = "Renamed"
                        Write-Host " [RENAMED]" -ForegroundColor Green
                    }
                }
            }
            catch {
                $result.GroupStatus = "Failed"
                $result.Message += " Group rename error: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
            }
        }

        $result.OverallStatus = "SUCCESS"
        [void]$results.Add([pscustomobject]$result)
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Log "Safe Rename Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
}

# =============================================================================
# 3. CSV TEMPLATE GENERATORS
# =============================================================================
function New-CACSafeCreationTemplate {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeCreation_Template.csv"
    }

    $template = [ordered]@{
        SafeName                  = "Example_Safe"
        SafeDescription           = "Safe Description"
        ManagingCPM               = "PasswordManager"
        NumberOfDaysRetention     = "7"
        NumberOfVersionsRetention = ""
        SafeMember                = "Domain\SafeGroup"
        MemberType                = "Group"
        GroupMembers              = "user1;user2;user3"
        PermissionKey             = "SAFE_READ"
        Permissions               = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "CSV Columns:" -ForegroundColor Cyan
    Write-Host "  SafeName                  - Name of the safe to create"
    Write-Host "  SafeDescription           - Description (optional)"
    Write-Host "  ManagingCPM               - CPM name (optional)"
    Write-Host "  NumberOfDaysRetention     - Days to retain (optional, mutually exclusive with versions)"
    Write-Host "  NumberOfVersionsRetention - Versions to retain (optional, mutually exclusive with days)"
    Write-Host "  SafeMember                - User or Group name to add as safe member"
    Write-Host "  MemberType                - 'User' or 'Group'"
    Write-Host "  GroupMembers              - Users to add to group (semicolon-separated, only for MemberType=Group)"
    Write-Host "  PermissionKey             - Key from config (e.g., SAFE_READ, SAFE_READWRITE)"
    Write-Host "  Permissions               - Override permissions (semicolon-separated)"
    
    return $Path
}

function New-CACSafeRenameTemplate {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeRename_Template.csv"
    }

    $template = [ordered]@{
        OldSafeName     = "Old_Safe_Name"
        SafeName        = "New_Safe_Name"
        SafeDescription = "Updated Description"
        ManagingCPM     = "PasswordManager"
        OldGroupName    = "KA_Old_Safe_Name_R"
        GroupName       = "KA_New_Safe_Name_R"
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "CSV Columns:" -ForegroundColor Cyan
    Write-Host "  OldSafeName     - Current safe name to rename FROM"
    Write-Host "  SafeName        - New safe name to rename TO"
    Write-Host "  SafeDescription - Updated description (optional)"
    Write-Host "  ManagingCPM     - CPM name (optional)"
    Write-Host "  OldGroupName    - Current group name to rename (optional)"
    Write-Host "  GroupName       - New group name (optional)"
    
    return $Path
}

# =============================================================================
# EXPORT
# =============================================================================
Export-ModuleMember -Function `
    Invoke-CACBatchSafeCreation, `
    Invoke-CACBatchSafeRename, `
    New-CACSafeCreationTemplate, `
    New-CACSafeRenameTemplate
