# =============================================================================
# SafeActions.psm1
# Description: Safe Operations - Create, Rename, and Member Management
# =============================================================================

# =============================================================================
# 1. BATCH SAFE CREATION
# Creates safes in batch from CSV, with group/member management
# =============================================================================
function Invoke-CACBatchSafeCreation {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    # Initialize dedicated log file for this operation
    $logDir = "$PSScriptRoot/../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "SafeCreation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    # Local logging function
    function Log {
        param($Msg, $Level = "INFO")
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
        Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
        if ($Level -eq "DEBUG") { Write-Verbose $entry }
    }

    Log "Started Invoke-CACBatchSafeCreation()" "DEBUG"
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    # Prompt for CSV path
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        $CsvPath = Read-Host "Enter CSV file path (or 'T' to download template)"
        
        if ($CsvPath -eq 'T' -or $CsvPath -eq 't') {
            New-CACSafeCreationTemplate
            return
        }
    }

    if (-not (Test-Path $CsvPath)) { 
        Write-Host "CSV not found: $CsvPath" -ForegroundColor Red
        return 
    }

    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeCreation_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = [System.Collections.ArrayList]::new()
    $data = Import-Csv $CsvPath

    Log "Processing $($data.Count) rows from CSV" "INFO"
    Write-Host "Processing $($data.Count) rows..." -ForegroundColor Cyan

    foreach ($row in $data) {
        $safeName = $row.SafeName.Trim()
        $safeMember = if ($row.PSObject.Properties['SafeMember']) { $row.SafeMember.Trim() } else { "" }
        $memberType = if ($row.PSObject.Properties['MemberType']) { $row.MemberType.Trim() } else { "Group" }
        $groupMembers = if ($row.PSObject.Properties['GroupMembers']) { $row.GroupMembers.Trim() } else { "" }
        $groupDescription = if ($row.PSObject.Properties['GroupDescription']) { $row.GroupDescription.Trim() } else { "" }

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING: Safe [$safeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan
        Log "Processing Safe: $safeName, Member: $safeMember, Type: $memberType" "INFO"

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
        Log "Checking if safe exists: $safeName" "DEBUG"
        try {
            $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))" -ErrorAction SilentlyContinue
            if ($safe) {
                $safeReady = $true
                $result.SafeStatus = "Exists"
                Write-Host " [EXISTS]" -ForegroundColor Green
                Log "Safe exists: $safeName" "INFO"
            }
        }
        catch {
            Log "Safe not found, creating: $safeName" "DEBUG"
            # Safe doesn't exist, create it
            try {
                $safeBody = @{ safeName = $safeName }
                if (-not [string]::IsNullOrWhiteSpace($row.SafeDescription)) { $safeBody["description"] = $row.SafeDescription }
                if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $safeBody["managingCPM"] = $row.ManagingCPM }
                if ($row.NumberOfDaysRetention) { $safeBody["numberOfDaysRetention"] = [int]$row.NumberOfDaysRetention }
                if ($row.NumberOfVersionsRetention) { $safeBody["numberOfVersionsRetention"] = [int]$row.NumberOfVersionsRetention }

                Log "Creating safe with body: $($safeBody | ConvertTo-Json -Compress)" "DEBUG"
                Write-Host " Creating..." -NoNewline
                Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes" -Body $safeBody | Out-Null
                $safeReady = $true
                $result.SafeStatus = "Created"
                Write-Host " [CREATED]" -ForegroundColor Green
                Log "Safe created: $safeName" "SUCCESS"
            }
            catch {
                $result.SafeStatus = "Failed"
                $result.Message = "Safe creation failed: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
                Log "Safe creation failed: $($_.Exception.Message)" "ERROR"
            }
        }

        if (-not $safeReady) { 
            [void]$results.Add([pscustomobject]$result)
            continue 
        }

        # Skip if no member specified
        if ([string]::IsNullOrWhiteSpace($safeMember)) {
            $result.OverallStatus = "SUCCESS"
            Log "No member specified, safe creation complete" "INFO"
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 2. HANDLE MEMBER (Group or User) ---
        $memberReady = $false
        $groupId = $null

        if ($memberType -eq "Group") {
            # Check/Create Group
            Write-Host " -> Checking Group [$safeMember]..." -NoNewline
            Log "Checking group: $safeMember" "DEBUG"
            try {
                $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($safeMember))"
                $existingGroup = $groups.value | Where-Object { $_.groupName -eq $safeMember } | Select-Object -First 1
                
                if ($existingGroup) {
                    $memberReady = $true
                    $groupId = $existingGroup.id
                    $result.MemberStatus = "Exists"
                    Write-Host " [EXISTS]" -ForegroundColor Green
                    Log "Group exists: $safeMember (ID: $groupId)" "INFO"
                }
                else {
                    Write-Host " Creating..." -NoNewline
                    Log "Creating group: $safeMember" "DEBUG"
                    $groupBody = @{ groupName = $safeMember }
                    if (-not [string]::IsNullOrWhiteSpace($groupDescription)) {
                        $groupBody["description"] = $groupDescription
                        Log "Group description: $groupDescription" "DEBUG"
                    }
                    $newGroup = Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups" -Body $groupBody
                    $memberReady = $true
                    $groupId = $newGroup.id
                    $result.MemberStatus = "Created"
                    Write-Host " [CREATED]" -ForegroundColor Green
                    Log "Group created: $safeMember (ID: $groupId)" "SUCCESS"
                }
            }
            catch {
                $result.MemberStatus = "Failed"
                $result.Message += " Group error: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
                Log "Group check/create failed: $($_.Exception.Message)" "ERROR"
            }

            # Add users to group ONLY if group was newly created
            if ($memberReady -and $result.MemberStatus -eq "Created" -and -not [string]::IsNullOrWhiteSpace($groupMembers)) {
                $members = $groupMembers -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                $addedMembers = @()
                $failedMembers = @()

                Write-Host " -> Adding users to group..." -ForegroundColor Cyan
                Log "Adding $($members.Count) users to group $safeMember" "INFO"
                
                foreach ($member in $members) {
                    Write-Host "    - $member..." -NoNewline
                    Log "Adding user to group: $member" "DEBUG"
                    
                    try {
                        $addMemberBody = @{
                            memberId   = $member
                            memberType = "Vault"
                        }
                        
                        Log "POST /API/UserGroups/$groupId/Members - Body: $($addMemberBody | ConvertTo-Json -Compress)" "DEBUG"
                        Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups/$groupId/Members" -Body $addMemberBody | Out-Null
                        $addedMembers += $member
                        Write-Host " [ADDED]" -ForegroundColor Green
                        Log "User added to group: $member" "SUCCESS"
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        Log "Failed to add user $member to group: $errMsg" "ERROR"
                        
                        if ($errMsg -match "409|already exists|ITATS262E") {
                            $addedMembers += "$member(Exists)"
                            Write-Host " [ALREADY MEMBER]" -ForegroundColor Green
                            Log "User already member: $member" "INFO"
                        }
                        else {
                            $failedMembers += "$member(Error)"
                            Write-Host " [FAILED: $errMsg]" -ForegroundColor Red
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
            Log "Checking user: $safeMember" "DEBUG"
            try {
                $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($safeMember))"
                $user = $users.Users | Where-Object { $_.username -eq $safeMember } | Select-Object -First 1
                
                if ($user) {
                    $memberReady = $true
                    $result.MemberStatus = "Exists"
                    Write-Host " [EXISTS]" -ForegroundColor Green
                    Log "User exists: $safeMember" "INFO"
                }
                else {
                    $result.MemberStatus = "NotFound"
                    Write-Host " [NOT FOUND]" -ForegroundColor Red
                    Log "User not found: $safeMember" "WARN"
                }
            }
            catch {
                $result.MemberStatus = "Failed"
                $result.Message += " User lookup error: $($_.Exception.Message)"
                Write-Host " [FAILED]" -ForegroundColor Red
                Log "User lookup failed: $($_.Exception.Message)" "ERROR"
            }
        }

        if (-not $memberReady) {
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 3. ADD MEMBER TO SAFE ---
        Write-Host " -> Adding $memberType to Safe..." -NoNewline
        Log "Adding $memberType '$safeMember' to safe '$safeName'" "DEBUG"
        
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

        Log "Permissions: $(($permissions.Keys | Where-Object { $permissions[$_] }) -join ', ')" "DEBUG"

        try {
            $safeMemberBody = @{
                memberName  = $safeMember
                permissions = $permissions
            }
            Log "POST /API/Safes/$safeName/Members - Body: $($safeMemberBody | ConvertTo-Json -Compress -Depth 3)" "DEBUG"
            
            Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members" -Body $safeMemberBody | Out-Null
            Write-Host " [ADDED]" -ForegroundColor Green
            $result.OverallStatus = "SUCCESS"
            Log "Member added to safe successfully" "SUCCESS"
        }
        catch {
            $errMsg = $_.Exception.Message
            Log "Failed to add member to safe: $errMsg" "ERROR"
            
            if ($errMsg -match "409|already exists") {
                try {
                    Log "Member exists, updating permissions..." "DEBUG"
                    Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members/$([System.Web.HttpUtility]::UrlEncode($safeMember))" -Body @{ permissions = $permissions } | Out-Null
                    Write-Host " [UPDATED]" -ForegroundColor Green
                    $result.OverallStatus = "SUCCESS"
                    Log "Member permissions updated" "SUCCESS"
                }
                catch {
                    Write-Host " [FAILED]" -ForegroundColor Red
                    $result.Message += " Safe member update failed: $($_.Exception.Message)"
                    Log "Failed to update member permissions: $($_.Exception.Message)" "ERROR"
                }
            }
            else {
                Write-Host " [FAILED]" -ForegroundColor Red
                $result.Message += " Safe member add failed: $errMsg"
            }
        }

        [void]$results.Add([pscustomobject]$result)
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Log "Safe Creation Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
    Write-Host "Log file: $logFile" -ForegroundColor Gray
}

# =============================================================================
# 2. BATCH SAFE RENAME
# Renames safes and associated groups (KA_..._R/RW) from CSV
# =============================================================================
function Invoke-CACBatchSafeRename {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    # Initialize dedicated log file for this operation
    $logDir = "$PSScriptRoot/../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "SafeRename_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    # Local logging function
    function Log {
        param($Msg, $Level = "INFO")
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
        Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
        if ($Level -eq "DEBUG") { Write-Verbose $entry }
    }

    Log "Started Invoke-CACBatchSafeRename()" "DEBUG"
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    # Prompt for CSV path
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        $CsvPath = Read-Host "Enter CSV file path (or 'T' to download template)"
        
        if ($CsvPath -eq 'T' -or $CsvPath -eq 't') {
            New-CACSafeRenameTemplate
            return
        }
    }

    if (-not (Test-Path $CsvPath)) { 
        Write-Host "CSV not found: $CsvPath" -ForegroundColor Red
        return 
    }

    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeRename_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    # Load config for default members and permission sets
    $config = Get-CACConfig
    $defaultSafeMembers = $config.DefaultSafeMembers
    $permissionSets = $config.SafePermissionSets
    
    # Standard Permission Lists
    $validPerms = @("useAccounts", "retrieveAccounts", "listAccounts", "addAccounts",
        "updateAccountContent", "updateAccountProperties", "initiateCPMAccountManagementOperations", 
        "specifyNextAccountContent", "renameAccounts", "deleteAccounts", "unlockAccounts",
        "manageSafe", "manageSafeMembers", "backupSafe", "viewAuditLog", "viewSafeMembers", 
        "accessWithoutConfirmation", "createFolders", "deleteFolders", "moveAccountsAndFolders",
        "requestsAuthorizationLevel1", "requestsAuthorizationLevel2")

    # Group Default Perms (For Self-Healing)
    $permsR = @("useAccounts", "retrieveAccounts", "listAccounts")
    $permsRW = @("useAccounts", "retrieveAccounts", "listAccounts", "addAccounts", 
        "updateAccountContent", "updateAccountProperties", "renameAccounts", 
        "deleteAccounts", "unlockAccounts")

    $results = [System.Collections.ArrayList]::new()
    $data = Import-Csv $CsvPath

    Log "Processing $($data.Count) rows from CSV" "INFO"
    Log "Default Safe Members from config: $($defaultSafeMembers.Keys -join ', ')" "INFO"
    Write-Host "Processing $($data.Count) rows..." -ForegroundColor Cyan

    foreach ($row in $data) {
        $oldSafeName = $row.OldSafeName.Trim()
        $newSafeName = $row.SafeName.Trim()

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " RENAMING: [$oldSafeName] -> [$newSafeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan
        Log "Processing Safe: $oldSafeName -> $newSafeName" "INFO"

        $result = [ordered]@{
            OldSafeName     = $oldSafeName
            NewSafeName     = $newSafeName
            RenameStatus    = "Unknown"
            RetentionStatus = "Unchanged"
            GroupStatus     = ""
            DefaultMembers  = ""
            OverallStatus   = "FAILED"
            Message         = ""
        }

        # --- 0. CHECK IF OLD SAFE EXISTS ---
        Write-Host " -> Checking Source Safe..." -NoNewline
        try {
            $oldSafe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($oldSafeName))" -ErrorAction SilentlyContinue
            if (-not $oldSafe) {
                $result.RenameStatus = "SourceNotFound"
                $result.Message = "Source safe not found"
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                Log "Source safe not found: $oldSafeName" "ERROR"
                [void]$results.Add([pscustomobject]$result)
                continue
            }
            Write-Host " [FOUND]" -ForegroundColor Green
        }
        catch {
            $result.RenameStatus = "Error"
            $result.Message = "Error checking source safe: $($_.Exception.Message)"
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 1. RENAME SAFE (If names differ) ---
        $skipRenameAPI = $false
        if ($oldSafeName -eq $newSafeName) {
            Write-Host " -> Names are identical. Skipping Rename API call." -ForegroundColor Gray
            Log "OldName == NewName. Skipping Rename API." "INFO"
            $skipRenameAPI = $true
            $result.RenameStatus = "Skipped(SameName)"
        }
        else {
            # Check Target
            Write-Host " -> Checking Target Safe..." -NoNewline
            try {
                $existingSafe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))" -ErrorAction SilentlyContinue
                if ($existingSafe) {
                    $result.RenameStatus = "TargetExists"
                    $result.Message = "Target safe already exists"
                    Write-Host " [EXISTS]" -ForegroundColor Yellow
                    Log "Target safe exists, aborting rename" "WARN"
                    [void]$results.Add([pscustomobject]$result)
                    continue
                }
                Write-Host " [OK]" -ForegroundColor Green
            }
            catch {}
        }

        # Perform Update (Rename + Retention + Desc)
        try {
            $updateBody = @{}
            
            if (-not $skipRenameAPI) { $updateBody["safeName"] = $newSafeName }
            if (-not [string]::IsNullOrWhiteSpace($row.SafeDescription)) { $updateBody["description"] = $row.SafeDescription }
            if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $updateBody["managingCPM"] = $row.ManagingCPM }
            
            # Retention Logic
            if ($row.NumberOfDaysRetention) { 
                $updateBody["numberOfDaysRetention"] = [int]$row.NumberOfDaysRetention 
                $result.RetentionStatus = "Updated(Days)"
            }
            if ($row.NumberOfVersionsRetention) { 
                $updateBody["numberOfVersionsRetention"] = [int]$row.NumberOfVersionsRetention 
                $result.RetentionStatus = "Updated(Versions)"
            }

            if ($updateBody.Keys.Count -gt 0) {
                Write-Host " -> Updating Safe Props..." -NoNewline
                Log "PUT Body: $($updateBody | ConvertTo-Json -Compress)" "DEBUG"
                Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($oldSafeName))" -Body $updateBody | Out-Null
                
                if (-not $skipRenameAPI) { 
                    $result.RenameStatus = "Success"
                    Write-Host " [RENAMED]" -ForegroundColor Green
                }
                else {
                    Write-Host " [UPDATED]" -ForegroundColor Green
                }
            }
        }
        catch {
            $result.RenameStatus = "Failed"
            $result.Message = "Safe update failed: $($_.Exception.Message)"
            Write-Host " [FAILED]" -ForegroundColor Red
            Log "Safe update failed: $($_.Exception.Message)" "ERROR"
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # --- 2. SYNC DEFAULT MEMBERS ---
        if ($defaultSafeMembers) {
            Write-Host " -> Syncing Default Members..." -ForegroundColor Cyan
            $syncLog = @()
            foreach ($memberName in $defaultSafeMembers.PSObject.Properties.Name) {
                try {
                    $memberConfig = $defaultSafeMembers.$memberName
                    
                    # Handle both old format (string) and new format (object)
                    if ($memberConfig -is [string]) {
                        $permSetKey = $memberConfig
                    }
                    else {
                        $permSetKey = $memberConfig.PermissionKey
                    }
                    
                    $permSource = $permissionSets.$permSetKey
                    if (-not $permSource) { continue }

                    $permissions = @{}
                    foreach ($p in $validPerms) { $permissions[$p] = $false }
                    foreach ($p in $permSource) {
                        $match = $validPerms | Where-Object { $_ -ieq $p } | Select-Object -First 1
                        if ($match) { $permissions[$match] = $true }
                    }

                    # Add or Update
                    try {
                        Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))/Members" -Body @{ memberName = $memberName; permissions = $permissions } -ErrorAction Stop | Out-Null
                        $syncLog += "$memberName(Added)"
                    }
                    catch {
                        # If exists (409), Update
                        Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))/Members/$([System.Web.HttpUtility]::UrlEncode($memberName))" -Body @{ permissions = $permissions } | Out-Null
                        $syncLog += "$memberName(Synced)"
                    }
                }
                catch {
                    $syncLog += "$memberName(Failed)"
                    Log "Default Member $memberName failed: $($_.Exception.Message)" "WARN"
                }
            }
            $result.DefaultMembers = $syncLog -join "; "
            Write-Host " [DONE]" -ForegroundColor Green
        }

        # --- 3. GROUPS: RENAME or CREATE (Self-Healing) ---
        $groupLog = @()
        $groupPatterns = @(
            @{ Old = "KA_${oldSafeName}_R"; New = "KA_${newSafeName}_R"; Perms = $permsR },
            @{ Old = "KA_${oldSafeName}_RW"; New = "KA_${newSafeName}_RW"; Perms = $permsRW }
        )

        foreach ($gp in $groupPatterns) {
            Write-Host " -> Group [$($gp.New)]..." -NoNewline
            
            # Check if OLD exists
            $foundOld = $false
            $srcGroupId = $null
            
            try {
                $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gp.Old))"
                $srcGroup = $groups.value | Where-Object { $_.groupName -eq $gp.Old } | Select-Object -First 1
                if ($srcGroup) { 
                    $foundOld = $true
                    $srcGroupId = $srcGroup.id
                }
            }
            catch {}

            if ($foundOld) {
                # --- CASE A: OLD EXISTS -> RENAME ---
                try {
                    Invoke-CACAPIRequest -Method PUT -Endpoint "/API/UserGroups/$srcGroupId" -Body @{ groupName = $gp.New } | Out-Null
                    $groupLog += "$($gp.Old)->$($gp.New) (Renamed)"
                    Write-Host " [RENAMED]" -ForegroundColor Green
                }
                catch {
                    Write-Host " [RENAME FAILED]" -ForegroundColor Red
                    $groupLog += "$($gp.Old) (RenameFailed)"
                }
            }
            else {
                # --- CASE B: OLD MISSING -> CREATE NEW ---
                Write-Host " [MISSING OLD]" -ForegroundColor Yellow
                Log "Group $($gp.Old) missing. Attempting to create $($gp.New)" "WARN"
                
                # Check if New already exists (Collision check)
                $targetExists = $false
                try {
                    $tGroups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gp.New))"
                    if ($tGroups.value | Where-Object { $_.groupName -eq $gp.New }) { $targetExists = $true }
                }
                catch {}

                if ($targetExists) {
                    $groupLog += "$($gp.New) (TargetExists-Skipped)"
                    Write-Host " -> Target Exists. Skipping." -ForegroundColor Yellow
                }
                else {
                    # Create Group & Add to Safe
                    try {
                        # 1. Create Group
                        Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups" -Body @{ groupName = $gp.New } | Out-Null
                        
                        # 2. Build Perms
                        $newPerms = @{}
                        foreach ($p in $validPerms) { $newPerms[$p] = $false }
                        foreach ($p in $gp.Perms) { $newPerms[$p] = $true }

                        # 3. Add to Safe
                        Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))/Members" -Body @{ memberName = $gp.New; permissions = $newPerms } | Out-Null
                        
                        $groupLog += "$($gp.New) (Created&Added)"
                        Write-Host " -> Created & Added." -ForegroundColor Green
                    }
                    catch {
                        Write-Host " -> Create Failed." -ForegroundColor Red
                        $groupLog += "$($gp.New) (CreateFailed)"
                        Log "Failed to create/add group $($gp.New): $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
        $result.GroupStatus = $groupLog -join "; "
        $result.OverallStatus = "SUCCESS"
        [void]$results.Add([pscustomobject]$result)
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Log "Safe Rename Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
    Write-Host "Log file: $logFile" -ForegroundColor Gray
}

