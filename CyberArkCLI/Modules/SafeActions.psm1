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

    # --- LOGGED-IN USER REMOVAL PROMPT ---
    $loggedInUser = $global:CACApiSession.User
    $removeLoggedInUser = $false
    $removedFromSafes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not [string]::IsNullOrWhiteSpace($loggedInUser)) {
        Write-Host ""
        Write-Host "Logged-in user: $loggedInUser" -ForegroundColor Yellow
        $removePrompt = Read-Host "Remove '$loggedInUser' from newly-created safes after member setup? (Y/N)"
        $removeLoggedInUser = ($removePrompt -match '^[Yy]$')
        if ($removeLoggedInUser) {
            Write-Host "  -> '$loggedInUser' will be removed from each newly-created safe." -ForegroundColor Cyan
        }
        else {
            Write-Host "  -> '$loggedInUser' will remain as a safe member." -ForegroundColor Gray
        }
        Write-Host ""
    }
    else {
        Write-Host "  [WARN] Could not determine logged-in user from session; removal skipped." -ForegroundColor Yellow
    }

    Log "Processing $($data.Count) rows from CSV" "INFO"
    Write-Host "Processing $($data.Count) rows..." -ForegroundColor Cyan
    $rowIndex = 0
    $rowTotal = $data.Count

    foreach ($row in $data) {
        $safeName = $row.SafeName.Trim()
        $safeMember = if ($row.PSObject.Properties['SafeMember']) { $row.SafeMember.Trim() } else { "" }
        $memberType = if ($row.PSObject.Properties['MemberType']) { $row.MemberType.Trim() } else { "Group" }
        $memberSourceRaw = if ($row.PSObject.Properties['MemberSource']) { $row.MemberSource.Trim() } else { "Vault" }
        
        # Resolve 'Domain' keyword to actual domain from config
        $memberSource = if ($memberSourceRaw -ieq "Domain") {
            if ($config.LDAPDomain) { $config.LDAPDomain } else { "Vault" }
        }
        else {
            $memberSourceRaw
        }
        
        $groupMembers = if ($row.PSObject.Properties['GroupMembers']) { $row.GroupMembers.Trim() } else { "" }
        $groupDescription = if ($row.PSObject.Properties['GroupDescription']) { $row.GroupDescription.Trim() } else { "" }

        $rowIndex++
        Write-Progress -Activity "Safe Creation" -Status "[$rowIndex/$rowTotal] $safeName" -PercentComplete (($rowIndex / $rowTotal) * 100)

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " [$rowIndex/$rowTotal] Safe: $safeName" -ForegroundColor Cyan
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
            # --- GROUP: Always check/create via CyberArk Vault API ---
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
            if ($memberSource -eq "Vault") {
                # --- VAULT USER: Validate via CyberArk API ---
                Write-Host " -> Checking Vault User [$safeMember]..." -NoNewline
                Log "Checking Vault user: $safeMember" "DEBUG"
                try {
                    $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($safeMember))"
                    $user = $users.Users | Where-Object { $_.username -eq $safeMember } | Select-Object -First 1
                    
                    if ($user) {
                        $memberReady = $true
                        $result.MemberStatus = "Exists"
                        Write-Host " [EXISTS]" -ForegroundColor Green
                        Log "Vault User exists: $safeMember" "INFO"
                    }
                    else {
                        $result.MemberStatus = "NotFound"
                        Write-Host " [NOT FOUND]" -ForegroundColor Red
                        Log "Vault User not found: $safeMember" "WARN"
                    }
                }
                catch {
                    $result.MemberStatus = "Failed"
                    $result.Message += " User lookup error: $($_.Exception.Message)"
                    Write-Host " [FAILED]" -ForegroundColor Red
                    Log "Vault User lookup failed: $($_.Exception.Message)" "ERROR"
                }
            }
            else {
                # --- DOMAIN USER: Skip pre-validation ---
                # CyberArk's Add Safe Member API with searchIn=domain handles LDAP lookup
                # internally. Even if the user never logged in, CyberArk will find them
                # in LDAP, register them, and add to the safe — or return an error if not found.
                Write-Host " -> Domain User [$safeMember] in [$memberSource] — skipping pre-check, CyberArk will resolve via LDAP." -ForegroundColor Gray
                Log "Domain user ${safeMember}: skipping pre-check, relying on CyberArk LDAP resolution (searchIn=$memberSource)" "INFO"
                $memberReady = $true
                $result.MemberStatus = "Pending(Domain)"
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
            # Add searchIn for domain users (Vault is default)
            if (-not [string]::IsNullOrWhiteSpace($memberSource) -and $memberSource -ne "Vault") {
                $safeMemberBody["searchIn"] = $memberSource
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

        # --- REMOVE LOGGED-IN USER FROM NEWLY-CREATED SAFE (once per safe) ---
        if ($removeLoggedInUser -and $result.SafeStatus -eq "Created" -and
            -not [string]::IsNullOrWhiteSpace($loggedInUser) -and
            -not $removedFromSafes.Contains($safeName)) {

            Write-Host " -> Removing '$loggedInUser' from safe '$safeName'..." -NoNewline
            $removed = Remove-CACSafeMember -SafeName $safeName -MemberName $loggedInUser
            if ($removed) {
                Write-Host " [REMOVED]" -ForegroundColor Green
                Log "Removed logged-in user '$loggedInUser' from safe '$safeName'" "SUCCESS"
            }
            else {
                Write-Host " [SKIP/FAILED]" -ForegroundColor Yellow
                Log "Could not remove '$loggedInUser' from '$safeName' (may not be a member or API error)" "WARN"
            }
            [void]$removedFromSafes.Add($safeName)
        }

        [void]$results.Add([pscustomobject]$result)
    }
    Write-Progress -Activity "Safe Creation" -Completed

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
    $rowIndex = 0
    $rowTotal = $data.Count

    foreach ($row in $data) {
        $oldSafeName = $row.OldSafeName.Trim()
        $newSafeName = $row.SafeName.Trim()

        $rowIndex++
        Write-Progress -Activity "Safe Rename" -Status "[$rowIndex/$rowTotal] $oldSafeName -> $newSafeName" -PercentComplete (($rowIndex / $rowTotal) * 100)

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " [$rowIndex/$rowTotal] Rename: $oldSafeName -> $newSafeName" -ForegroundColor Cyan
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

                    # Resolve MemberSource from config (supports "Domain" keyword)
                    $memberSourceRaw = if ($memberConfig -is [string]) { "Vault" } 
                    elseif ($memberConfig.MemberSource) { $memberConfig.MemberSource } 
                    else { "Vault" }
                    $memberSource = if ($memberSourceRaw -ieq "Domain") {
                        if ($config.LDAPDomain) { $config.LDAPDomain } else { "Vault" }
                    }
                    else { $memberSourceRaw }

                    # Add or Update
                    try {
                        $safeMemberBody = @{ memberName = $memberName; permissions = $permissions }
                        if (-not [string]::IsNullOrWhiteSpace($memberSource) -and $memberSource -ne "Vault") {
                            $safeMemberBody["searchIn"] = $memberSource
                        }
                        Log "Adding default member $memberName (Source: $memberSource)" "DEBUG"
                        Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($newSafeName))/Members" -Body $safeMemberBody -ErrorAction Stop | Out-Null
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
    Write-Progress -Activity "Safe Rename" -Completed

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
    $rowIndex = 0
    $rowTotal = $data.Count

    foreach ($row in $data) {
        $rowIndex++
        $safeName = $row.SafeName.Trim()
        $memberName = $row.MemberName.Trim()
        $type = $row.MemberType.Trim() # User or Group
        $memberSourceRaw = if ($row.PSObject.Properties['MemberSource']) { $row.MemberSource.Trim() } else { "Vault" }
        
        # Resolve 'Domain' keyword to actual domain from config
        $memberSource = if ($memberSourceRaw -ieq "Domain") {
            if ($config.LDAPDomain) { $config.LDAPDomain } else { "Vault" }
        }
        else {
            $memberSourceRaw
        }

        Write-Progress -Activity "Safe Member Management" -Status "[$rowIndex/$rowTotal] $safeName + $memberName" -PercentComplete (($rowIndex / $rowTotal) * 100)
        Write-Host "`n[$rowIndex/$rowTotal] $safeName + $memberName ($type) [Source: $memberSource]" -ForegroundColor Cyan
        Log "Processing $safeName + $memberName (Source: $memberSource)" "INFO"

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
            $safeMemberBody = @{ memberName = $memberName; permissions = $permissions }
            if (-not [string]::IsNullOrWhiteSpace($memberSource) -and $memberSource -ne "Vault") {
                $safeMemberBody["searchIn"] = $memberSource
            }
            Log "POST Body: $($safeMemberBody | ConvertTo-Json -Compress -Depth 3)" "DEBUG"
            Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members" -Body $safeMemberBody -ErrorAction Stop | Out-Null
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
    Write-Progress -Activity "Safe Member Management" -Completed

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

    # --- Step 1: Prompt for Safe Type ---
    Write-Host ""
    Write-Host "Safe Type:" -ForegroundColor Cyan
    Write-Host "  [A] Account Safe  - KA_R/KA_RW groups will be added" -ForegroundColor Gray
    Write-Host "  [P] Personal Safe - User added directly (no KA groups)" -ForegroundColor Gray
    $safeType = (Read-Host "Select type (A/P)").Trim().ToUpper()
    if ($safeType -ne "P") { $safeType = "A" }  # Default to Account

    # --- Step 2: Get safe names based on type ---
    $safeNames = @()
    $personalUsers = @{}  # Map: safeName -> userId

    if ($safeType -eq "P") {
        # Personal Safe: Accept user IDs, generate safe names from config pattern
        $config = Get-CACConfig
        $pattern = $config.PersonalSafePattern
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            Write-Host "PersonalSafePattern not configured in config.json (e.g., 'WI-A-SVC-{userid}')" -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "Safe name pattern: $pattern" -ForegroundColor Gray
        $userIdInput = (Read-Host "Enter User ID(s) - comma-separated").Trim()
        if ([string]::IsNullOrWhiteSpace($userIdInput)) {
            Write-Host "At least one User ID is required." -ForegroundColor Red
            return
        }

        $userIds = $userIdInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($uid in $userIds) {
            $safeName = $pattern -replace "\{userid\}", $uid
            $safeNames += $safeName
            $personalUsers[$safeName] = $uid
        }

        Write-Host ""
        Write-Host "Generated safe names:" -ForegroundColor Cyan
        foreach ($sn in $safeNames) {
            Write-Host "  $sn -> $($personalUsers[$sn])" -ForegroundColor Gray
        }
    }
    else {
        # Account Safe: Accept safe names directly
        Write-Host ""
        $safeNameInput = (Read-Host "Enter Safe Name(s) - comma-separated (or press Enter for 'Example_Safe')").Trim()
        if ([string]::IsNullOrWhiteSpace($safeNameInput)) { $safeNameInput = "Example_Safe" }
        $safeNames = $safeNameInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeCreation_Template_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    # Load config for DefaultSafeMembers
    if (-not $config) { $config = Get-CACConfig }
    $defaultSafeMembers = $config.DefaultSafeMembers

    # Build template rows for each safe
    $templateRows = @()

    foreach ($safeName in $safeNames) {
        $isFirstRowForSafe = $true

        # Add DefaultSafeMembers from config
        if ($defaultSafeMembers) {
            foreach ($memberName in $defaultSafeMembers.PSObject.Properties.Name) {
                $memberConfig = $defaultSafeMembers.$memberName
                
                # Handle both old format (string) and new format (object)
                if ($memberConfig -is [string]) {
                    $permKey = $memberConfig
                    $memberType = "Group"
                }
                else {
                    $permKey = $memberConfig.PermissionKey
                    $memberType = if ($memberConfig.MemberType) { $memberConfig.MemberType } else { "Group" }
                }
                
                $templateRows += [pscustomobject][ordered]@{
                    SafeName                  = $safeName
                    SafeDescription           = if ($isFirstRowForSafe) { "Safe Description" } else { "" }
                    ManagingCPM               = if ($isFirstRowForSafe) { "PasswordManager" } else { "" }
                    NumberOfDaysRetention     = ""
                    NumberOfVersionsRetention = if ($isFirstRowForSafe) { "30" } else { "" }
                    SafeMember                = $memberName
                    MemberType                = $memberType
                    MemberSource              = "Vault"
                    GroupDescription          = ""
                    GroupMembers              = ""
                    PermissionKey             = $permKey
                    Permissions               = ""
                }
                $isFirstRowForSafe = $false
            }
        }

        if ($safeType -eq "P") {
            # ---- PERSONAL SAFE: Add user directly (Domain source, no KA groups) ----
            $templateRows += [pscustomobject][ordered]@{
                SafeName                  = $safeName
                SafeDescription           = if ($isFirstRowForSafe) { "pam container" } else { "" }
                ManagingCPM               = if ($isFirstRowForSafe) { "PasswordManager" } else { "" }
                NumberOfDaysRetention     = ""
                NumberOfVersionsRetention = if ($isFirstRowForSafe) { "30" } else { "" }
                SafeMember                = $personalUsers[$safeName]
                MemberType                = "User"
                MemberSource              = "Domain"
                GroupDescription          = ""
                GroupMembers              = ""
                PermissionKey             = "USER_ACCESS"
                Permissions               = ""
            }
        }
        else {
            # ---- ACCOUNT SAFE: Add KA_R and KA_RW groups ----
            # KA_R group (Read-only)
            $templateRows += [pscustomobject][ordered]@{
                SafeName                  = $safeName
                SafeDescription           = if ($isFirstRowForSafe) { "Safe Description" } else { "" }
                ManagingCPM               = if ($isFirstRowForSafe) { "PasswordManager" } else { "" }
                NumberOfDaysRetention     = ""
                NumberOfVersionsRetention = if ($isFirstRowForSafe) { "30" } else { "" }
                SafeMember                = "KA_${safeName}_R"
                MemberType                = "Group"
                MemberSource              = "Vault"
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
                MemberSource              = "Vault"
                GroupDescription          = "Read-write access group for $safeName"
                GroupMembers              = "admin1;admin2"
                PermissionKey             = "SAFE_READ_WRITE"
                Permissions               = ""
            }
        }
    }

    $templateRows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "Template Summary:" -ForegroundColor Cyan
    Write-Host "  Type : $(if ($safeType -eq 'P') { 'Personal Safe' } else { 'Account Safe' })" -ForegroundColor White
    Write-Host "  Safes: $($safeNames -join ', ')" -ForegroundColor White
    Write-Host ""
    foreach ($sn in $safeNames) {
        Write-Host "  [$sn]" -ForegroundColor Yellow
        if ($defaultSafeMembers) {
            foreach ($m in $defaultSafeMembers.PSObject.Properties.Name) {
                Write-Host "    - $m (DefaultSafeMembers)" -ForegroundColor Gray
            }
        }
        if ($safeType -eq "P") {
            Write-Host "    - $($personalUsers[$sn]) (Personal Owner - Domain)" -ForegroundColor Gray
        }
        else {
            Write-Host "    - KA_${sn}_R (Read group)" -ForegroundColor Gray
            Write-Host "    - KA_${sn}_RW (Read-Write group)" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "MemberSource options:" -ForegroundColor Cyan
    Write-Host "  Vault   = Vault internal user/group (default)" -ForegroundColor Gray
    Write-Host "  Domain  = LDAP domain user/group (resolved from config.LDAPDomain)" -ForegroundColor Gray
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
        MemberSource     = "Vault"
        GroupDescription = "Group description (only used if MemberType=Group and group is created)"
        PermissionKey    = "SAFE_READ"
        Permissions      = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "MemberSource options:" -ForegroundColor Cyan
    Write-Host "  Vault   = Vault internal user/group (default)" -ForegroundColor Gray
    Write-Host "  Domain  = LDAP domain user/group (resolved from config.LDAPDomain)" -ForegroundColor Gray
    return $Path
}

# =============================================================================
# 4. BATCH SAFE DELETION
# Deletes safes and associated groups from CSV
# =============================================================================
function Invoke-CACBatchSafeDelete {
    [CmdletBinding()]
    param(
        [string]$CsvPath,
        [string]$OutputCsvPath
    )

    # Initialize dedicated log file
    $logDir = "$PSScriptRoot/../Logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "SafeDeletion_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    function Log {
        param($Msg, $Level = "INFO")
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
        Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
        if ($Level -eq "DEBUG") { Write-Verbose $entry }
    }

    Log "Started Invoke-CACBatchSafeDelete()" "DEBUG"
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    # Prompt for CSV path if missing
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host ""
        Write-Host "Select Input Method:" -ForegroundColor Cyan
        Write-Host "1. Manual Entry (Comma-separated)"
        Write-Host "2. CSV File (Header: SafeName, SafeDescription)"
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
            $CsvPath = Get-CACFilePath -Title "Select Safe Deletion CSV" -Filter "CSV Files (*.csv)|*.csv"
            
            if (-not [string]::IsNullOrWhiteSpace($CsvPath) -and (Test-Path $CsvPath)) {
                $csv = Import-Csv $CsvPath
                foreach ($row in $csv) {
                    if ($row.SafeName) { $targetSafes += $row.SafeName.Trim() }
                }
            }
            else {
                Write-Host "No file selected." -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Red
            return
        }
    }
    else {
        # Processing passed CSV Path argument
        if (Test-Path $CsvPath) {
            $csv = Import-Csv $CsvPath
            $targetSafes = @()
            foreach ($row in $csv) {
                if ($row.SafeName) { $targetSafes += $row.SafeName.Trim() }
            }
        }
        else {
            Write-Host "File not found: $CsvPath" -ForegroundColor Red
            return
        }
    }

    if ($targetSafes.Count -eq 0) {
        Write-Host "No safes found to process." -ForegroundColor Yellow
        return
    }

    # --- SUMMARY CONFIRMATION ---
    Write-Host ""
    Write-Host "===== DELETION SUMMARY =====" -ForegroundColor Red
    Write-Host "Total Safes to Delete: $($targetSafes.Count)"
    if ($targetSafes.Count -lt 11) {
        $targetSafes | ForEach-Object { Write-Host " - $_" -ForegroundColor DarkGray }
    }
    else {
        $targetSafes | Select-Object -First 5 | ForEach-Object { Write-Host " - $_" -ForegroundColor DarkGray }
        Write-Host " ... and $(($targetSafes.Count - 5)) more." -ForegroundColor DarkGray
    }
    Write-Host "============================" -ForegroundColor Red
    
    $confirm = Read-Host "Are you sure you want to PERMANENTLY DELETE these safes? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
    }

    # Output path
    if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
        $OutputCsvPath = Join-Path (Get-CACOutputDir) "SafeDeletion_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    }

    $results = [System.Collections.ArrayList]::new()
    $i = 0
    $total = $targetSafes.Count

    foreach ($safeName in $targetSafes) {
        $i++
        Write-Progress -Activity "Safe Deletion" -Status "[$i/$total] $safeName" -PercentComplete (($i / $total) * 100)

        Write-Host "[$i/$total] Deleting Safe: $safeName ..." -NoNewline

        $rowResult = [ordered]@{
            SafeName = $safeName
            Status   = "Unknown"
            Groups   = ""
            Message  = ""
        }

        # 1. Check Safe Existence
        $safeExists = $false
        try {
            $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))" -ErrorAction SilentlyContinue
            if ($safe) { $safeExists = $true }
        }
        catch { }

        if (-not $safeExists) {
            $rowResult.Status = "NotFound"
            $rowResult.Message = "Safe does not exist"
            Write-Host " [NOT FOUND]" -ForegroundColor Yellow
            [void]$results.Add([pscustomobject]$rowResult)
            continue
        }

        # 2. Delete Safe
        try {
            Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))"
            $rowResult.Status = "Deleted"
            Write-Host " [DELETED]" -ForegroundColor Green
            Log "Deleted Safe: $safeName" "SUCCESS"
        }
        catch {
            $rowResult.Status = "Failed"
            $rowResult.Message = "Safe delete error: $($_.Exception.Message)"
            Write-Host " [FAILED]" -ForegroundColor Red
            Log "Failed to delete Safe $safeName : $($_.Exception.Message)" "ERROR"
        }

        # 3. Delete Groups (KA_..._R / RW)
        # Groups are deleted regardless of safe deletion success, to ensure cleanup
        $groupsToDelete = @("KA_${safeName}_R", "KA_${safeName}_RW")
        $groupLog = @()

        foreach ($gName in $groupsToDelete) {
            # Find Group
            $groupId = $null
            try {
                $gRes = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($gName))"
                $grp = $gRes.value | Where-Object { $_.groupName -eq $gName } | Select-Object -First 1
                if ($grp) { $groupId = $grp.id }
            }
            catch {}

            if ($groupId) {
                try {
                    Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/UserGroups/$groupId"
                    $groupLog += "$gName(Deleted)"
                    Log "Deleted Group: $gName" "SUCCESS"
                }
                catch {
                    $groupLog += "$gName(Failed)"
                    Log "Failed to delete Group $gName" "WARN"
                }
            }
            else {
                $groupLog += "$gName(NotFound)"
            }
        }
        $rowResult.Groups = $groupLog -join "; "
        [void]$results.Add([pscustomobject]$rowResult)
    }
    Write-Progress -Activity "Safe Deletion" -Completed

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
    Log "Operation Complete" "INFO"
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
# REMOVE SAFE MEMBER
# Removes a specific member (user or group) from a safe
# =============================================================================
function Remove-CACSafeMember {
    <#
    .SYNOPSIS
        Remove a member from a CyberArk safe.
    .DESCRIPTION
        Calls DELETE /API/Safes/{safeName}/Members/{memberName}.
        Returns $true on success, $false if the member was not found or the call failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$MemberName
    )

    Write-Log "Remove-CACSafeMember: Safe='$SafeName', Member='$MemberName'" "DEBUG"

    try {
        $encodedSafe = [System.Web.HttpUtility]::UrlEncode($SafeName)
        $encodedMember = [System.Web.HttpUtility]::UrlEncode($MemberName)
        Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/Safes/$encodedSafe/Members/$encodedMember" | Out-Null
        Write-Log "Successfully removed '$MemberName' from safe '$SafeName'" "SUCCESS"
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        # 404 means the member wasn't there - treat as success (idempotent)
        if ($errMsg -match "404|not found") {
            Write-Log "'$MemberName' was not a member of '$SafeName' (404 - skipped)" "INFO"
            return $true
        }
        Write-Log "Failed to remove '$MemberName' from '$SafeName': $errMsg" "ERROR"
        return $false
    }
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
    New-CACSafeDeleteTemplate, `
    Remove-CACSafeMember