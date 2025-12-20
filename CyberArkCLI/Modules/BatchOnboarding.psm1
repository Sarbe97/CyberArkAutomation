# ==========================
# BatchOnboarding.psm1
# ==========================

function New-CACBatchOnboardingTemplate {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot "..\OnboardingTemplate.csv")
    )
    #Permissions takes precedence over PermissionKey
    $header = "SafeName,SafeDescription,ManagingCPM,SafeMember,MemberDescription,PermissionKey,Permissions,Users"
    $rows = @(
        "Safe_Finance,Financial Data Safe,CPM_Prod,Finance_Admins,Admin Group for Finance,VAULT_ADMIN,,john.doe;jane.smith"
        "Safe_HR,HR Documents Safe,CPM_Prod,audit_user,Auditor for HR,SAFE_READ,,"
        "Safe_IT,IT Operations Safe,CPM_DR,VaultAdmins,System Admins,VAULT_ADMIN,,"
    )
    
    $content = $header + "`n" + ($rows -join "`n")
    
    try {
        $content | Out-File -FilePath $Path -Encoding UTF8 -Force
        Write-Log "Batch onboarding template created at: $Path" "SUCCESS"
        Write-Host "Template created at: $Path" -ForegroundColor Green
    }
    catch {
        Write-Log "Failed to create template: $($_.Exception.Message)" "ERROR"
        Write-Error "Failed to create template: $($_.Exception.Message)"
    }
}

