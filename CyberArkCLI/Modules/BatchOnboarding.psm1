
# =============================================================================
# BatchOnboarding.psm1
# Description: Onboards Safes, Groups, Users, and Permissions via psPaS
# =============================================================================

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PWD "BatchOnboarding_Result.csv")
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
                $safeParams = @{ SafeName = $safeName; Description = $row.SafeDescription; ErrorAction = 'Stop' }
                if (-not [string]::IsNullOrWhiteSpace($row.ManagingCPM)) { $safeParams.ManagingCPM = $row.ManagingCPM }
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
        # 2. MEMBER CHECK / CREATE
        # -----------------------------
        if ($memberType -eq "Group") {
            $groupId = $null 
            $existingGroup = $null
            try { $existingGroup = Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue } catch { $existingGroup = $null }

            if ($existingGroup) {
                $result.GroupStatus = "Exists"
                $groupId = $existingGroup.id
                Write-Host " -> Group '$safeMember' exists." -ForegroundColor Green
            } 
            else {
                try {
                    Write-Host " -> Creating Group '$safeMember'..." -ForegroundColor DarkGray
                    $newGroup = New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop
                    $groupId = $newGroup.id
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

            if (-not [string]::IsNullOrWhiteSpace($row.Users)) {
                $userList = $row.Users -split ";"
                foreach ($u in $userList) {
                    $inputName = $u.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($inputName)) {
                        try {
                            Add-PASGroupMember -GroupId $groupId -MemberId $inputName -ErrorAction Stop
                        }
                        catch {}
                    }
                }
            }
        }
        elseif ($memberType -eq "User") {
            try {
                $u = Get-PASUser -UserName $safeMember -ErrorAction Stop
                $safeMember = $u.UserName 
                Write-Host " -> User Verified." -ForegroundColor Green
            }
            catch {
                $result.Message = "User '$safeMember' not found in Vault"
                $result.OverallStatus = "FAILED"
                $results += [pscustomobject]$result
                Write-Host " -> User Not Found." -ForegroundColor Red
                continue 
            }
        }

        # -----------------------------
        # 3. PERMISSIONS MAPPING (UPDATED)
        # -----------------------------
        Write-Host " -> Mapping Permissions..." -NoNewline
        
        # Determine permission source (CSV override OR JSON Config key)
        $rawPerms = if ($row.Permissions) { 
            $row.Permissions -split ";" | ForEach-Object { $_.Trim() } 
        }
        else { 
            $permissionSets.$($row.PermissionKey) 
        }

        # We allow standard permissions AND the two Authorization Level switches
        $validPASPermissions = @(
            "UseAccounts", "RetrieveAccounts", "ListAccounts", "AddAccounts", 
            "UpdateAccountContent", "UpdateAccountProperties", "InitiateCPMAccountManagementOperations", 
            "SpecifyNextAccountContent", "RenameAccounts", "DeleteAccounts", "UnlockAccounts", 
            "ManageSafe", "ManageSafeMembers", "BackupSafe", "ViewAuditLog", "ViewSafeMembers", 
            "AccessWithoutConfirmation", "CreateFolders", "DeleteFolders", "MoveAccountsAndFolders",
            "RequestsAuthorizationLevel1", "RequestsAuthorizationLevel2"
        )

        $permParams = @{}
        foreach ($p in $rawPerms) {
            # Direct match (covers standard perms AND AuthLevels)
            if ($validPASPermissions -contains $p) { 
                $permParams[$p] = $true 
            }
            # Handle Aliases (Legacy support)
            elseif ($p -eq "UpdateAccounts") { 
                $permParams["UpdateAccountProperties"] = $true
                $permParams["UpdateAccountContent"] = $true 
            }
            elseif ($p -eq "ViewAudit") { $permParams["ViewAuditLog"] = $true }
            elseif ($p -eq "MoveAccounts") { $permParams["MoveAccountsAndFolders"] = $true }
        }
        Write-Host " [DONE]" -ForegroundColor Green

        # -----------------------------
        # 4. ATTACH TO SAFE
        # -----------------------------
        Write-Host " -> Attaching to Safe..." -NoNewline
        try {
            # Splatting automatically handles -RequestsAuthorizationLevel1:$true if present in $permParams
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
        [string]$Path = (Join-Path $PWD "Onboarding_Template.csv")
    )
    $headers = [ordered]@{
        SafeName                  = "Example_Safe"
        SafeDescription           = "Description"
        ManagingCPM               = "PasswordManager"
        NumberOfVersionsRetention = "5"
        NumberOfDaysRetention     = "7"
        SafeMember                = "Domain\Group"
        MemberType                = "Group" 
        MemberDescription         = "Group Desc"
        Users                     = "user1;user2" 
        PermissionKey             = "SAFE_READ" # Matches config JSON key
        Permissions               = "" # Optional override
    }
    @([pscustomobject]$headers) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template created at: $Path" -ForegroundColor Green
    return $Path
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding, New-CACOnboardingTemplate
