function Invoke-CACBatchOnboarding {
    [CmdletBinding()]
    param(
        # Provide FULL PATH to SAFE LIST CSV.
        # Member list will be auto-resolved as <SafeFileName>-members.csv in the same directory.
        [Parameter(Mandatory)]
        [string]$SafeCsvPath
    )

    # -------------------------------
    # Resolve member CSV automatically
    # -------------------------------
    if (-not (Test-Path $SafeCsvPath)) {
        throw "Safe CSV not found: $SafeCsvPath"
    }

    $baseDir = Split-Path $SafeCsvPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SafeCsvPath)
    $memberCsvPath = Join-Path $baseDir "$baseName-members.csv"

    if (-not (Test-Path $memberCsvPath)) {
        throw "Member CSV not found: $memberCsvPath"
    }

    Write-Log "Safe CSV: $SafeCsvPath" "INFO"
    Write-Log "Member CSV: $memberCsvPath" "INFO"

    # -------------------------------
    # Import CSVs
    # -------------------------------
    $safes = Import-Csv $SafeCsvPath
    $members = Import-Csv $memberCsvPath

    # -------------------------------
    # Schema validation
    # -------------------------------
    $safeHeaders = "SafeName", "SafeDescription", "ManagingCPM", "NumberOfVersionsRetention", "NumberOfDaysRetention"
    $memberHeaders = "SafeName", "SafeMember", "MemberType", "PermissionKey", "Users"

    foreach ($h in $safeHeaders) {
        if (-not ($safes[0].PSObject.Properties.Name -contains $h)) {
            throw "Safes CSV missing column: $h"
        }
    }

    foreach ($h in $memberHeaders) {
        if (-not ($members[0].PSObject.Properties.Name -contains $h)) {
            throw "Members CSV missing column: $h"
        }
    }

    # -------------------------------
    # Summary tracking
    # -------------------------------
    $summary = @{}

    function Init-SafeSummary($safeName) {
        if (-not $summary.ContainsKey($safeName)) {
            $summary[$safeName] = [PSCustomObject]@{
                SafeName       = $safeName
                SafeCreated    = $false
                MembersAdded   = 0
                MembersSkipped = 0
                Errors         = 0
                Logs           = @()
            }
        }
    }

    # -------------------------------
    # Load config.json for permission mapping
    # -------------------------------
    $config = Get-CACConfig

    # -------------------------------
    # Phase 1: Safes
    # -------------------------------
    foreach ($safe in $safes) {
        Init-SafeSummary $safe.SafeName

        $hasVersions = -not [string]::IsNullOrWhiteSpace($safe.NumberOfVersionsRetention)
        $hasDays = -not [string]::IsNullOrWhiteSpace($safe.NumberOfDaysRetention)

        if ($hasVersions -and $hasDays) {
            $msg = "Safe '$($safe.SafeName)' has BOTH retention values. Only one allowed."
            $summary[$safe.SafeName].Errors++
            $summary[$safe.SafeName].Logs += $msg
            Write-Log $msg "ERROR"
            continue
        }
        if (-not ($hasVersions -or $hasDays)) {
            $msg = "Safe '$($safe.SafeName)' must have one retention value."
            $summary[$safe.SafeName].Errors++
            $summary[$safe.SafeName].Logs += $msg
            Write-Log $msg "ERROR"
            continue
        }

        try {
            $existing = Get-PASSafe -SafeName $safe.SafeName -ErrorAction Ignore
            if (-not $existing) {
                Add-PASSafe `
                    -SafeName $safe.SafeName `
                    -Description $safe.SafeDescription `
                    -ManagingCPM $safe.ManagingCPM `
                    -NumberOfVersionsRetention $safe.NumberOfVersionsRetention `
                    -NumberOfDaysRetention $safe.NumberOfDaysRetention `
                    -ErrorAction Stop

                # Confirm creation
                Start-Sleep -Seconds 2
                $existing = Get-PASSafe -SafeName $safe.SafeName -ErrorAction Stop
                Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
                $summary[$safe.SafeName].SafeCreated = $true
            }
            else {
                Write-Log "Safe exists: $($safe.SafeName)" "INFO"
            }
        }
        catch {
            $summary[$safe.SafeName].Errors++
            $summary[$safe.SafeName].Logs += "Safe creation error [$($safe.SafeName)]: $_"
            Write-Log "Safe creation error [$($safe.SafeName)]: $_" "ERROR"
            continue
        }
    }

    # -------------------------------
    # Phase 2: Members
    # -------------------------------
    foreach ($row in $members) {
        Init-SafeSummary $row.SafeName
        $logPrefix = "Safe [$($row.SafeName)] / Member [$($row.SafeMember)]"

        try {
            if ($row.MemberType -eq "Group") {
                $group = Get-PASGroup -GroupName $row.SafeMember -ErrorAction Ignore

                if (-not $group) {
                    New-PASGroup -GroupName $row.SafeMember -Description "Auto-created" -ErrorAction Stop
                    Write-Log "$logPrefix - Group created." "INFO"
                    $summary[$row.SafeName].Logs += "Group created: $($row.SafeMember)"

                    if ($row.Users) {
                        foreach ($u in ($row.Users -split ";")) {
                            $uname = $u.Trim()
                            if ([string]::IsNullOrWhiteSpace($uname)) { continue }
                            try {
                                Add-PASGroupMember -GroupName $row.SafeMember -UserName $uname -ErrorAction Stop
                                Write-Log "$logPrefix - Added user '$uname' to group." "SUCCESS"
                                $summary[$row.SafeName].Logs += "Added user '$uname' to group '$($row.SafeMember)'"
                            }
                            catch {
                                $summary[$row.SafeName].Logs += "Failed to add user '$uname': $_"
                                Write-Log "$logPrefix - Failed to add user '$uname': $_" "ERROR"
                            }
                        }
                    }
                }
                else {
                    Write-Log "$logPrefix - Group exists, adding to safe." "INFO"
                    $summary[$row.SafeName].Logs += "Group exists: $($row.SafeMember)"
                }

                # -------------------------------
                # Add group to safe with dynamic permissions
                # -------------------------------
                try {
                    $perms = $config.SafePermissionSets[$row.PermissionKey]
                    $permParams = @{}
                    foreach ($p in $perms) { $permParams[$p] = $true }

                    Add-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -SearchInVault $true -ErrorAction Stop
                    Write-Log "$logPrefix - Added group to safe." "SUCCESS"
                    $summary[$row.SafeName].MembersAdded++
                }
                catch {
                    if ($_.Exception.Message -match "already exists|409") {
                        Write-Log "$logPrefix - Member already in safe, skipped." "INFO"
                        $summary[$row.SafeName].MembersSkipped++
                        $summary[$row.SafeName].Logs += "Member already in safe."
                    }
                    else {
                        $summary[$row.SafeName].Errors++
                        $summary[$row.SafeName].Logs += "$logPrefix - Failed to add to safe: $_"
                        Write-Log "$logPrefix - Failed to add to safe: $_" "ERROR"
                    }
                }
            }
            else {
                # User
                try {
                    $perms = $config.SafePermissionSets[$row.PermissionKey]
                    $permParams = @{}
                    foreach ($p in $perms) { $permParams[$p] = $true }

                    Add-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -SearchInVault $true -ErrorAction Stop
                    Write-Log "$logPrefix - User added to safe." "SUCCESS"
                    $summary[$row.SafeName].MembersAdded++
                }
                catch {
                    if ($_.Exception.Message -match "already exists|409") {
                        Write-Log "$logPrefix - User already in safe, skipped." "INFO"
                        $summary[$row.SafeName].MembersSkipped++
                        $summary[$row.SafeName].Logs += "User already in safe."
                    }
                    else {
                        $summary[$row.SafeName].Errors++
                        $summary[$row.SafeName].Logs += "$logPrefix - Failed to add user: $_"
                        Write-Log "$logPrefix - Failed to add user: $_" "ERROR"
                    }
                }
            }
        }
        catch {
            $summary[$row.SafeName].Errors++
            $summary[$row.SafeName].Logs += "$logPrefix - Unexpected error: $_"
            Write-Log "$logPrefix - Unexpected error: $_" "ERROR"
        }
    }

    # -------------------------------
    # Write summary CSV
    # -------------------------------
    $summaryPath = Join-Path $baseDir "$baseName-summary.csv"
    $summary.Values | Select-Object SafeName, SafeCreated, MembersAdded, MembersSkipped, Errors |
    Export-Csv $summaryPath -NoTypeInformation

    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
    Write-Host "Summary written to: $summaryPath" -ForegroundColor Green

    # -------------------------------
    # Write detailed log file per safe
    # -------------------------------
    foreach ($safe in $summary.Values) {
        $logFile = Join-Path $baseDir "$($safe.SafeName)-log.txt"
        $safe.Logs | Out-File -FilePath $logFile -Encoding UTF8 -Force
        Write-Host "Detailed log for $($safe.SafeName): $logFile" -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding
