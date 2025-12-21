# ==========================
# BatchOnboarding.psm1
# ==========================

function New-CACBatchOnboardingTemplate {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot "..\OnboardingTemplate.csv")
    )

    $header = "SafeName,SafeDescription,ManagingCPM,SafeMember,MemberDescription,PermissionKey,Permissions,Users"
    $rows = @(
        "Safe_Finance,Financial Data Safe,CPM_Prod,Finance_Admins,Admin Group for Finance,VAULT_ADMIN,,john.doe;jane.smith"
        "Safe_HR,HR Documents Safe,CPM_Prod,audit_user,Auditor for HR,SAFE_READ,,"
        "Safe_IT,IT Operations Safe,CPM_DR,VaultAdmins,System Admins,VAULT_ADMIN,,"
    )

    try {
        ($header + "`n" + ($rows -join "`n")) |
        Out-File -FilePath $Path -Encoding UTF8 -Force

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
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    Write-Log "Starting batch onboarding from: $CsvPath" "INFO"

    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found: $CsvPath"
        return
    }

    try {
        $data = Import-Csv -Path $CsvPath
    }
    catch {
        Write-Error "Failed to import CSV: $($_.Exception.Message)"
        return
    }

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    foreach ($row in $data) {

        Write-Host "`n--- Processing Row: Safe [$($row.SafeName)] / Member [$($row.SafeMember)] ---" -ForegroundColor Cyan

        # -------------------------------------------------------------
        # 1. SAFE CHECK / CREATE
        # -------------------------------------------------------------
        $safeReady = $false

        try {
            Get-PASSafe -SafeName $row.SafeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            Write-Host "Safe '$($row.SafeName)' already exists." -ForegroundColor Yellow
        }
        catch {
            if ($_.Exception.Message -match "404") {
                try {
                    Write-Log "Creating Safe: $($row.SafeName)" "INFO"
                    Add-PASSafe `
                        -SafeName $row.SafeName `
                        -Description $row.SafeDescription `
                        -ManagingCPM $row.ManagingCPM `
                        -ErrorAction Stop

                    $safeReady = $true
                    Write-Host "Safe created successfully." -ForegroundColor Green
                }
                catch {
                    Write-Log "Failed to create safe '$($row.SafeName)': $($_.Exception.Message)" "ERROR"
                    continue
                }
            }
            else {
                Write-Log "Error checking safe '$($row.SafeName)': $($_.Exception.Message)" "ERROR"
                continue
            }
        }

        if (-not $safeReady) {
            Write-Log "Skipping row because safe is not ready." "ERROR"
            continue
        }

        # -------------------------------------------------------------
        # 2. USER / GROUP HANDLING
        # -------------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace($row.SafeMember)) {

            $isGroupOperation = -not [string]::IsNullOrWhiteSpace($row.Users)

            # -------- Scenario A: Group + Users --------
            if ($isGroupOperation) {
                try {
                    $groupExists = $false
                    try {
                        Get-PASGroup -GroupName $row.SafeMember -ErrorAction Stop | Out-Null
                        $groupExists = $true
                        Write-Host "Group '$($row.SafeMember)' already exists." -ForegroundColor Yellow
                    }
                    catch {
                        Write-Log "Creating group '$($row.SafeMember)'" "INFO"
                        New-PASGroup `
                            -GroupName $row.SafeMember `
                            -Description $row.MemberDescription `
                            -ErrorAction Stop
                        Write-Host "Group '$($row.SafeMember)' created." -ForegroundColor Green
                    }

                    $userList = $row.Users -split ";" | ForEach-Object { $_.Trim() }
                    foreach ($username in $userList) {
                        if ([string]::IsNullOrWhiteSpace($username)) { continue }

                        try {
                            Add-PASGroupMember `
                                -GroupName $row.SafeMember `
                                -Member $username `
                                -ErrorAction Stop
                            Write-Host "  Added '$username' to group." -ForegroundColor Green
                        }
                        catch {
                            if ($_.Exception.Message -match "409|already exists") {
                                Write-Log "User '$username' already in group '$($row.SafeMember)'" "DEBUG"
                            }
                            else {
                                Write-Log "Failed adding '$username' to group: $($_.Exception.Message)" "ERROR"
                            }
                        }
                    }
                }
                catch {
                    Write-Log "Group operation failed: $($_.Exception.Message)" "ERROR"
                    continue
                }
            }
            # -------- Scenario B: Existing User or Group --------
            else {
                try {
                    if (Get-PASUser -UserName $row.SafeMember -ErrorAction Ignore) {
                        Write-Host "Found User '$($row.SafeMember)'." -ForegroundColor Gray
                    }
                    elseif (Get-PASGroup -GroupName $row.SafeMember -ErrorAction Ignore) {
                        Write-Host "Found Group '$($row.SafeMember)'." -ForegroundColor Gray
                    }
                    else {
                        Write-Host "Warning: '$($row.SafeMember)' not found as User or Group." -ForegroundColor Magenta
                    }
                }
                catch { }
            }

            # -------------------------------------------------------------
            # 3. ADD MEMBER TO SAFE
            # -------------------------------------------------------------
            try {
                if ($row.Permissions) {
                    $perms = $row.Permissions -split ";" | ForEach-Object { $_.Trim() }
                }
                else {
                    $key = if ($row.PermissionKey) { $row.PermissionKey } else { "SAFE_READ" }
                    $perms = $permissionSets.$key
                    if (-not $perms) { $perms = $permissionSets.SAFE_READ }
                }

                Add-PASSafeMember `
                    -SafeName $row.SafeName `
                    -MemberName $row.SafeMember `
                    -Permissions $perms `
                    -SearchInVault $true `
                    -ErrorAction Stop

                Write-Host "Member '$($row.SafeMember)' added to safe." -ForegroundColor Green
            }
            catch {
                if ($_.Exception.Message -match "409|already exists") {
                    Write-Host "Member already exists in safe." -ForegroundColor Yellow
                }
                else {
                    Write-Log "Failed adding member to safe: $($_.Exception.Message)" "ERROR"
                }
            }
        }
    }

    Write-Log "Batch onboarding completed." "SUCCESS"
    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function `
    New-CACBatchOnboardingTemplate, `
    Invoke-CACBatchOnboarding
