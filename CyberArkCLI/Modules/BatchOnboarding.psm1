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

                $summary[$safe.SafeName].SafeCreated = $true
                $summary[$safe.SafeName].Logs += "Safe created successfully."
                Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
            }
            else {
                $summary[$safe.SafeName].Logs += "Safe already exists."
                Write-Log "Safe exists: $($safe.SafeName)" "INFO"
            }
        }
    }
    catch {
        if ($_.Exception.Message -match "404|Not Found") {
            # Fallback if Get-PASSafe failed unexpectedly with 404 during check
            # We simply allow the loop to continue or consider it non-fatal if logic flows
            $summary[$safe.SafeName].Logs += "Reference check returned 404."
        }
        $msg = "Safe creation error [$($safe.SafeName)]: $_"
        $summary[$safe.SafeName].Errors++
        $summary[$safe.SafeName].Logs += $msg
        Write-Log $msg "ERROR"
    }
}

# -------------------------------
# Phase 2: Members
# -------------------------------
$config = Get-CACConfig

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
                            Add-PASGroupMember -GroupName $row.SafeMember -MemberName $uname -ErrorAction Stop
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
            # Add group to safe with dynamic permission mapping
            # -------------------------------
            try {
                # Handle PSCustomObject lookup for permissions
                $perms = $null
                if ($config.SafePermissionSets.PSObject.Properties.Match($row.PermissionKey)) {
                    $perms = $config.SafePermissionSets.$($row.PermissionKey)
                }

                if (-not $perms) {
                    Write-Log "$logPrefix - Permission Set '$($row.PermissionKey)' not found in config." "WARN"
                    $summary[$row.SafeName].Logs += "Permission Set '$($row.PermissionKey)' not found."
                    continue
                }

                $permParams = @{}
                foreach ($p in $perms) {
                    $permParams[$p] = $true
                }

                Add-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -ErrorAction Stop
                Write-Log "$logPrefix - Added to safe." "SUCCESS"
                $summary[$row.SafeName].MembersAdded++
            }
            catch {
                if ($_.Exception.Message -match "already exists|409") {
                    Write-Log "$logPrefix - Member already in safe, skipped." "INFO"
                    $summary[$row.SafeName].MembersSkipped++
                    $summary[$row.SafeName].Logs += "Member already in safe."
                }
                else {
                    $msg = "$logPrefix - Failed to add to safe: $_"
                    $summary[$row.SafeName].Errors++
                    $summary[$row.SafeName].Logs += $msg
                    Write-Log $msg "ERROR"
                }
            }
        }
        else {
            # User
            try {
                # Handle PSCustomObject lookup for permissions
                $perms = $null
                if ($config.SafePermissionSets.PSObject.Properties.Match($row.PermissionKey)) {
                    $perms = $config.SafePermissionSets.$($row.PermissionKey)
                }
                    
                if (-not $perms) {
                    Write-Log "$logPrefix - Permission Set '$($row.PermissionKey)' not found in config." "WARN"
                    $summary[$row.SafeName].Logs += "Permission Set '$($row.PermissionKey)' not found."
                    continue
                }

                $permParams = @{}
                foreach ($p in $perms) { $permParams[$p] = $true }

                Add-PASSafeMember -SafeName $row.SafeName -MemberName $row.SafeMember @permParams -ErrorAction Stop
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
                    $msg = "$logPrefix - Failed to add user: $_"
                    $summary[$row.SafeName].Errors++
                    $summary[$row.SafeName].Logs += $msg
                    Write-Log $msg "ERROR"
                }
            }
        }
    }
    catch {
        $msg = "$logPrefix - Unexpected error: $_"
        $summary[$row.SafeName].Errors++
        $summary[$row.SafeName].Logs += $msg
        Write-Log $msg "ERROR"
    }
}

# -------------------------------
# Write summary CSV
# -------------------------------
$summaryPath = Join-Path $baseDir "$baseName-summary.csv"
$summary.Values | Select-Object SafeName, SafeCreated, MembersAdded, MembersSkipped, Errors |
Export-Csv $summaryPath -NoTypeInformation -Encoding UTF8

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
