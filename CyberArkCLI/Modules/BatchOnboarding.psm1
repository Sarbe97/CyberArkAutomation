# ==========================
# BatchOnboarding.psm1
# ==========================

function Invoke-CACBatchOnboarding222 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$OutputCsvPath = (Join-Path $PSScriptRoot "BatchOnboarding_Result.csv")
    )

    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV not found: $CsvPath"
        return
    }

    $data = Import-Csv $CsvPath
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    $results = @()

    foreach ($row in $data) {

        Write-Host "`n--- Processing Safe [$($row.SafeName)] / Member [$($row.SafeMember)] ---" -ForegroundColor Cyan

        # -----------------------------
        # Result tracking object
        # -----------------------------
        $result = [ordered]@{
            SafeName             = $row.SafeName
            SafeStatus           = "Unknown"
            SafeMember           = $row.SafeMember
            MemberType           = "Unknown"
            GroupStatus          = "NotApplicable"
            GroupMembersAction   = "NotApplicable"
            SafeMembershipStatus = "NotAttempted"
            OverallStatus        = "FAILED"
            Message              = ""
        }

        # -----------------------------
        # SAFE CHECK / CREATE
        # -----------------------------
        $safeReady = $false

        try {
            Get-PASSafe -SafeName $row.SafeName -ErrorAction Stop | Out-Null
            $safeReady = $true
            $result.SafeStatus = "Exists"
            Write-Log "Safe exists: $($row.SafeName)" "INFO"
        }
        catch {
            $versions = if ($row.NumberOfVersionsRetention) { [int]$row.NumberOfVersionsRetention } else { $null }
            $days = if ($row.NumberOfDaysRetention) { [int]$row.NumberOfDaysRetention }     else { $null }

            if (-not $versions -and -not $days) {
                $result.SafeStatus = "Failed"
                $result.Message = "Retention policy missing"
                $results += [pscustomobject]$result
                Write-Log "Safe '$($row.SafeName)' missing retention policy" "ERROR"
                continue
            }

            $safeParams = @{
                SafeName    = $row.SafeName
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
                Write-Log "Safe created: $($row.SafeName)" "SUCCESS"
            }
            catch {
                $result.SafeStatus = "Failed"
                $result.Message = $_.Exception.Message
                $results += [pscustomobject]$result
                Write-Log "Safe creation failed: $($_.Exception.Message)" "ERROR"
                continue
            }
        }

        if (-not $safeReady) {
            $results += [pscustomobject]$result
            continue
        }

        # -----------------------------
        # MEMBER HANDLING
        # -----------------------------
        $groupExists = $false
        $userExists = $false

        try {
            Get-PASGroup -GroupName $row.SafeMember -ErrorAction Stop | Out-Null
            $groupExists = $true
            $result.MemberType = "Group"
        }
        catch {
            try {
                Get-PASUser -UserName $row.SafeMember -ErrorAction Stop | Out-Null
                $userExists = $true
                $result.MemberType = "User"
            }
            catch {
                $result.Message = "Member not found"
            }
        }

        # ---- GROUP LOGIC ----
        if ($result.MemberType -eq "Group" -or $row.Users) {

            if (-not $groupExists) {
                try {
                    New-PASGroup `
                        -GroupName $row.SafeMember `
                        -Description $row.MemberDescription `
                        -ErrorAction Stop

                    $result.GroupStatus = "Created"
                    Write-Log "Group created: $($row.SafeMember)" "SUCCESS"

                    if ($row.Users) {
                        foreach ($u in ($row.Users -split ";")) {
                            if (-not $u.Trim()) { continue }
                            Add-PASGroupMember `
                                -GroupName $row.SafeMember `
                                -Member $u.Trim() `
                                -ErrorAction Stop
                        }
                        $result.GroupMembersAction = "Added"
                    }
                }
                catch {
                    $result.GroupStatus = "Failed"
                    $result.Message = $_.Exception.Message
                }
            }
            else {
                $result.GroupStatus = "Exists"
                $result.GroupMembersAction = "Skipped"
                Write-Log "Group exists, membership unchanged: $($row.SafeMember)" "INFO"
            }
        }

        # -----------------------------
        # PERMISSIONS
        # -----------------------------
        if ($row.Permissions) {
            $perms = $row.Permissions -split ";" | ForEach-Object { $_.Trim() }
        }
        else {
            $perms = $permissionSets.$($row.PermissionKey)
        }

        # -----------------------------
        # ADD MEMBER TO SAFE
        # -----------------------------
        try {
            Add-PASSafeMember `
                -SafeName $row.SafeName `
                -MemberName $row.SafeMember `
                -Permissions $perms `
                -SearchInVault $true `
                -ErrorAction Stop

            $result.SafeMembershipStatus = "Added"
            $result.OverallStatus = "SUCCESS"
            Write-Log "Member added to safe: $($row.SafeMember)" "SUCCESS"
        }
        catch {
            if ($_.Exception.Message -match "409|already exists") {
                $result.SafeMembershipStatus = "Exists"
                $result.OverallStatus = "SUCCESS"
                Write-Log "Member already in safe: $($row.SafeMember)" "INFO"
            }
            else {
                $result.SafeMembershipStatus = "Failed"
                $result.Message = $_.Exception.Message
            }
        }

        if ($result.OverallStatus -ne "SUCCESS") {
            $result.OverallStatus = "PARTIAL"
        }

        $results += [pscustomobject]$result
    }

    # -----------------------------
    # EXPORT RESULT CSV
    # -----------------------------
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force

    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
    Write-Host "Result CSV generated at: $OutputCsvPath" -ForegroundColor Green
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding
