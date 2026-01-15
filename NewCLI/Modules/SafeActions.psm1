# =============================================================================
# SafeActions.psm1
# Description: Consolidated Safe Operations - Create, Rename, Sync
#              Uses raw CyberArk REST API
# =============================================================================

# =============================================================================
# COMMON HELPER FUNCTIONS
# =============================================================================

function Get-CACPermissionParams {
    param(
        [array]$PermissionSource,
        [hashtable]$PermissionSets
    )

    # All valid API permission names (lowercase as expected by REST API)
    $validPerms = @(
        "useAccounts", "retrieveAccounts", "listAccounts", "addAccounts",
        "updateAccountContent", "updateAccountProperties", 
        "initiateCPMAccountManagementOperations", "specifyNextAccountContent",
        "renameAccounts", "deleteAccounts", "unlockAccounts",
        "manageSafe", "manageSafeMembers", "backupSafe",
        "viewAuditLog", "viewSafeMembers", "accessWithoutConfirmation",
        "createFolders", "deleteFolders", "moveAccountsAndFolders",
        "requestsAuthorizationLevel1", "requestsAuthorizationLevel2"
    )

    # Initialize all permissions to false
    $permissions = @{}
    foreach ($p in $validPerms) {
        $permissions[$p] = $false
    }

    # Set provided permissions to true (direct match, case-insensitive)
    foreach ($p in $PermissionSource) {
        $match = $validPerms | Where-Object { $_ -eq $p } | Select-Object -First 1
        if ($match) {
            $permissions[$match] = $true
        }
    }

    return $permissions
}


function Test-CACSafeExistsInternal {
    param([string]$SafeName)
    try {
        $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))"
        return ($null -ne $safe)
    }
    catch { return $false }
}

function Test-CACGroupExistsInternal {
    param([string]$GroupName)
    try {
        $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))"
        $match = $groups.value | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1
        return ($null -ne $match)
    }
    catch { return $false }
}

function Test-CACUserExistsInternal {
    param([string]$UserName)
    try {
        $users = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Users?search=$([System.Web.HttpUtility]::UrlEncode($UserName))"
        $match = $users.Users | Where-Object { $_.username -eq $UserName } | Select-Object -First 1
        return ($null -ne $match)
    }
    catch { return $false }
}

function Add-CACSafeMemberInternal {
    param(
        [string]$SafeName,
        [string]$MemberName,
        [hashtable]$Permissions
    )

    $body = @{
        memberName  = $MemberName
        permissions = $Permissions
    }

    try {
        Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))/Members" -Body $body
        return @{ Success = $true; Status = "Added" }
    }
    catch {
        if ($_.Exception.Message -match "409|already exists|SFWS014E") {
            try {
                Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))/Members/$([System.Web.HttpUtility]::UrlEncode($MemberName))" -Body @{ permissions = $Permissions }
                return @{ Success = $true; Status = "Updated" }
            }
            catch {
                return @{ Success = $false; Status = "Failed"; Error = $_.Exception.Message }
            }
        }
        return @{ Success = $false; Status = "Failed"; Error = $_.Exception.Message }
    }
}