# =============================================================================
# 3. BATCH SAFE MEMBER MANAGEMENT
# Add/update members on safes from CSV
# =============================================================================
function Invoke-CACBatchSafeMember {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    # Initialize dedicated log file
    $logDir = "$PSScriptRoot/../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "SafeMember_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    function Log {
        param($Msg, $Level = "INFO")
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
        Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
        if ($Level -eq "DEBUG") { Write-Verbose $entry }
    }

    Log "Started Invoke-CACBatchSafeMember()" "DEBUG"
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        $CsvPath = Read-Host "Enter CSV file path (or 'T' to download template)"
        if ($CsvPath -eq 'T' -or $CsvPath -eq 't') {
            New-CACSafeMemberTemplate
            return
        }
    }

    if (-not (Test-Path $CsvPath)) { Write-Host "CSV not found." -ForegroundColor Red; return }
    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeMember_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = [System.Collections.ArrayList]::new()
    $data = Import-Csv $CsvPath

    Write-Host "Processing $($data.Count) rows..." -ForegroundColor Cyan

    foreach ($row in $data) {
        $safeName = $row.SafeName.Trim()
        $memberName = $row.MemberName.Trim()
        $type = $row.MemberType.Trim() # User or Group

        Write-Host "`n[$safeName] + [$memberName] ($type)" -ForegroundColor Cyan
        Log "Processing $safeName + $memberName" "INFO"

        $result = [ordered]@{
            SafeName     = $safeName
            MemberName   = $memberName
            SafeStatus   = "Unknown"
            MemberStatus = "Unknown"
            ActionStatus = "Failed"
            Message      = ""
        }

        # 1. Check Safe
        try {
            $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))" -ErrorAction SilentlyContinue
            if (-not $safe) {
                $result.SafeStatus = "NotFound"
                $result.Message = "Safe does not exist"
                Write-Host " -> Safe Not Found" -ForegroundColor Red
                [void]$results.Add([pscustomobject]$result)
                continue
            }
            $result.SafeStatus = "Exists"
        }
        catch {
            $result.SafeStatus = "Error"
            $result.Message = "Error checking safe"
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # 2. Check/Create Member
        $memberReady = $false
        if ($type -eq "Group") {
            # Check Group
            try {
                $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($memberName))"
                if ($groups.value | Where-Object { $_.groupName -eq $memberName }) {
                    $memberReady = $true
                    $result.MemberStatus = "Exists"
                }
                else {
                    # Create Group
                    Write-Host " -> Creating Group..." -NoNewline
                    $groupBody = @{ groupName = $memberName }
                    $groupDesc = if ($row.PSObject.Properties['GroupDescription']) { $row.GroupDescription.Trim() } else { "" }
                    if (-not [string]::IsNullOrWhiteSpace($groupDesc)) {
                        $groupBody["description"] = $groupDesc
                    }
                    Invoke-CACAPIRequest -Method POST -Endpoint "/API/UserGroups" -Body $groupBody | Out-Null
                    $memberReady = $true
                    $result.MemberStatus = "Created"
                    Write-Host " [CREATED]" -ForegroundColor Green
                }
            }
            catch {
                $result.MemberStatus = "Error"
                $result.Message = "Group check/create failed: $($_.Exception.Message)"
                Write-Host " -> Group Error" -ForegroundColor Red
            }
        }
        else {
            # Check User
            try {
                $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($memberName))"
                if ($users.Users | Where-Object { $_.username -eq $memberName }) {
                    $memberReady = $true
                    $result.MemberStatus = "Exists"
                }
                else {
                    $result.MemberStatus = "NotFound"
                    Write-Host " -> User Not Found" -ForegroundColor Red
                }
            }
            catch {
                $result.MemberStatus = "Error"
            }
        }

        if (-not $memberReady) { 
            [void]$results.Add([pscustomobject]$result)
            continue
        }

        # 3. Add to Safe
        # Build Permissions
        $permSource = if ($row.Permissions) { $row.Permissions -split ";" } else { $permissionSets.$($row.PermissionKey) }
        $validPerms = @("useAccounts", "retrieveAccounts", "listAccounts", "addAccounts", "updateAccountContent", "updateAccountProperties", "initiateCPMAccountManagementOperations", "specifyNextAccountContent", "renameAccounts", "deleteAccounts", "unlockAccounts", "manageSafe", "manageSafeMembers", "backupSafe", "viewAuditLog", "viewSafeMembers", "accessWithoutConfirmation", "createFolders", "deleteFolders", "moveAccountsAndFolders", "requestsAuthorizationLevel1", "requestsAuthorizationLevel2")
        $permissions = @{}
        foreach ($p in $validPerms) { $permissions[$p] = $false }
        foreach ($p in $permSource) {
            $match = $validPerms | Where-Object { $_ -eq $p.Trim() } | Select-Object -First 1
            if ($match) { $permissions[$match] = $true }
        }

        try {
            Write-Host " -> Adding to Safe..." -NoNewline
            Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members" -Body @{ memberName = $memberName; permissions = $permissions } -ErrorAction Stop | Out-Null
            $result.ActionStatus = "Added"
            Write-Host " [ADDED]" -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message -match "409|already exists") {
                Write-Host " -> Updating..." -NoNewline
                try {
                    Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members/$([System.Web.HttpUtility]::UrlEncode($memberName))" -Body @{ permissions = $permissions } | Out-Null
                    $result.ActionStatus = "Updated"
                    Write-Host " [UPDATED]" -ForegroundColor Green
                }
                catch {
                    $result.ActionStatus = "FailedUpdate"
                    $result.Message = $_.Exception.Message
                    Write-Host " [FAILED]" -ForegroundColor Red
                }
            }
            else {
                $result.ActionStatus = "FailedAdd"
                $result.Message = $_.Exception.Message
                Write-Host " [FAILED]" -ForegroundColor Red
            }
        }
        [void]$results.Add([pscustomobject]$result)
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Log "Finished. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
}

