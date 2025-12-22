# =============================================================================
# BatchOnboarding.psm1
# Description: Onboards Safes, Groups, Users, and Permissions via psPaS
# =============================================================================

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PSScriptRoot "BatchOnboarding_Result.csv")
    )

    if (-not (Test-Path $CsvPath)) { Write-Error "CSV not found: $CsvPath"; return }
    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) { Write-Error "Config missing. Please load your module."; return }
    
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets
    $results = @()
    $data = Import-Csv $CsvPath

    foreach ($row in $data) {
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
        try {
            Get-PASSafe -SafeName $safeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $result.SafeStatus = "Exists"
        }
        catch {
            try {
                $safeParams = @{ SafeName = $safeName; Description = $row.SafeDescription; ManagingCPM = $row.ManagingCPM; ErrorAction = 'Stop' }
                if ($row.NumberOfDaysRetention) { $safeParams.NumberOfDaysRetention = [int]$row.NumberOfDaysRetention }
                if ($row.NumberOfVersionsRetention) { $safeParams.NumberOfVersionsRetention = [int]$row.NumberOfVersionsRetention }
                Add-PASSafe @safeParams
                $safeReady = $true
                $result.SafeStatus = "Created"
                Write-Host " -> Safe Created." -ForegroundColor Green
            }
            catch {
                $result.SafeStatus = "Failed"
                Write-Host " -> Safe Creation Failed: $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }

        if (-not $safeReady) { $results += [pscustomobject]$result; continue }

        # -----------------------------
        # 2. MEMBER TYPE LOGIC
        # -----------------------------
        
        # --- CASE A: GROUP MEMBER ---
        if ($memberType -eq "Group") {
            
            $groupId = $null 
            $existingGroup = $null
            
            # Check if Group Exists
            try { $existingGroup = Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue } catch { $existingGroup = $null }

            if ($existingGroup) {
                $result.GroupStatus = "Exists"
                $groupId = $existingGroup.id
                Write-Host " -> Group '$safeMember' exists." -ForegroundColor Green
            } 
            else {
                # Create Group
                try {
                    Write-Host " -> Creating Group '$safeMember'..." -ForegroundColor DarkGray
                    $newGroup = New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop
                    $groupId = $newGroup.id
                    
                    # Latency Wait
                    Start-Sleep -Seconds 2
                    $result.GroupStatus = "Created"
                    Write-Host " -> Group Created." -ForegroundColor Green
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed"
                    Write-Host " -> [CRITICAL] Group Create Failed: $($_.Exception.Message)" -ForegroundColor Red
                    continue 
                }
            }

            # Add Users to Group
            if (-not [string]::IsNullOrWhiteSpace($row.Users)) {
                $userList = $row.Users -split ";"
                Write-Host " -> Processing Group Members..." -ForegroundColor Cyan
                
                foreach ($u in $userList) {
                    $inputName = $u.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($inputName)) {
                        
                        # Resolve User Name
                        $vaultUser = $null
                        try { $vaultUser = Get-PASUser -UserName $inputName -ErrorAction Stop } catch { try { $res = Get-PASUser -Search $inputName; if ($res.Count -eq 1) { $vaultUser = $res[0] } } catch {} }

                        if ($null -eq $vaultUser) {
                            Write-Host "    ! User '$inputName' not found in Vault." -ForegroundColor Red
                            continue
                        }
                        $officialName = $vaultUser.UserName
                        
                        # Add User to Group
                        try {
                            # Using -GroupId and -MemberId (passing Name) as confirmed
                            Add-PASGroupMember -GroupId $groupId -MemberId $officialName -ErrorAction Stop
                            Write-Host "    [SUCCESS] Added $officialName to group." -ForegroundColor Green
                        } 
                        catch {
                            if ($_.Exception.Message -match "409|already exists|already a member") {
                                Write-Host "    [SKIPPED] User already in group." -ForegroundColor Yellow
                            }
                            else {
                                Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red
                            }
                        }
                    }
                }
            }
        }
        # --- CASE B: USER MEMBER ---
        elseif ($memberType -eq "User") {
            Write-Host " -> Verifying User '$safeMember'..." -NoNewline
            try {
                # Check existence
                $u = Get-PASUser -UserName $safeMember -ErrorAction Stop
                
                # Use official name
                $safeMember = $u.UserName 
                Write-Host " [FOUND] ($safeMember)" -ForegroundColor Green
            }
            catch {
                $result.Message = "User '$safeMember' not found in Vault"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Host " [NOT FOUND]" -ForegroundColor Red
                continue 
            }
        }
        else {
            Write-Host " -> [WARN] Invalid MemberType '$memberType'. Skipping." -ForegroundColor Yellow
            continue
        }

        # -----------------------------
        # 3. PERMISSIONS MAPPING
        # -----------------------------
        Write-Host " -> Mapping Permissions..." -NoNewline
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

        # -----------------------------
        # 4. ATTACH TO SAFE
        # -----------------------------
        Write-Host " -> Attaching to Safe..." -NoNewline
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
                Write-Host " [SKIPPED (Exists)]" -ForegroundColor Yellow
            } 
            else {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = $_.Exception.Message
                Write-Host " [ERROR] $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        $results += [pscustomobject]$result
    }
    
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "Done." -ForegroundColor Green
}

function New-CACOnboardingTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = (Join-Path $PWD "Onboarding_Template.csv")
    )

    $headers = [ordered]@{
        SafeName                  = "Example_Safe"
        SafeDescription           = "Description of the safe"
        ManagingCPM               = "PasswordManager"
        NumberOfVersionsRetention = "5"
        NumberOfDaysRetention     = "7"
        SafeMember                = "Domain\GroupOrUser"
        MemberType                = "Group" 
        MemberDescription         = "Description of the group (if creating)"
        Users                     = "user1;user2" 
        PermissionKey             = "Full"
        Permissions               = ""
    }

    $data = @([pscustomobject]$headers)
    $data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8

    Write-Host "Template created at: $Path" -ForegroundColor Green
    return $Path
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding, New-CACOnboardingTemplate