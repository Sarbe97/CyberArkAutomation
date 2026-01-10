# =============================================================================
# BatchOnboarding.psm1
# Description: Onboards Safes, Groups, Permissions via psPaS
#              Supports "Rename & Sync" workflow (STRICT mode).
#              - No Safe Creation (Skip if missing)
#              - No User Sync (Only Permissions)
#              - Deep Logging (Start/End per Safe)
# =============================================================================

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PWD "BatchOnboarding_Result.csv")
    )

    # --- Setup & Validation ---
    if (-not (Test-Path $CsvPath)) { Write-Error "CSV not found: $CsvPath"; return }
    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) { Write-Error "Config missing. Please load your module."; return }
    if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) { function Write-Log ($msg, $level) { Write-Host "[$level] $msg" } }
    
    # Redirect logs to separate file (Locally scoped)
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["Write-Log:LogName"] = "BatchOnboarding"

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    # Use script-scope variable for results to access it inside helper
    $script:results = @()
    
    Write-Log "Starting Batch Onboarding (Strict Rename & Sync) from: $CsvPath" "INFO"

    # -----------------------------
    # HELPER: Rename Group
    # -----------------------------
    function Rename-LocalGroup {
        param($OldGroup, $NewGroup, $SafeContext)
        try {
            # Check existence
            try { $g = Get-PASGroup -GroupName $OldGroup -ErrorAction Stop } 
            catch { 
                Write-Log "[$SafeContext] Source Group '$OldGroup' not found. Skipping rename." "WARN"
                return 
            }

            # Check target conflict
            $target = Get-PASGroup -GroupName $NewGroup -ErrorAction SilentlyContinue
            if ($target) { 
                Write-Log "[$SafeContext] Target Group '$NewGroup' already exists. Skipping rename." "WARN"
                return 
            }

            # Rename
            Set-PASGroup -GroupName $OldGroup -NewGroupName $NewGroup -ErrorAction Stop
            Write-Log "[$SafeContext] Group Renamed: $OldGroup -> $NewGroup" "SUCCESS"
            Write-Host "   -> Group Renamed: $OldGroup -> $NewGroup" -ForegroundColor Green
        }
        catch {
            Write-Log "[$SafeContext] Group Rename Failed ($OldGroup -> $NewGroup): $($_.Exception.Message)" "ERROR"
            Write-Host "   -> Group Rename Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # -----------------------------
    # HELPER: Add Result
    # -----------------------------
    function Add-Result {
        param($sName, $sStatus, $mName, $mType, $gStatus, $smStatus, $oStatus, $msg)
        $res = [ordered]@{
            SafeName             = $sName
            SafeStatus           = $sStatus
            SafeMember           = $mName
            MemberType           = $mType
            GroupStatus          = $gStatus
            SafeMembershipStatus = $smStatus
            OverallStatus        = $oStatus
            Message              = $msg
        }
        # Append to the parent scope array
        $script:results += [pscustomobject]$res
    }

    $data = Import-Csv $CsvPath
    $groupedData = $data | Group-Object SafeName

    # -----------------------------
    # MAIN LOOP (Per Safe)
    # -----------------------------
    foreach ($group in $groupedData) {
        $safeName = $group.Name.Trim()
        $safeRows = $group.Group
        
        # Log Start of Safe Processing
        Write-Log "--------------------------------------------------------" "INFO"
        Write-Log "PROCESSING SAFE: [$safeName]" "INFO"
        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING SAFE: [$safeName]" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        # -----------------------------
        # STEP 1: SAFE RENAME / CHECK
        # -----------------------------
        $safeReady = $false
        $safeStatus = "Unknown"
        # Check if CSV has OldSafeName column
        $oldSafeName = if ($safeRows[0].PSObject.Properties['OldSafeName']) { $safeRows[0].OldSafeName } else { $null }
        $renameOccurred = $false

        # A. Check Existence
        try {
            Get-PASSafe -SafeName $safeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $safeStatus = "Exists"
            Write-Log "[$safeName] Safe already exists." "INFO"
            Write-Host " -> Safe '$safeName' already exists." -ForegroundColor Green
        }
        catch {
            # B. Rename Logic
            if (-not [string]::IsNullOrWhiteSpace($oldSafeName)) {
                Write-Log "[$safeName] Target missing. Attempting rename from '$oldSafeName'." "INFO"
                Write-Host " -> Checking Old Safe: '$oldSafeName'..." -NoNewline
                
                try {
                    # Verify Old Safe Exists
                    Get-PASSafe -SafeName $oldSafeName -ErrorAction Stop | Out-Null
                    
                    # Rename
                    Set-PASSafe -SafeName $oldSafeName -NewSafeName $safeName -ErrorAction Stop
                    
                    $safeReady = $true
                    $safeStatus = "Renamed"
                    $renameOccurred = $true
                    Write-Log "[$safeName] Safe successfully renamed from '$oldSafeName'." "SUCCESS"
                    Write-Host " [RENAMED]" -ForegroundColor Green
                }
                catch {
                    Write-Log "[$safeName] Rename failed: $($_.Exception.Message)" "ERROR"
                    Write-Host " [FAILED]" -ForegroundColor Red
                    Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            else {
                Write-Log "[$safeName] Target missing and no OldSafeName provided." "WARN"
            }
        }

        # C. Skip if Not Ready (STRICT MODE: No Creation)
        if (-not $safeReady) {
            Write-Log "[$safeName] Safe check failed and Creation is disabled. Skipping Safe." "WARN"
            Write-Host " -> Safe not found/renaming failed. Skipping." -ForegroundColor Yellow
            
            foreach ($r in $safeRows) {
                Add-Result $safeName "Skipped" $r.SafeMember $r.MemberType "N/A" "N/A" "SKIPPED" "Safe not found (Strict Mode)"
            }
            continue 
        }

        # -----------------------------
        # STEP 2: GROUP RENAME (If Safe Rename Occurred)
        # -----------------------------
        if ($renameOccurred) {
            Write-Log "[$safeName] Triggering Group Renames..." "INFO"
            Write-Host " -> Rename Groups..." -ForegroundColor Cyan
            
            $oldGroupR = "KA_${oldSafeName}_R"
            $oldGroupRW = "KA_${oldSafeName}_RW"
            $newGroupR = "KA_${safeName}_R"
            $newGroupRW = "KA_${safeName}_RW"

            Rename-LocalGroup $oldGroupR $newGroupR $safeName
            Rename-LocalGroup $oldGroupRW $newGroupRW $safeName
        }

        # -----------------------------
        # STEP 3: SYNC PERMISSIONS (Iterate Rows)
        # -----------------------------
        foreach ($row in $safeRows) {
            $safeMember = $row.SafeMember.Trim()
            $memberType = $row.MemberType.Trim()
            
            if (-not $safeMember) { continue }
            
            Write-Log "[$safeName] Processing Member: $safeMember ($memberType)" "INFO"
            Write-Host "   Member: $safeMember" -ForegroundColor Gray -NoNewline

            # --- A. Validate Member Existence (Read-Only Check) ---
            # We do NOT create groups or users here anymore.
            $memberExists = $false
            
            if ($memberType -eq "Group") {
                try { 
                    Get-PASGroup -GroupName $safeMember -ErrorAction Stop | Out-Null
                    $memberExists = $true
                } 
                catch { 
                    Write-Log "[$safeName] Group '$safeMember' not found." "ERROR"
                    Write-Host " [GROUP MISSING]" -ForegroundColor Red
                    Add-Result $safeName $safeStatus $safeMember $memberType "Missing" "Failed" "FAILED" "Group not found"
                    continue
                }
            }
            elseif ($memberType -eq "User") {
                try { 
                    $u = Get-PASUser -UserName $safeMember -ErrorAction Stop
                    $safeMember = $u.UserName 
                    $memberExists = $true
                } 
                catch { 
                    Write-Log "[$safeName] User '$safeMember' not found." "ERROR"
                    Write-Host " [USER MISSING]" -ForegroundColor Red
                    Add-Result $safeName $safeStatus $safeMember $memberType "Missing" "Failed" "FAILED" "User not found"
                    continue
                }
            }

            # --- B. Attach/Update Permissions ---
            $permSource = if ($row.Permissions) { 
                $row.Permissions -split ";" | ForEach-Object { $_.Trim() } 
            }
            else { 
                $permissionSets.$($row.PermissionKey) 
            }

            # Map Permissions
            $validPASPermissions = @(
                "UseAccounts", "RetrieveAccounts", "ListAccounts", "AddAccounts", 
                "UpdateAccountContent", "UpdateAccountProperties", "InitiateCPMAccountManagementOperations", 
                "SpecifyNextAccountContent", "RenameAccounts", "DeleteAccounts", "UnlockAccounts", 
                "ManageSafe", "ManageSafeMembers", "BackupSafe", "ViewAuditLog", "ViewSafeMembers", 
                "AccessWithoutConfirmation", "CreateFolders", "DeleteFolders", "MoveAccountsAndFolders",
                "RequestsAuthorizationLevel1", "RequestsAuthorizationLevel2"
            )
            $permParams = @{}
            foreach ($p in $permSource) {
                if ($validPASPermissions -contains $p) { $permParams[$p] = $true }
                elseif ($p -eq "UpdateAccounts") { $permParams["UpdateAccountProperties"] = $true; $permParams["UpdateAccountContent"] = $true }
                elseif ($p -eq "ViewAudit") { $permParams["ViewAuditLog"] = $true }
                elseif ($p -eq "MoveAccounts") { $permParams["MoveAccountsAndFolders"] = $true }
            }

            try {
                Add-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
                
                Write-Log "[$safeName] Successfully added/updated member permissions." "SUCCESS"
                Write-Host " [OK]" -ForegroundColor Green
                Add-Result $safeName $safeStatus $safeMember $memberType "Exists" "Success" "SUCCESS" "Permissions updated"
            }
            catch {
                if ($_.Exception.Message -match "404|Not Found") {
                    # Should be caught above, but safety net
                    Write-Log "[$safeName] Add-Member 404 Error." "ERROR"
                    Write-Host " [404 ERROR]" -ForegroundColor Red
                    Add-Result $safeName $safeStatus $safeMember $memberType "Exists" "Failed" "FAILED" "Vault 404"
                }
                elseif ($_.Exception.Message -match "409|already exists") {
                    # Retry with Update-PASSafeMember for permission refresh
                    try {
                        Write-Log "[$safeName] Member exists. Attempting Update-PASSafeMember..." "INFO"
                        Update-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
                        Write-Log "[$safeName] Permissions updated via Update-PASSafeMember." "SUCCESS"
                        Write-Host " [UPDATED]" -ForegroundColor Green
                        Add-Result $safeName $safeStatus $safeMember $memberType "Exists" "Updated" "SUCCESS" "Permissions updated"
                    }
                    catch {
                        Write-Log "[$safeName] Update failed: $($_.Exception.Message)" "ERROR"
                        Write-Host " [UPDATE FAILED]" -ForegroundColor Red
                        Add-Result $safeName $safeStatus $safeMember $memberType "Exists" "Failed" "FAILED" "Could not update permissions"
                    }
                }
                else {
                    Write-Log "[$safeName] Add-Member Error: $($_.Exception.Message)" "ERROR"
                    Write-Host " [ERROR]" -ForegroundColor Red
                    Add-Result $safeName $safeStatus $safeMember $memberType "Exists" "Failed" "FAILED" $_.Exception.Message
                }
            }
        }
    }
    
    $script:results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Log "Batch Onboarding Complete. Results: $OutputCsvPath" "INFO"
    Write-Host "`nDone. Results saved to $OutputCsvPath" -ForegroundColor Green
}

function New-CACOnboardingTemplate {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PWD "Onboarding_Template.csv")
    )
    $headers = [ordered]@{
        OldSafeName               = "Old_Safe_Optional_Name" 
        SafeName                  = "Example_Safe"
        SafeDescription           = "Description"
        ManagingCPM               = "PasswordManager"
        NumberOfVersionsRetention = "5"
        NumberOfDaysRetention     = "7"
        SafeMember                = "Domain\Group"
        MemberType                = "Group" 
        MemberDescription         = "Group Desc"
        # Users Column Removed Per Requirement
        PermissionKey             = "SAFE_READ"
        Permissions               = ""
    }
    @([pscustomobject]$headers) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created at: $Path" -ForegroundColor Green
    return $Path
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding, New-CACOnboardingTemplate
