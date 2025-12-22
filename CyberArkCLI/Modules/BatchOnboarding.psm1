# =============================================================================
# BatchOnboarding.psm1
# Required CSV Columns:
#   SafeName, SafeDescription, ManagingCPM, NumberOfVersionsRetention, NumberOfDaysRetention, 
#   SafeMember, MemberType (User|Group), MemberDescription, Users (semicolon separated), 
#   PermissionKey (e.g. SAFE_READ), Permissions (optional override)
# =============================================================================

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PSScriptRoot "BatchOnboarding_Result.csv")
    )

    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV not found: $CsvPath"
        return
    }

    # Ensure Config is loaded
    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) {
        Write-Error "Get-CACConfig function is missing. Please ensure your Config module is loaded."
        return
    }
    
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = @()
    $data = Import-Csv $CsvPath

    foreach ($row in $data) {
        Write-Host "`n--- Processing Safe [$($row.SafeName)] / Member [$($row.SafeMember)] ---" -ForegroundColor Cyan

        $result = [ordered]@{
            SafeName             = $row.SafeName
            SafeStatus           = "Unknown"
            SafeMember           = $row.SafeMember
            MemberType           = $row.MemberType
            GroupStatus          = "NotApplicable"
            SafeMembershipStatus = "NotAttempted"
            OverallStatus        = "FAILED"
            Message              = ""
        }

        # -----------------------------
        # 1. SAFE CHECK / CREATE
        # -----------------------------
        $safeReady = $false
        try {
            Get-PASSafe -SafeName $row.SafeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $result.SafeStatus = "Exists"
            Write-Log "Safe exists: $($row.SafeName)" "INFO"
        }
        catch {
            # Retention Logic
            $versions = if ($row.NumberOfVersionsRetention) { [int]$row.NumberOfVersionsRetention } else { $null }
            $days = if ($row.NumberOfDaysRetention) { [int]$row.NumberOfDaysRetention } else { $null }

            if (-not $versions -and -not $days) {
                $result.SafeStatus = "Failed"
                $result.Message = "Retention policy missing"
                $results += [pscustomobject]$result
                Write-Log "Safe '$($row.SafeName)' missing retention policy" "ERROR"
                continue
            }

            $safeParams = @{
                SafeName    = $row.SafeName
                Description = $row.SafeDescription
                ManagingCPM = $row.ManagingCPM
                ErrorAction = 'Stop'
            }
            if ($versions) { $safeParams.NumberOfVersionsRetention = $versions }
            if ($days) { $safeParams.NumberOfDaysRetention = $days }

            try {
                Add-PASSafe @safeParams
                $safeReady = $true
                $result.SafeStatus = "Created"
                Write-Log "Safe created: $($row.SafeName)" "SUCCESS"
            }
            catch {
                $result.SafeStatus = "Failed"
                $result.Message = $_.Exception.Message
                $results += [pscustomobject]$result
                Write-Log "Safe creation failed: $($_.Exception.Message)" "ERROR"
                continue
            }
        }

        if (-not $safeReady) { $results += [pscustomobject]$result; continue }

        # -----------------------------
        # 2. MEMBER HANDLING (Explicit vs Inferred)
        # -----------------------------
        $memberIsGroup = $false
        
        # LOGIC: Check explicit type first, otherwise infer
        if ($row.MemberType -eq "Group") {
            $memberIsGroup = $true
        }
        elseif ($row.MemberType -eq "User") {
            $memberIsGroup = $false
        }
        else {
            # Fallback Inference (Legacy Logic)
            if ($row.Users -or (Get-PASGroup -GroupName $row.SafeMember -ErrorAction SilentlyContinue)) {
                $memberIsGroup = $true
                $result.MemberType = "Group (Inferred)"
            }
            else {
                $memberIsGroup = $false
                $result.MemberType = "User (Inferred)"
            }
        }

        # ---- GROUP LOGIC ----
        if ($memberIsGroup) {
            $groupExists = $false
            try {
                Get-PASGroup -GroupName $row.SafeMember -ErrorAction Stop | Out-Null
                $groupExists = $true
                $result.GroupStatus = "Exists"
            }
            catch { $groupExists = $false }

            if (-not $groupExists) {
                try {
                    New-PASGroup -GroupName $row.SafeMember -Description $row.MemberDescription -ErrorAction Stop
                    $result.GroupStatus = "Created"
                    Write-Log "Group created: $($row.SafeMember)" "SUCCESS"
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed: " + $_.Exception.Message
                    $results += [pscustomobject]$result
                    continue
                }
            }

            # Add users to group (only if column has data)
            if ($row.Users) {
                foreach ($u in ($row.Users -split ";")) {
                    if (-not [string]::IsNullOrWhiteSpace($u)) {
                        try {
                            Add-PASGroupMember -GroupName $row.SafeMember -MemberName $u.Trim() -ErrorAction Stop
                        }
                        catch { 
                            Write-Log "Warning: Failed to add $u to group ($($_.Exception.Message))" "WARN" 
                        }
                    }
                }
            }
        }
        # ---- USER LOGIC ----
        else {
            # Just verify user exists before adding to safe
            try {
                Get-PASUser -UserName $row.SafeMember -ErrorAction Stop | Out-Null
            }
            catch {
                $result.Message = "User '$($row.SafeMember)' not found in Vault/Directory"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Log "User not found: $($row.SafeMember)" "ERROR"
                continue
            }
        }

        # -----------------------------
        # 3. PERMISSIONS MAPPING
        # -----------------------------
        $rawPerms = if ($row.Permissions) { $row.Permissions -split ";" | ForEach-Object { $_.Trim() } } else { $permissionSets.$($row.PermissionKey) }

        $validPASPermissions = @("UseAccounts", "RetrieveAccounts", "ListAccounts", "AddAccounts", "UpdateAccountContent", "UpdateAccountProperties", "InitiateCPMAccountManagementOperations", "SpecifyNextAccountContent", "RenameAccounts", "DeleteAccounts", "UnlockAccounts", "ManageSafe", "ManageSafeMembers", "BackupSafe", "ViewAuditLog", "ViewSafeMembers", "AccessWithoutConfirmation", "CreateFolders", "DeleteFolders", "MoveAccountsAndFolders")

        $permParams = @{}
        foreach ($p in $rawPerms) {
            if ($validPASPermissions -contains $p) { $permParams[$p] = $true }
            elseif ($p -eq "UpdateAccounts") { $permParams["UpdateAccountProperties"] = $true; $permParams["UpdateAccountContent"] = $true }
            elseif ($p -eq "ViewAudit") { $permParams["ViewAuditLog"] = $true }
            elseif ($p -eq "MoveAccounts") { $permParams["MoveAccountsAndFolders"] = $true }
        }

        # -----------------------------
        # 4. ADD MEMBER TO SAFE
        # -----------------------------
        try {
            Add-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -ErrorAction Stop
            $result.SafeMembershipStatus = "Added"
            $result.OverallStatus = "SUCCESS"
            Write-Log "Member added to safe: $($row.SafeMember)" "SUCCESS"
        }
        catch {
            if ($_.Exception.Message -match "409|already exists") {
                try {
                    Set-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -ErrorAction Stop
                    $result.SafeMembershipStatus = "Updated"
                    $result.OverallStatus = "SUCCESS"
                    Write-Log "Permissions updated for: $($row.SafeMember)" "INFO"
                }
                catch {
                    $result.SafeMembershipStatus = "UpdateFailed"
                    $result.Message = "Update failed: " + $_.Exception.Message
                    Write-Log "Update failed: $($_.Exception.Message)" "ERROR"
                }
            }
            else {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = $_.Exception.Message
                Write-Log "Add failed: $($_.Exception.Message)" "ERROR"
            }
        }
        $results += [pscustomobject]$result
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "Done. Results at: $OutputCsvPath" -ForegroundColor Green
}
Export-ModuleMember -Function Invoke-CACBatchOnboarding