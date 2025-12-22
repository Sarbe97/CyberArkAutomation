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

    if (-not (Test-Path $CsvPath)) { Write-Error "CSV not found: $CsvPath"; return }
    if (-not (Get-Command Get-CACConfig -ErrorAction SilentlyContinue)) { Write-Error "Config missing."; return }
    
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
        # 1. SAFE CHECK
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
        # 2. MEMBER TYPE & GROUP LOGIC
        # -----------------------------
        $memberIsGroup = ($memberType -eq "Group") -or ($row.Users -ne $null)

        if ($memberIsGroup) {
            # --- Check Group Exists ---
            $groupId = $null # We need the ID for the fallback method
            $existingGroup = $null
            
            try { $existingGroup = Get-PASGroup -GroupName $safeMember -ErrorAction SilentlyContinue } catch { $existingGroup = $null }

            if ($existingGroup) {
                $result.GroupStatus = "Exists"
                $groupId = $existingGroup.id # Capture ID for API calls
            } 
            else {
                # --- Create Group ---
                try {
                    Write-Host " -> Creating Group '$safeMember'..." -ForegroundColor DarkGray
                    $newGroup = New-PASGroup -GroupName $safeMember -Description $row.MemberDescription -ErrorAction Stop
                    $groupId = $newGroup.id
                    
                    Start-Sleep -Seconds 2
                    $result.GroupStatus = "Created"
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = "Group creation failed"
                    Write-Host " -> [CRITICAL] Group Create Failed: $($_.Exception.Message)" -ForegroundColor Red
                    continue 
                }
            }

            # --- ADD USERS TO GROUP (DEBUGGING ADDED) ---
            if (-not [string]::IsNullOrWhiteSpace($row.Users)) {
                $userList = $row.Users -split ";"
                Write-Host " -> Processing Members..." -ForegroundColor Cyan
                
                foreach ($u in $userList) {
                    $inputName = $u.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($inputName)) {
                        
                        # A. Resolve User
                        $vaultUser = $null
                        try { $vaultUser = Get-PASUser -UserName $inputName -ErrorAction Stop } catch { try { $res = Get-PASUser -Search $inputName; if ($res.Count -eq 1) { $vaultUser = $res[0] } } catch {} }

                        if ($null -eq $vaultUser) {
                            Write-Host "    ! User '$inputName' not found." -ForegroundColor Red
                            continue
                        }
                        $officialName = $vaultUser.UserName
                        $officialId = $vaultUser.id
                        $domain = $vaultUser.Domain # Useful context for debugging

                        # --- DEBUG LOGS ---
                        Write-Host "    ------------------------------------------------" -ForegroundColor Magenta
                        Write-Host "    [DEBUG] Group Name: $safeMember (ID: $groupId)" -ForegroundColor Magenta
                        Write-Host "    [DEBUG] User Name:  $officialName (ID: $officialId)" -ForegroundColor Magenta
                        Write-Host "    [DEBUG] User Domain:$domain" -ForegroundColor Magenta
                        
                        # METHOD 1: Standard Cmdlet
                        try {
                            Add-PASGroupMember -groupId $groupId -memberId $officialName -ErrorAction Stop
                            Write-Host "    [SUCCESS] Added via Cmdlet." -ForegroundColor Green
                        } 
                        catch {
                            # CAPTURE 500 ERROR DETAILS
                            $ex = $_.Exception
                            $errMsg = $ex.Message
                            $responseBody = ""
                            
                            # Try to read the hidden JSON error from the server
                            if ($ex.Response) {
                                $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                                $responseBody = $reader.ReadToEnd()
                            }

                            Write-Host "    [FAIL] Cmdlet failed. Message: $errMsg" -ForegroundColor Red
                            if ($responseBody) { Write-Host "    [SERVER RESPONSE] $responseBody" -ForegroundColor Yellow }

                            # METHOD 2: FALLBACK (Direct API Call)
                            if ($errMsg -match "500|Internal Server") {
                                Write-Host "    [RETRY] Attempting Direct API Fallback..." -ForegroundColor Yellow
                                try {
                                    # Fallback: POST /UserGroups/{GroupID}/Members
                                    # We try passing MemberName. If that fails, some versions need MemberId.
                                    $uri = "PasswordVault/API/UserGroups/$groupId/Members"
                                    
                                    # Try standard Payload
                                    $body = @{ "MemberName" = $officialName } | ConvertTo-Json
                                    
                                    Invoke-PASRestMethod -Uri $uri -Method POST -Body $body -ErrorAction Stop | Out-Null
                                    Write-Host "    [SUCCESS] Added via Direct API." -ForegroundColor Green
                                }
                                catch {
                                    Write-Host "    [FAIL] Fallback also failed: $($_.Exception.Message)" -ForegroundColor Red
                                    # Try reading response body again for the fallback
                                    if ($_.Exception.Response) {
                                        $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                                        Write-Host "    [FALLBACK RESPONSE] $($r.ReadToEnd())" -ForegroundColor Red
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        # -----------------------------
        # 3. PERMISSIONS & SAFE ATTACHMENT
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
        
        $results += [pscustomobject]$result
    }
    
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "Done." -ForegroundColor Green
}
Export-ModuleMember -Function Invoke-CACBatchOnboarding