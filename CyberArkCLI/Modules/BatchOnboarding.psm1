# =============================================================================
# BatchOnboarding.psm1
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

    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) {
        Write-Error "Get-CACConfig missing. Load your Config module."
        return
    }
    
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = @()
    $data = Import-Csv $CsvPath

    foreach ($row in $data) {
        # ### FIX 1: Trim all inputs immediately to prevent " GroupName " mismatches
        $safeName = $row.SafeName.Trim()
        $safeMember = $row.SafeMember.Trim()
        $memberType = $row.MemberType.Trim()

        Write-Host "`n--- Processing Safe [$safeName] / Member [$safeMember] ---" -ForegroundColor Cyan

        $result = [ordered]@{
            SafeName             = $safeName
            SafeStatus           = "Unknown"
            SafeMember           = $safeMember
            MemberType           = $memberType
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
            Get-PASSafe -SafeName $safeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $result.SafeStatus = "Exists"
            Write-Log "Safe exists: $safeName" "INFO"
        }
        catch {
            # Retention Logic
            $versions = if ($row.NumberOfVersionsRetention) { [int]$row.NumberOfVersionsRetention } else { $null }
            $days = if ($row.NumberOfDaysRetention) { [int]$row.NumberOfDaysRetention } else { $null }

            if (-not $versions -and -not $days) {
                $result.SafeStatus = "Failed"
                $result.Message = "Retention policy missing"
                $results += [pscustomobject]$result
                Write-Log "Safe '$safeName' missing retention policy" "ERROR"
                continue
            }

            $safeParams = @{
                SafeName    = $safeName
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
                Write-Log "Safe created: $safeName" "SUCCESS"
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
        # 2. MEMBER HANDLING
        # -----------------------------
        $memberIsGroup = $false
        
        # Determine Type
        if ($memberType -eq "Group") {
            $memberIsGroup = $true
        }
        elseif ($memberType -eq "User") {
            $memberIsGroup = $false
        }
        else {
            # Inferred Fallback
            if ($row.Users -or (Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue)) {
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
                Get-PASGroup -GroupName $safeMember -ErrorAction Stop | Out-Null
                $groupExists = $true
                $result.GroupStatus = "Exists"
            }
            catch { $groupExists = $false }

            if (-not $groupExists) {
                try {
                    Write-Log "Creating Group: $safeMember ..." "INFO"
                    New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop
                    
                    # ### FIX 2: Add Delay and Verification
                    # The Vault needs a moment to commit the new Group ID before it can be added to a Safe.
                    Start-Sleep -Seconds 2 
                    
                    # Verify it actually exists now
                    try {
                        Get-PASGroup -GroupName $safeMember -ErrorAction Stop | Out-Null
                        $result.GroupStatus = "Created"
                        Write-Log "Group verified: $safeMember" "SUCCESS"
                    }
                    catch {
                        throw "Group created but lookup failed (Latency issue). Retrying Safe Add might fail."
                    }
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed: " + $_.Exception.Message
                    $results += [pscustomobject]$result
                    continue
                }
            }

            # Add users to group
            if ($row.Users) {
                foreach ($u in ($row.Users -split ";")) {
                    if (-not [string]::IsNullOrWhiteSpace($u)) {
                        try {
                            Add-PASGroupMember -GroupName $safeMember -MemberName $u.Trim() -ErrorAction Stop
                        }
                        catch { 
                            Write-Log "Warning: Failed to add user '$u' to group ($($_.Exception.Message))" "WARN" 
                        }
                    }
                }
            }
        }
        # ---- USER LOGIC ----
        else {
            try {
                Get-PASUser -UserName $safeMember -ErrorAction Stop | Out-Null
            }
            catch {
                $result.Message = "User '$safeMember' not found"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Log "User not found: $safeMember" "ERROR"
                continue
            }
        }

        # -----------------------------
        # 3. PERMISSIONS MAPPING
        # -----------------------------
        $rawPerms = if ($row.Permissions) { $row.Permissions -split ";" | ForEach-Object { $_.Trim() } } else { $permissionSets.$($row.PermissionKey) }

        # Valid psPaS parameters
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
            Write-Log "Adding member '$safeMember' to safe '$safeName'..." "INFO"
            
            Add-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
            
            $result.SafeMembershipStatus = "Added"
            $result.OverallStatus = "SUCCESS"
            Write-Log "Member added to safe successfully." "SUCCESS"
        }
        catch {
            # 404 = Not Found (The issue you were seeing)
            if ($_.Exception.Message -match "404|Not Found") {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = "Vault could not find member '$safeMember'. Verify it exists."
                Write-Log "Error: Vault returned 404 for member '$safeMember'. It may not be indexed yet." "ERROR"
            }
            # 409 = Already Exists
            elseif ($_.Exception.Message -match "409|already exists") {
                try {
                    Set-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
                    $result.SafeMembershipStatus = "Updated"
                    $result.OverallStatus = "SUCCESS"
                    Write-Log "Member exists. Permissions updated." "INFO"
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