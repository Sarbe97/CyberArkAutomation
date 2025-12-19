# ==========================
# BatchOnboarding.psm1
# ==========================

function New-CACBatchOnboardingTemplate {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot "..\OnboardingTemplate.csv")
    )
    
    $header = "SafeName,SafeDescription,ManagingCPM,GroupName,GroupDescription,PermissionKey,Permissions,Users"
    $rows = @(
        "Safe_Finance,Financial Data Safe,CPM_Prod,Finance_Admins,Admin Group for Finance,VAULT_ADMIN,,john.doe;jane.smith"
        "Safe_HR,HR Documents Safe,CPM_Prod,HR_Users,Read-Only Group for HR,,ListAccounts;RetrieveAccounts;UseAccounts,alice.williams"
        "Safe_IT,IT Operations Safe,CPM_DR,IT_Ops_Group,Operations Team,SAFE_READ_WRITE,,bob.jones;charlie.brown"
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
        Write-Host "`n--- Processing Row: Safe [$($row.SafeName)] / Group [$($row.GroupName)] ---" -ForegroundColor Cyan

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
        # 2. Create Group if not exists
        # -------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($row.GroupName)) {
            try {
                $existingGroup = Get-PASGroup -GroupName $row.GroupName -ErrorAction Ignore
                if (-not $existingGroup) {
                    Write-Log "Creating Group: $($row.GroupName)" "INFO"
                    New-PASGroup -GroupName $row.GroupName -Description $row.GroupDescription -ErrorAction Stop
                    Write-Host "Group created successfully." -ForegroundColor Green
                } else {
                    Write-Host "Group '$($row.GroupName)' already exists." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Log "Error creating group '$($row.GroupName)': $($_.Exception.Message)" "ERROR"
                Write-Host "Error creating group: $($_.Exception.Message)" -ForegroundColor Red
            }

            # -------------------------------------------------------------
            # 3. Add Group as Safe Member
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

                    Write-Log "Adding Group '$($row.GroupName)' to Safe '$($row.SafeName)'" "INFO"
                    Add-PASSafeMember -SafeName $row.SafeName `
                        -MemberName $row.GroupName `
                        -Permissions $perms `
                        -SearchInVault $true -ErrorAction Stop
                    Write-Host "Group added as safe member." -ForegroundColor Green
                }
                catch {
                    # If already a member, psPAS might throw error
                    if ($_.Exception.Message -match "already exists" -or $_.Exception.Message -match "409") {
                        Write-Host "Group is already a member of the safe." -ForegroundColor Yellow
                    }
                    else {
                        Write-Log "Error adding group to safe: $($_.Exception.Message)" "ERROR"
                        Write-Host "Error adding group to safe: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }

            # -------------------------------------------------------------
            # 4. Add Users to Group
            # -------------------------------------------------------------
            if (-not [string]::IsNullOrWhiteSpace($row.Users)) {
                $userList = $row.Users -split ";" | ForEach-Object { $_.Trim() }
                foreach ($username in $userList) {
                    if ([string]::IsNullOrWhiteSpace($username)) { continue }
                    try {
                        Write-Log "Adding User '$username' to Group '$($row.GroupName)'" "INFO"
                        Add-PASGroupMember -GroupName $row.GroupName -MemberName $username -ErrorAction Stop
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
    }

    Write-Log "Batch onboarding completed." "SUCCESS"
    Write-Host "`nBatch onboarding process completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function New-CACBatchOnboardingTemplate, Invoke-CACBatchOnboarding