# =============================================================================
# 1. CREATE SAFES FROM CSV
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
    $results = @()
    $data = Import-Csv $CsvPath

    Write-Log "Processing $($data.Count) rows from CSV" "INFO"

    foreach ($row in $data) {
        $safeName = $row.SafeName.Trim()
        $safeMember = $row.SafeMember.Trim()
        $memberType = $row.MemberType.Trim()

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING: Safe [$safeName] | Member [$safeMember] ($memberType)" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        $result = [ordered]@{
            SafeName         = $safeName
            SafeStatus       = "Unknown"
            SafeMember       = $safeMember
            MemberType       = $memberType
            MembershipStatus = "NotAttempted"
            OverallStatus    = "FAILED"
            Message          = ""
        }

        # --- 1. SAFE CHECK / CREATE ---
        $safeReady = $false
        if (Test-CACSafeExistsInternal $safeName) {
            $safeReady = $true
            $result.SafeStatus = "Exists"
            Write-Host " -> Safe exists." -ForegroundColor Green
        }
        else {
            try {
                $safeBody = @{ safeName = $safeName }
                if (-not [string]::IsNullOrWhiteSpace($row.SafeDescription)) { $safeBody["description"] = $row.SafeDescription }
                if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $safeBody["managingCPM"] = $row.ManagingCPM }
                if ($row.NumberOfDaysRetention) { $safeBody["numberOfDaysRetention"] = [int]$row.NumberOfDaysRetention }

                Write-Host " -> Creating Safe..." -NoNewline
                Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes" -Body $safeBody
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
            $results += [pscustomobject]$result
            continue 
        }

        # --- 2. MEMBER VALIDATION ---
        if ([string]::IsNullOrWhiteSpace($safeMember)) {
            $result.MembershipStatus = "Skipped"
            $result.OverallStatus = "SUCCESS"
            $result.Message = "No member specified"
            $results += [pscustomobject]$result
            continue
        }

        Write-Host " -> Validating member: $safeMember..." -NoNewline
        $memberExists = $false

        if ($memberType -eq "Group") {
            $memberExists = Test-CACGroupExistsInternal $safeMember
        }
        elseif ($memberType -eq "User") {
            $memberExists = Test-CACUserExistsInternal $safeMember
        }

        if (-not $memberExists) {
            $result.MembershipStatus = "Failed"
            $result.Message = "$memberType '$safeMember' not found"
            Write-Host " [NOT FOUND]" -ForegroundColor Red
            $results += [pscustomobject]$result
            continue
        }
        Write-Host " [OK]" -ForegroundColor Green

        # --- 3. PERMISSIONS MAPPING ---
        $permSource = if ($row.Permissions) { 
            $row.Permissions -split ";" | ForEach-Object { $_.Trim() } 
        }
        else { 
            $permissionSets.$($row.PermissionKey) 
        }

        $permissions = Get-CACPermissionParams -PermissionSource $permSource -PermissionSets $permissionSets

        # --- 4. ADD MEMBER TO SAFE ---
        Write-Host " -> Adding to Safe..." -NoNewline
        $addResult = Add-CACSafeMemberInternal -SafeName $safeName -MemberName $safeMember -Permissions $permissions

        if ($addResult.Success) {
            $result.MembershipStatus = $addResult.Status
            $result.OverallStatus = "SUCCESS"
            Write-Host " [$($addResult.Status.ToUpper())]" -ForegroundColor Green
        }
        else {
            $result.MembershipStatus = "Failed"
            $result.Message = $addResult.Error
            Write-Host " [FAILED]" -ForegroundColor Red
        }

        $results += [pscustomobject]$result
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Log "Safe Creation Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
}

