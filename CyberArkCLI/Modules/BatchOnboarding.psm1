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
        # TRIM INPUTS
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
            Write-Host "    -> Creating safe..." -ForegroundColor DarkGray

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
        if ($memberType -eq "Group") { $memberIsGroup = $true }
        elseif ($memberType -eq "User") { $memberIsGroup = $false }
        else {
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
        # 3. GROUP LOGIC (Create & Populate)
        # -----------------------------
        if ($memberIsGroup) {
            Write-Host " -> Step 2: Verifying Group '$safeMember'..." -NoNewline
            
            # Strict Exists Check
            $existingGroup = $null
            try { $existingGroup = Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue } catch { $existingGroup = $null }

            if ($existingGroup) {
                Write-Host " [EXISTS]" -ForegroundColor Green
                $result.GroupStatus = "Exists"
            } 
            else {
                Write-Host " [MISSING]" -ForegroundColor Yellow
                Write-Host "    -> Creating Group '$safeMember'..." -ForegroundColor DarkGray
                try {
                    New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop | Out-Null
                    Write-Host "    -> Waiting 3s for Vault indexing..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 3 # Critical Latency Pause
                    
                    if (Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue) {
                        $result.GroupStatus = "Created"
                        Write-Host "    [SUCCESS] Group created." -ForegroundColor Green
                    }
                    else {
                        throw "Group created but lookup failed (Latency)."
                    }
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed: " + $_.Exception.Message
                    $results += [pscustomobject]$result
                    Write-Host "    [CRITICAL] Failed to create group: $($_.Exception.Message)" -ForegroundColor Red
                    continue 
                }
            }

            # --- KEY FIX: RESOLVE USER BEFORE ADDING ---
            if (-not [string]::IsNullOrWhiteSpace($row.Users)) {
                $userList = $row.Users -split ";"
                Write-Host "    -> Processing $($userList.Count) user(s) for group membership..." -ForegroundColor Cyan
                
                foreach ($u in $userList) {
                    $inputName = $u.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($inputName)) {
                        Write-Host "       User [$inputName]: " -NoNewline -ForegroundColor DarkGray
                        
                        # A. Resolve User Identity
                        $vaultUser = $null
                        try {
                            $vaultUser = Get-PASUser -UserName $inputName -ErrorAction Stop
                        }
                        catch {
                            # If direct lookup fails, try searching (handles some domain mismatches)
                            try { 
                                $searchResults = Get-PASUser -Search $inputName -ErrorAction Stop
                                if ($searchResults.Count -eq 1) { $vaultUser = $searchResults[0] }
                            }
                            catch {}
                        }

                        if ($null -eq $vaultUser) {
                            Write-Host "NOT FOUND" -ForegroundColor Red
                            Write-Host "         ! Error: User '$inputName' does not exist in the Vault." -ForegroundColor Yellow
                            continue
                        }

                        # B. Add using the Official Vault Name
                        $officialName = $vaultUser.UserName
                        Write-Host "RESOLVED as [$officialName] -> " -NoNewline -ForegroundColor DarkGray
                        
                        try {
                            Add-PASGroupMember -GroupName $safeMember -MemberName $officialName -ErrorAction Stop
                            Write-Host "ADDED" -ForegroundColor Green
                        } 
                        catch {
                            if ($_.Exception.Message -match "409|already exists|already a member") {
                                Write-Host "SKIPPED (Already in group)" -ForegroundColor Yellow
                            }
                            else {
                                Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Red
                            }
                        }
                    }
                }
            }
        }
        # -----------------------------
        # 4. USER LOGIC (Verify Existence)
        # -----------------------------
        else {
            Write-Host " -> Step 2: Verifying User '$safeMember'..." -NoNewline
            try {
                Get-PASUser -UserName $safeMember -ErrorAction Stop | Out-Null
                Write-Host " [FOUND]" -ForegroundColor Green
            }
            catch {
                $result.Message = "User '$safeMember' not found"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                continue
            }
        }

        # -----------------------------
        # 5. PERMISSIONS & SAFE ATTACHMENT
        # -----------------------------
        Write-Host " -> Step 3: Mapping Permissions..." -NoNewline
        $rawPerms = if ($row.Permissions) { $row.Permissions -split ";" | ForEach-Object { $_.Trim() } } else { $permissionSets.$($row.PermissionKey) }

        $validPASPermissions = @("UseAccounts", "RetrieveAccounts", "ListAccounts", "AddAccounts", "UpdateAccountContent", "UpdateAccountProperties", "InitiateCPMAccountManagementOperations", "SpecifyNextAccountContent", "RenameAccounts", "DeleteAccounts", "UnlockAccounts", "ManageSafe", "ManageSafeMembers", "BackupSafe", "ViewAuditLog", "ViewSafeMembers", "AccessWithoutConfirmation", "CreateFolders", "DeleteFolders", "MoveAccountsAndFolders")

        $permParams = @{}
        foreach ($p in $rawPerms) {
            if ($validPASPermissions -contains $p) { $permParams[$p] = $true }
            elseif ($p -eq "UpdateAccounts") { $permParams["UpdateAccountProperties"] = $true; $permParams["UpdateAccountContent"] = $true }
            elseif ($p -eq "ViewAudit") { $permParams["ViewAuditLog"] = $true }
            elseif ($p -eq "MoveAccounts") { $permParams["MoveAccountsAndFolders"] = $true }
        }
        Write-Host " [DONE]" -ForegroundColor Green

        Write-Host " -> Step 4: Attaching Member to Safe..." -NoNewline
        try {
            Add-PASSafeMember -SafeName $safeName -MemberName $safeMember @permParams -ErrorAction Stop
            $result.SafeMembershipStatus = "Added"
            $result.OverallStatus = "SUCCESS"
            Write-Host " [SUCCESS]" -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message -match "404|Not Found") {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = "Vault returned 404 (Member/Safe not found)."
                Write-Host " [FAILED 404]" -ForegroundColor Red
            }
            elseif ($_.Exception.Message -match "409|already exists") {
                $result.SafeMembershipStatus = "Skipped"
                $result.OverallStatus = "SUCCESS"
                $result.Message = "Member already exists in Safe"
                Write-Host " [SKIPPED (Member exists)]" -ForegroundColor Yellow
            } 
            else {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = $_.Exception.Message
                Write-Host " [ERROR] $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        if ($result.OverallStatus -ne "SUCCESS" -and $result.SafeMembershipStatus -ne "Failed") { $result.OverallStatus = "PARTIAL" }

        $results += [pscustomobject]$result
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
    Write-Host "Result CSV generated at: $OutputCsvPath" -ForegroundColor Green
}
Export-ModuleMember -Function Invoke-CACBatchOnboarding