# =============================================================================
# 4. TEMPLATE GENERATORS
# Generates CSV templates for batch operations
# =============================================================================

# --- Safe Creation Template ---
function New-CACSafeCreationTemplate {
    [CmdletBinding()]
    param([string]$Path)

    # Prompt for Safe Name
    Write-Host ""
    $safeName = (Read-Host "Enter Safe Name for template (or press Enter for 'Example_Safe')").Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "Example_Safe" }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeCreation_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    # Load config for DefaultSafeMembers
    $config = Get-CACConfig
    $defaultSafeMembers = $config.DefaultSafeMembers

    # Build template rows
    $templateRows = @()

    # Row 1: Main safe entry (no member - just safe properties)
    $templateRows += [pscustomobject][ordered]@{
        SafeName                  = $safeName
        SafeDescription           = "Safe Description"
        ManagingCPM               = "PasswordManager"
        NumberOfDaysRetention     = "7"
        NumberOfVersionsRetention = ""
        SafeMember                = ""
        MemberType                = ""
        GroupDescription          = ""
        GroupMembers              = ""
        PermissionKey             = ""
        Permissions               = ""
    }

    # Add DefaultSafeMembers from config first
    if ($defaultSafeMembers) {
        foreach ($memberName in $defaultSafeMembers.PSObject.Properties.Name) {
            $memberConfig = $defaultSafeMembers.$memberName
            
            # Handle both old format (string) and new format (object)
            if ($memberConfig -is [string]) {
                $permKey = $memberConfig
                $memberType = "Group"  # Default for old format
            }
            else {
                $permKey = $memberConfig.PermissionKey
                $memberType = if ($memberConfig.MemberType) { $memberConfig.MemberType } else { "Group" }
            }
            
            $templateRows += [pscustomobject][ordered]@{
                SafeName                  = $safeName
                SafeDescription           = ""
                ManagingCPM               = ""
                NumberOfDaysRetention     = ""
                NumberOfVersionsRetention = ""
                SafeMember                = $memberName
                MemberType                = $memberType
                GroupDescription          = ""
                GroupMembers              = ""
                PermissionKey             = $permKey
                Permissions               = ""
            }
        }
    }

    # KA_R group (Read-only)
    $templateRows += [pscustomobject][ordered]@{
        SafeName                  = $safeName
        SafeDescription           = ""
        ManagingCPM               = ""
        NumberOfDaysRetention     = ""
        NumberOfVersionsRetention = ""
        SafeMember                = "KA_${safeName}_R"
        MemberType                = "Group"
        GroupDescription          = "Read-only access group for $safeName"
        GroupMembers              = "user1;user2"
        PermissionKey             = "SAFE_READ"
        Permissions               = ""
    }

    # KA_RW group (Read-Write)
    $templateRows += [pscustomobject][ordered]@{
        SafeName                  = $safeName
        SafeDescription           = ""
        ManagingCPM               = ""
        NumberOfDaysRetention     = ""
        NumberOfVersionsRetention = ""
        SafeMember                = "KA_${safeName}_RW"
        MemberType                = "Group"
        GroupDescription          = "Read-write access group for $safeName"
        GroupMembers              = "admin1;admin2"
        PermissionKey             = "SAFE_READ_WRITE"
        Permissions               = ""
    }

    $templateRows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "Template includes:" -ForegroundColor Cyan
    Write-Host "  - KA_${safeName}_R (Read group)" -ForegroundColor Gray
    Write-Host "  - KA_${safeName}_RW (Read-Write group)" -ForegroundColor Gray
    if ($defaultSafeMembers) {
        foreach ($m in $defaultSafeMembers.PSObject.Properties.Name) {
            Write-Host "  - $m (from DefaultSafeMembers)" -ForegroundColor Gray
        }
    }
    return $Path
}