# =============================================================================
# 2. RENAME SAFES FROM CSV (Rename & Sync)
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

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $script:results = @()

    # Helper to add result
    function Add-Result {
        param($sName, $sStatus, $mName, $mType, $smStatus, $oStatus, $msg)
        $script:results += [pscustomobject][ordered]@{
            SafeName         = $sName
            SafeStatus       = $sStatus
            SafeMember       = $mName
            MemberType       = $mType
            MembershipStatus = $smStatus
            OverallStatus    = $oStatus
            Message          = $msg
        }
    }

    # Helper to rename group
    function Rename-Group {
        param($OldGroup, $NewGroup, $Context)
        try {
            $groups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($OldGroup))"
            $srcGroup = $groups.value | Where-Object { $_.groupName -eq $OldGroup } | Select-Object -First 1
            
            if (-not $srcGroup) {
                Write-Log "[$Context] Source Group '$OldGroup' not found." "WARN"
                return
            }

            $targetGroups = Invoke-CACAPIRequest -Method GET -Endpoint "/API/UserGroups?search=$([System.Web.HttpUtility]::UrlEncode($NewGroup))"
            $tgtGroup = $targetGroups.value | Where-Object { $_.groupName -eq $NewGroup } | Select-Object -First 1
            
            if ($tgtGroup) {
                Write-Log "[$Context] Target Group '$NewGroup' already exists." "WARN"
                return
            }

            Invoke-CACAPIRequest -Method PUT -Endpoint "/API/UserGroups/$($srcGroup.id)" -Body @{ groupName = $NewGroup }
            Write-Log "[$Context] Group Renamed: $OldGroup -> $NewGroup" "SUCCESS"
            Write-Host "   -> Group Renamed: $OldGroup -> $NewGroup" -ForegroundColor Green
        }
        catch {
            Write-Log "[$Context] Group Rename Failed: $($_.Exception.Message)" "ERROR"
        }
    }

    $data = Import-Csv $CsvPath
    $groupedData = $data | Group-Object SafeName

    Write-Log "Processing $($groupedData.Count) safes from CSV" "INFO"

    foreach ($group in $groupedData) {
        $safeName = $group.Name.Trim()
        $safeRows = $group.Group
        
        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING SAFE: [$safeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        # --- STEP 1: SAFE RENAME / CHECK ---
        $safeReady = $false
        $safeStatus = "Unknown"
        $oldSafeName = if ($safeRows[0].PSObject.Properties['OldSafeName']) { $safeRows[0].OldSafeName } else { $null }
        $renameOccurred = $false

        if (Test-CACSafeExistsInternal $safeName) {
            $safeReady = $true
            $safeStatus = "Exists"
            Write-Host " -> Safe '$safeName' already exists." -ForegroundColor Green
        }
        elseif (-not [string]::IsNullOrWhiteSpace($oldSafeName)) {
            Write-Host " -> Checking Old Safe: '$oldSafeName'..." -NoNewline
            
            if (Test-CACSafeExistsInternal $oldSafeName) {
                try {
                    Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($oldSafeName))" -Body @{ safeName = $safeName }
                    $safeReady = $true
                    $safeStatus = "Renamed"
                    $renameOccurred = $true
                    Write-Host " [RENAMED]" -ForegroundColor Green
                }
                catch {
                    Write-Host " [FAILED]" -ForegroundColor Red
                }
            }
            else {
                Write-Host " [NOT FOUND]" -ForegroundColor Yellow
            }
        }

        if (-not $safeReady) {
            Write-Host " -> Safe not found. Skipping." -ForegroundColor Yellow
            foreach ($r in $safeRows) {
                Add-Result $safeName "Skipped" $r.SafeMember $r.MemberType "N/A" "SKIPPED" "Safe not found"
            }
            continue
        }

        # --- STEP 2: GROUP RENAME (If Safe Rename Occurred) ---
        if ($renameOccurred -and -not [string]::IsNullOrWhiteSpace($oldSafeName)) {
            Write-Host " -> Renaming associated groups..." -ForegroundColor Cyan
            Rename-Group "KA_${oldSafeName}_R" "KA_${safeName}_R" $safeName
            Rename-Group "KA_${oldSafeName}_RW" "KA_${safeName}_RW" $safeName
        }

        # --- STEP 3: SYNC SAFE PROPERTIES ---
        $desc = if ($safeRows[0].PSObject.Properties['SafeDescription']) { $safeRows[0].SafeDescription } else { $null }
        $cpm = if ($safeRows[0].PSObject.Properties['ManagingCPM']) { $safeRows[0].ManagingCPM } else { $null }

        $updateBody = @{}
        if (-not [string]::IsNullOrWhiteSpace($desc)) { $updateBody["description"] = $desc }
        if (-not [string]::IsNullOrWhiteSpace($cpm)) { $updateBody["managingCPM"] = $cpm }

        if ($updateBody.Count -gt 0) {
            try {
                Invoke-CACAPIRequest -Method PUT -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))" -Body $updateBody
                Write-Host " -> Safe properties updated." -ForegroundColor Green
            }
            catch {
                Write-Host " -> Failed to update properties." -ForegroundColor Red
            }
        }

        # --- STEP 4: SYNC PERMISSIONS ---
        foreach ($row in $safeRows) {
            $safeMember = $row.SafeMember.Trim()
            $memberType = $row.MemberType.Trim()
            
            if ([string]::IsNullOrWhiteSpace($safeMember)) { continue }
            
            Write-Host "   Member: $safeMember" -ForegroundColor Gray -NoNewline

            $memberExists = if ($memberType -eq "Group") { Test-CACGroupExistsInternal $safeMember } else { Test-CACUserExistsInternal $safeMember }

            if (-not $memberExists) {
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                Add-Result $safeName $safeStatus $safeMember $memberType "Failed" "FAILED" "$memberType not found"
                continue
            }

            $permSource = if ($row.Permissions) { $row.Permissions -split ";" | ForEach-Object { $_.Trim() } } else { $permissionSets.$($row.PermissionKey) }
            $permissions = Get-CACPermissionParams -PermissionSource $permSource -PermissionSets $permissionSets

            $addResult = Add-CACSafeMemberInternal -SafeName $safeName -MemberName $safeMember -Permissions $permissions

            if ($addResult.Success) {
                Write-Host " [$($addResult.Status.ToUpper())]" -ForegroundColor Green
                Add-Result $safeName $safeStatus $safeMember $memberType $addResult.Status "SUCCESS" "OK"
            }
            else {
                Write-Host " [FAILED]" -ForegroundColor Red
                Add-Result $safeName $safeStatus $safeMember $memberType "Failed" "FAILED" $addResult.Error
            }
        }
    }

    $script:results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Log "Safe Rename Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to: $OutputCsvPath" -ForegroundColor Green
}

