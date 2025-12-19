# ==========================
# BatchOnboarding.psm1
# ==========================

function New-CACBatchOnboardingTemplate {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot "..\OnboardingTemplate.csv")
    )
    
    $header = "SafeName,SafeDescription,ManagingCPM,MemberName,MemberType,MemberDescription,PermissionKey,Permissions,GroupMembers"
    $rows = @(
        "Safe_Finance,Financial Data Safe,CPM_Prod,Finance_Admins,Group,Admin Group for Finance,VAULT_ADMIN,,john.doe;jane.smith"
        "Safe_HR,HR Documents Safe,CPM_Prod,audit_user,User,Auditor for HR,SAFE_READ,,"
        "Safe_IT,IT Operations Safe,CPM_DR,IT_Ops_Group,Group,Operations Team,,ListAccounts;RetrieveAccounts;UseAccounts,bob.jones"
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
        Write-Host "`n--- Processing Row: Safe [$($row.SafeName)] / Member [$($row.MemberName)] ---" -ForegroundColor Cyan

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
        # 2. Handle Member (Group or User)
        # -------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($row.MemberName)) {
            
            # Default to Group if not specified
            $type = if ($row.MemberType) { $row.MemberType } else { "Group" }

            if ($type -eq "Group") {
                # --- GROUP LOGIC ---
                try {
                    $existingGroup = Get-PASGroup -GroupName $row.MemberName -ErrorAction Ignore
                    if (-not $existingGroup) {
                        Write-Log "Creating Group: $($row.MemberName)" "INFO"
                        New-PASGroup -GroupName $row.MemberName -Description $row.MemberDescription -ErrorAction Stop
                        Write-Host "Group created successfully." -ForegroundColor Green
                    } else {
                        Write-Host "Group '$($row.MemberName)' already exists." -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Log "Error checking/creating group '$($row.MemberName)': $($_.Exception.Message)" "ERROR"
                    Write-Host "Error checking/creating group: $($_.Exception.Message)" -ForegroundColor Red
                    continue 
                }

                # Add Users to Group (only applies to Group type)
                if (-not [string]::IsNullOrWhiteSpace($row.GroupMembers)) {
                    $userList = $row.GroupMembers -split ";" | ForEach-Object { $_.Trim() }
                    foreach ($username in $userList) {
                        if ([string]::IsNullOrWhiteSpace($username)) { continue }
                        try {
                            Write-Log "Adding User '$username' to Group '$($row.MemberName)'" "INFO"
                            Add-PASGroupMember -GroupName $row.MemberName -MemberName $username -ErrorAction Stop
                            Write-Host "User '$username' added to group." -ForegroundColor Green
                        }
                        catch {
                            if ($_.Exception.Message -match "already exists" -or $_.Exception.Message -match "409") {
                                Write-Host "User '$username' is already in group." -ForegroundColor Yellow
                            }
                            else {
                                Write-Log "Failed to add user '$username' to group: $($_.Exception.Message)" "ERROR"
                                Write-Host "Failed to add user '$username': $($_.Exception.Message)" -ForegroundColor Red
                            }
                        }
                    }
                }
            }
            elseif ($type -eq "User") {
                # --- USER LOGIC ---
                try {
                    # Verify user exists (optional but good practice)
                    $user = Get-PASUser -UserName $row.MemberName -ErrorAction Ignore
                    if (-not $user) {
                        Write-Host "User '$($row.MemberName)' not found in PAS! proceeding anyway (might fail)..." -ForegroundColor Magenta
                    } else {
                        Write-Host "User '$($row.MemberName)' found." -ForegroundColor Green
                    }
                    
                    if (-not [string]::IsNullOrWhiteSpace($row.GroupMembers)) {
                        Write-Warning "Row contains 'GroupMembers' but MemberType is 'User'. Ignoring members."
                    }
                }
                catch {
                     Write-Log "Error checking user '$($row.MemberName)': $($_.Exception.Message)" "ERROR"
                }
            }

            # -------------------------------------------------------------
            # 3. Add Member (User or Group) to Safe
            # -------------------------------------------------------------
            if (-not [string]::IsNullOrWhiteSpace($row.SafeName)) {
                try {
                    $perms = $null
                    
                    # Check for direct permissions first
                    if ($row.Permissions -and -not [string]::IsNullOrWhiteSpace($row.Permissions)) {
                        $perms = $row.Permissions -split ";" | ForEach-Object { $_.Trim() }
                        Write-Log "Using direct permissions: $($row.Permissions)" "DEBUG"
                    }
                    else {
                        $permKey = if ($row.PermissionKey) { $row.PermissionKey } else { "SAFE_READ" }
                        $perms = $permissionSets.$permKey
                        
                        if (-not $perms) {
                            Write-Log "PermissionKey '$permKey' not found. Defaulting to SAFE_READ." "WARN"
                            $perms = $permissionSets.SAFE_READ
                        }
                        Write-Log "Using permission set key: $permKey" "DEBUG"
                    }

                    Write-Log "Adding Member '$($row.MemberName)' to Safe '$($row.SafeName)'" "INFO"
                    Add-PASSafeMember -SafeName $row.SafeName `
                        -MemberName $row.MemberName `
                        -Permissions $perms `
                        -SearchInVault $true -ErrorAction Stop
                    Write-Host "Member added to safe: $($row.MemberName)" -ForegroundColor Green
                }
                catch {
                    # If already a member, psPAS might throw error
                    if ($_.Exception.Message -match "already exists" -or $_.Exception.Message -match "409") {
                        Write-Host "Member is already in the safe." -ForegroundColor Yellow
                    }
                    else {
                        Write-Log "Error adding member to safe: $($_.Exception.Message)" "ERROR"
                        Write-Host "Error adding member to safe: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
    }

    Write-Log "Batch onboarding completed." "SUCCESS"
    Write-Host "`nBatch onboarding process completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function New-CACBatchOnboardingTemplate, Invoke-CACBatchOnboarding