function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CsvPath
    )

    Write-Log "Starting batch onboarding from: $CsvPath" "INFO"

    if (-not (Test-Path $CsvPath)) {
        Write-Log "CSV file not found: $CsvPath" "ERROR"
        Write-Error "CSV file not found: $CsvPath"
        return
    }

    try {
        $data = Import-Csv -Path $CsvPath
    }
    catch {
        Write-Log "Failed to import CSV: $($_.Exception.Message)" "ERROR"
        Write-Error "Failed to import CSV: $($_.Exception.Message)"
        return
    }

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    foreach ($row in $data) {
        Write-Host "`n--- Processing Row: Safe [$($row.SafeName)] / Member [$($row.SafeMember)] ---" -ForegroundColor Cyan

        # -------------------------------------------------------------
        # 1. Create Safe if not exists
        # -------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($row.SafeName)) {
            try {
                $existingSafe = Get-PASSafe -SafeName $row.SafeName -ErrorAction Ignore
                if (-not $existingSafe) {
                    Write-Log "Creating Safe: $($row.SafeName)" "INFO"
                    Add-PASSafe -SafeName $row.SafeName `
                        -Description $row.SafeDescription `
                        -ManagingCPM $row.ManagingCPM -ErrorAction Stop
                    Write-Host "Safe created successfully." -ForegroundColor Green
                } else {
                    Write-Host "Safe '$($row.SafeName)' already exists." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Log "Error creating safe '$($row.SafeName)': $($_.Exception.Message)" "ERROR"
                Write-Host "Error creating safe: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        # -------------------------------------------------------------
        # 2. Logic: User vs Group Detection
        # -------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($row.SafeMember)) {
            
            $isGroupOperation = -not [string]::IsNullOrWhiteSpace($row.Users)

            # Scenario A: Users column has values -> Treat as Group that performs management
            if ($isGroupOperation) {
                # 1. Check/Create Group
                try {
                    $existingGroup = Get-PASGroup -GroupName $row.SafeMember -ErrorAction Ignore
                    
                    if (-not $existingGroup) {
                        # Group doesn't exist, create it
                        Write-Log "Creating Safe-Specific Group: $($row.SafeMember)" "INFO"
                        New-PASGroup -GroupName $row.SafeMember -Description $row.MemberDescription -ErrorAction Stop
                        Write-Host "Group '$($row.SafeMember)' created." -ForegroundColor Green
                    } 
                    else {
                        # Group exists
                        Write-Host "Group '$($row.SafeMember)' already exists. Adding any new members..." -ForegroundColor Yellow
                    }

                    # 2. Add Users to Group 
                    # Logic Update: Whether group is new or existing, we attempt to add the listed users.
                    # PsPAS/API will fail if user is already a member, which we catch. This allows "Adding new members" without "Modifying existing ones" (removing etc).
                    
                    $userList = $row.Users -split ";" | ForEach-Object { $_.Trim() }
                    foreach ($username in $userList) {
                        if ([string]::IsNullOrWhiteSpace($username)) { continue }
                        try {
                            Add-PASGroupMember -GroupName $row.SafeMember -MemberName $username -ErrorAction Stop
                            Write-Host "  Added '$username' to group." -ForegroundColor Green
                        }
                        catch {
                            # 409 Conflict = Already exists
                            if ($_.Exception.Message -match "already exists" -or $_.Exception.Message -match "409") {
                                # Silent or low-level log for existing members to reduce noise
                                Write-Log "User '$username' already in group '$($row.SafeMember)'" "DEBUG"
                            }
                            else {
                                Write-Log "Failed to add '$username' to group: $_" "ERROR"
                                Write-Host "  Failed to add '$username': $($_.Exception.Message)" -ForegroundColor Red
                            }
                        }
                    }
                }
                catch {
                    Write-Log "Group operation failed: $_" "ERROR"
                    continue
                }
            }
            # Scenario B: Users column Empty -> Treat as Existing Entity (User OR Group e.g. VaultAdmins)
            else {
                # No creation logic here. We assume it exists.
                # Validate existence
                try {
                   # Check if it's a User
                   $u = Get-PASUser -UserName $row.SafeMember -ErrorAction Ignore
                   if (-not $u) {
                       # Check if it's a Group
                       $g = Get-PASGroup -GroupName $row.SafeMember -ErrorAction Ignore
                       if (-not $g) {
                           Write-Host "Warning: Member '$($row.SafeMember)' not found as User or Group." -ForegroundColor Magenta
                       } else {
                           Write-Host "Found Group '$($row.SafeMember)'." -ForegroundColor Gray
                       }
                   } else {
                       Write-Host "Found User '$($row.SafeMember)'." -ForegroundColor Gray
                   }
                }
                catch { }
            }

            # -------------------------------------------------------------
            # 3. Add Member (User or Group) to Safe
            # -------------------------------------------------------------
            if (-not [string]::IsNullOrWhiteSpace($row.SafeName)) {
                try {
                    $perms = $null
                    
                    # Direct permissions check
                    if ($row.Permissions -and -not [string]::IsNullOrWhiteSpace($row.Permissions)) {
                        $perms = $row.Permissions -split ";" | ForEach-Object { $_.Trim() }
                    }
                    else {
                        $permKey = if ($row.PermissionKey) { $row.PermissionKey } else { "SAFE_READ" }
                        $perms = $permissionSets.$permKey
                        
                        if (-not $perms) { $perms = $permissionSets.SAFE_READ }
                    }

                    Write-Log "Adding '$($row.SafeMember)' toSafe '$($row.SafeName)'" "INFO"
                    Add-PASSafeMember -SafeName $row.SafeName `
                        -MemberName $row.SafeMember `
                        -Permissions $perms `
                        -SearchInVault $true -ErrorAction Stop
                    Write-Host "Member '$($row.SafeMember)' added to safe." -ForegroundColor Green
                }
                catch {
                    if ($_.Exception.Message -match "already exists" -or $_.Exception.Message -match "409") {
                        Write-Host "Member already in safe." -ForegroundColor Yellow
                    }
                    else {
                        Write-Log "Error adding to safe: $($_.Exception.Message)" "ERROR"
                        Write-Host "Failed to add to safe." -ForegroundColor Red
                    }
                }
            }
        }
    }

    Write-Log "Batch onboarding completed." "SUCCESS"
    Write-Host "`nBatch onboarding process completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function New-CACBatchOnboardingTemplate, Invoke-CACBatchOnboarding