# =============================================================================
# 3. CSV TEMPLATE GENERATORS
# =============================================================================
function New-CACSafeCreationTemplate {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeCreation_Template.csv"
    }

    $template = [ordered]@{
        SafeName              = "Example_Safe"
        SafeDescription       = "Safe Description"
        ManagingCPM           = "PasswordManager"
        NumberOfDaysRetention = "7"
        SafeMember            = "Domain\GroupOrUser"
        MemberType            = "Group"
        PermissionKey         = "SAFE_READ"
        Permissions           = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "CSV Columns:" -ForegroundColor Cyan
    Write-Host "  SafeName          - Name of the safe to create"
    Write-Host "  SafeDescription   - Description (optional)"
    Write-Host "  ManagingCPM       - CPM name (optional)"
    Write-Host "  NumberOfDaysRetention - Retention days (optional)"
    Write-Host "  SafeMember        - User or Group to add"
    Write-Host "  MemberType        - 'User' or 'Group'"
    Write-Host "  PermissionKey     - Key from config (e.g., SAFE_READ)"
    Write-Host "  Permissions       - Override permissions (semicolon-separated)"
    
    return $Path
}

function New-CACSafeRenameTemplate {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-CACOutputDir) "SafeRename_Template.csv"
    }

    $template = [ordered]@{
        OldSafeName     = "Old_Safe_Name"
        SafeName        = "New_Safe_Name"
        SafeDescription = "Updated Description"
        ManagingCPM     = "PasswordManager"
        SafeMember      = "Domain\GroupOrUser"
        MemberType      = "Group"
        PermissionKey   = "SAFE_READ"
        Permissions     = ""
    }

    @([pscustomobject]$template) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "CSV Columns:" -ForegroundColor Cyan
    Write-Host "  OldSafeName       - Current safe name to rename FROM"
    Write-Host "  SafeName          - New safe name to rename TO"
    Write-Host "  SafeDescription   - Updated description (optional)"
    Write-Host "  ManagingCPM       - CPM name (optional)"
    Write-Host "  SafeMember        - User or Group for permission sync"
    Write-Host "  MemberType        - 'User' or 'Group'"
    Write-Host "  PermissionKey     - Key from config (e.g., SAFE_READ)"
    Write-Host "  Permissions       - Override permissions (semicolon-separated)"
    
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