# --- Safe Rename Template ---
function New-CACSafeRenameTemplate {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeRename_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $template = [ordered]@{
        OldSafeName               = "Old_Safe_Name"
        SafeName                  = "New_Safe_Name"
        SafeDescription           = "Updated Description"
        ManagingCPM               = "PasswordManager"
        NumberOfDaysRetention     = "7"
        NumberOfVersionsRetention = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host "Note: Standard groups (KA_..._R/RW) will be renamed if present, or Created if missing." -ForegroundColor Yellow
    return $Path
}

# --- Safe Member Template ---
function New-CACSafeMemberTemplate {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeMember_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $template = [ordered]@{
        SafeName         = "Existing_Safe_Name"
        MemberName       = "Domain\GroupOrUser"
        MemberType       = "Group"
        GroupDescription = "Group description (only used if MemberType=Group and group is created)"
        PermissionKey    = "SAFE_READ"
        Permissions      = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    return $Path
}

# =============================================================================
# 5. BATCH SAFE DELETE
# Deletes empty safes (skips safes with accounts)
# =============================================================================
function Invoke-CACBatchSafeDelete {
    [CmdletBinding()]
    param()

    # Setup Logging
    $logDir = "$PSScriptRoot/../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "SafeDeletion_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    function Log { param($Msg) Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" }

    Write-Host "Log file: $logFile" -ForegroundColor Gray

    # Input Selection
    Write-Host "`nSelect Input Method:" -ForegroundColor Cyan
    Write-Host "1. Manual Entry (Comma-separated)"
    Write-Host "2. CSV File (Header: SafeName)"
    Write-Host "T. Download Template CSV"
    $inputChoice = Read-Host "Enter option"

    if ($inputChoice -eq 'T' -or $inputChoice -eq 't') {
        New-CACSafeDeleteTemplate
        return
    }

    $targetSafes = @()

    if ($inputChoice -eq '1') {
        $manualInput = Read-Host "Enter Safe Names (e.g. Safe1,Safe2)"
        if (-not [string]::IsNullOrWhiteSpace($manualInput)) {
            $targetSafes = $manualInput -split "," | ForEach-Object { $_.Trim() }
        }
    }
    elseif ($inputChoice -eq '2') {
        $path = Read-Host "Enter CSV File Path"
        if (Test-Path $path) {
            $csv = Import-Csv $path
            foreach ($row in $csv) { if ($row.SafeName) { $targetSafes += $row.SafeName.Trim() } }
        }
        else {
            Write-Host "File not found." -ForegroundColor Red
            return
        }
    }
    else {
        Write-Host "Invalid selection." -ForegroundColor Red
        return
    }

    if ($targetSafes.Count -eq 0) { Write-Host "No safes provided." -ForegroundColor Yellow; return }

    $results = [System.Collections.ArrayList]::new()
    $outPath = Join-Path (Get-CACOutputDir) "SafeDelete_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    foreach ($safe in $targetSafes) {
        if (-not $safe) { continue }
        
        Write-Host "Processing Safe: [$safe]..." -NoNewline
        Log "Processing $safe"

        $res = [ordered]@{ SafeName = $safe; Status = "Failed"; Message = "" }

        try {
            # 1. Check Account Count
            $encodedFilter = [System.Web.HttpUtility]::UrlEncode("safename eq $safe")
            $accts = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Accounts?filter=$encodedFilter&limit=1"
            $count = if ($accts.count) { $accts.count } elseif ($accts.value) { ($accts.value | Measure-Object).Count } else { 0 }

            if ($count -gt 0) {
                $res.Status = "Skipped"
                $res.Message = "Safe contains $count accounts"
                Write-Host " [SKIPPED - $count Accounts]" -ForegroundColor Yellow
                Log "Skipped $safe - contains $count accounts"
            }
            else {
                # 2. Delete Safe
                Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safe))" | Out-Null
                $res.Status = "Deleted"
                Write-Host " [DELETED]" -ForegroundColor Green
                Log "Deleted $safe"
            }
        }
        catch {
            $err = $_.Exception.Message
            if ($err -match "404") {
                $res.Status = "NotFound"
                $res.Message = "Safe not found"
                Write-Host " [NOT FOUND]" -ForegroundColor DarkGray
            }
            else {
                $res.Message = $err
                Write-Host " [ERROR]" -ForegroundColor Red
                Log "Error: $err"
            }
        }
        [void]$results.Add([pscustomobject]$res)
    }

    $results | Export-Csv -Path $outPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nDone. Results: $outPath" -ForegroundColor Green
}

# --- Safe Delete Template ---
function New-CACSafeDeleteTemplate {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeDelete_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $template = [ordered]@{
        SafeName = "Safe_To_Delete"
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host "Note: Only empty safes (0 accounts) will be deleted." -ForegroundColor Yellow
    return $Path
}

# =============================================================================
# EXPORT
# =============================================================================
Export-ModuleMember -Function `
    Invoke-CACBatchSafeCreation, `
    Invoke-CACBatchSafeRename, `
    Invoke-CACBatchSafeMember, `
    Invoke-CACBatchSafeDelete, `
    New-CACSafeCreationTemplate, `
    New-CACSafeRenameTemplate, `
    New-CACSafeMemberTemplate, `
    New-CACSafeDeleteTemplate