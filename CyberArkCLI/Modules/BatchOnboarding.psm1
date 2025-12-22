# =============================================================================
# BatchOnboarding.psm1
# Description: Onboards Safes, Groups, and Permissions via psPaS
# 
# REQUIRED CSV COLUMNS:
# SafeName, SafeDescription, ManagingCPM, NumberOfVersionsRetention, NumberOfDaysRetention,
# SafeMember, MemberType, MemberDescription, Users, PermissionKey, Permissions
# =============================================================================

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PSScriptRoot "BatchOnboarding_Result.csv")
    )

    # 1. Validate Input
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV not found: $CsvPath"
        return
    }

    # 2. Check Dependencies
    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) {
        Write-Error "Get-CACConfig function is missing. Please ensure your Config module is loaded."
        return
    }
    
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    $results = @()
    $data = Import-Csv $CsvPath

    foreach ($row in $data) {
        # TRIM WHITESPACE (Critical for avoiding mismatches)
        $safeName = $row.SafeName.Trim()
        $safeMember = $row.SafeMember.Trim()
        $memberType = $row.MemberType.Trim()

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host " PROCESSING: Safe [$safeName] | Member [$safeMember] ($memberType)" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

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
        Write-Host " -> Step 1: Verifying Safe..." -NoNewline

        try {
            Get-PASSafe -SafeName $safeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $result.SafeStatus = "Exists"
            Write-Host " [EXISTS]" -ForegroundColor Green
        }
        catch {
            Write-Host " [MISSING]" -ForegroundColor Yellow
            Write-Host "    -> Attempting to create safe..." -ForegroundColor DarkGray

            # Retention Logic
            $versions = if ($row.NumberOfVersionsRetention) { [int]$row.NumberOfVersionsRetention } else { $null }
            $days = if ($row.NumberOfDaysRetention) { [int]$row.NumberOfDaysRetention } else { $null }

            if (-not $versions -and -not $days) {
                $result.SafeStatus = "Failed"
                $result.Message = "Retention policy missing"
                $results += [pscustomobject]$result
                Write-Host "    [ERROR] Safe missing retention policy columns." -ForegroundColor Red
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
                Write-Host "    [SUCCESS] Safe created." -ForegroundColor Green
            }
            catch {
                $result.SafeStatus = "Failed"
                $result.Message = $_.Exception.Message
                $results += [pscustomobject]$result
                Write-Host "    [ERROR] Safe creation failed: $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }

        if (-not $safeReady) { $results += [pscustomobject]$result; continue }

        # -----------------------------
        # 2. MEMBER TYPE IDENTIFICATION
        # -----------------------------
        $memberIsGroup = $false
        
        if ($memberType -eq "Group") {
            $memberIsGroup = $true
        }
        elseif ($memberType -eq "User") {
            $memberIsGroup = $false
        }
        else {
            # Fallback Inference
            Write-Host " -> [WARN] MemberType column empty. Inferring type..." -ForegroundColor Yellow
            if ($row.Users -or (Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue)) {
                $memberIsGroup = $true
                $result.MemberType = "Group (Inferred)"
            }
            else {
                $memberIsGroup = $false
                $result.MemberType = "User (Inferred)"
            }
        }

        # -----------------------------
        # 3. GROUP LOGIC (Strict Creation)
        # -----------------------------
        if ($memberIsGroup) {
            Write-Host " -> Step 2: Verifying Group '$safeMember'..." -NoNewline
            
            # STRICT CHECK: Don't rely on try/catch. Explicitly check for null.
            $existingGroup = $null
            try {
                $existingGroup = Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue
            }
            catch { $existingGroup = $null }

            if ($existingGroup) {
                Write-Host " [EXISTS]" -ForegroundColor Green
                $result.GroupStatus = "Exists"
            } 
            else {
                # Group does not exist. Create it.
                Write-Host " [MISSING]" -ForegroundColor Yellow
                Write-Host "    -> Creating Group '$safeMember'..." -ForegroundColor DarkGray
                
                try {
                    New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop | Out-Null
                    
                    # LATENCY WAIT: Crucial step
                    Write-Host "    -> Waiting 2s for Vault indexing..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 2
                    
                    # VERIFY CREATION
                    if (Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue) {
                        $result.GroupStatus = "Created"
                        Write-Host "    [SUCCESS] Group created and verified." -ForegroundColor Green
                    }
                    else {
                        throw "Group created but lookup failed (Vault Latency or Permission)."
                    }
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed: " + $_.Exception.Message
                    $results += [pscustomobject]$result
                    
                    Write-Host "    [CRITICAL ERROR] Failed to create group: $($_.Exception.Message)" -ForegroundColor Red
                    continue # STOP HERE for this row. Do not try to add missing group to Safe.
                }
            }

            # Add users to group (Runs for both New and Existing groups)
            if ($row.Users) {
                Write-Host "    -> Processing Group Membership..." -ForegroundColor DarkGray
                foreach ($u in ($row.Users -split ";")) {
                    $uName = $u.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($uName)) {
                        try {
                            Add-PASGroupMember -GroupName $safeMember -MemberName $uName -ErrorAction Stop
                            Write-Host "       + Added user: $uName" -ForegroundColor Gray
                        }
                        catch { 
                            Write-Host "       ! Warning: Could not add '$uName' (User missing or already in group)" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
        # -----------------------------
        # 4. USER LOGIC (Verify Existence Only)
        # -----------------------------
        else {
            Write-Host " -> Step 2: Verifying User '$safeMember'..." -NoNewline
            try {
                Get-PASUser -UserName $safeMember -ErrorAction Stop | Out-Null
                Write-Host " [FOUND]" -ForegroundColor Green
            }
            catch {
                $result.Message = "User '$safeMember' not found in Vault"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                Write-Host "    [ERROR] Cannot onboard a user that does not exist in the Vault." -ForegroundColor Red
                continue
            }
        }

        # -----------------------------
        # 5. PERMISSIONS MAPPING
        # -----------------------------
        Write-Host " -> Step 3: Mapping Permissions..." -NoNewline
        $rawPerms = if ($row.Permissions) { $row.Permissions -split ";" | ForEach-Object { $_.Trim() } } else { $permissionSets.$($row.PermissionKey) }

        # Valid psPaS parameters
        $validPASPermissions = @(
            "UseAccounts", "RetrieveAccounts", "ListAccounts", "AddAccounts",
            "UpdateAccountContent", "UpdateAccountProperties", 
            "InitiateCPMAccountManagementOperations", "SpecifyNextAccountContent", 
            "RenameAccounts", "DeleteAccounts", "UnlockAccounts",
            "ManageSafe", "ManageSafeMembers", "BackupSafe", 
            "ViewAuditLog", "ViewSafeMembers", "AccessWithoutConfirmation", 
            "CreateFolders", "DeleteFolders", "MoveAccountsAndFolders"
        )

        $permParams = @{}
        foreach ($p in $rawPerms) {
            if ($validPASPermissions -contains $p) { $permParams[$p] = $true }
            # Auto-Correction Logic
            elseif ($p -eq "UpdateAccounts") { $permParams["UpdateAccountProperties"] = $true; $permParams["UpdateAccountContent"] = $true }
            elseif ($p -eq "ViewAudit") { $permParams["ViewAuditLog"] = $true }
            elseif ($p -eq "MoveAccounts") { $permParams["MoveAccountsAndFolders"] = $true }
        }
        Write-Host " [DONE]" -ForegroundColor Green

        # -----------------------------
        # 6. ATTACH TO SAFE
        # -----------------------------
        Write-Host " -> Step 4: Attaching Member to Safe..." -NoNewline
        try {
            Add-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
            
            $result.SafeMembershipStatus = "Added"
            $result.OverallStatus = "SUCCESS"
            Write-Host " [SUCCESS]" -ForegroundColor Green
        }
        catch {
            # 404 = Not Found
            if ($_.Exception.Message -match "404|Not Found") {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = "Vault returned 404. Member not found."
                Write-Host " [FAILED 404]" -ForegroundColor Red
                Write-Host "    [ERROR] The Vault says '$safeMember' does not exist." -ForegroundColor Red
            }
            # 409 = Conflict (Already Exists) -> SKIP
            elseif ($_.Exception.Message -match "409|already exists") {
                $result.SafeMembershipStatus = "Skipped"
                $result.OverallStatus = "SUCCESS"
                $result.Message = "Member already exists in Safe"
                Write-Host " [SKIPPED]" -ForegroundColor Yellow
                Write-Host "    (Member is already attached to this Safe)" -ForegroundColor DarkGray
            } 
            else {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = $_.Exception.Message
                Write-Host " [ERROR]" -ForegroundColor Red
                Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        # Check Partial Status
        if ($result.OverallStatus -ne "SUCCESS" -and $result.SafeMembershipStatus -ne "Failed") {
            $result.OverallStatus = "PARTIAL"
        }

        $results += [pscustomobject]$result
    }

    # -----------------------------
    # EXPORT RESULT CSV
    # -----------------------------
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
    Write-Host "Result CSV generated at: $OutputCsvPath" -ForegroundColor Green
}
Export-ModuleMember -Function Invoke-CACBatchOnboarding