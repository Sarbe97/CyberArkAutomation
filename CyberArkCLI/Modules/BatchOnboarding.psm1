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
            throw "Safe '$($safe.SafeName)' has BOTH retention values. Only one allowed."
        }
        if (-not ($hasVersions -or $hasDays)) {
            throw "Safe '$($safe.SafeName)' must have one retention value."
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
                Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
            }
            else {
                Write-Log "Safe exists: $($safe.SafeName)" "INFO"
            }
        }
        catch {
            $summary[$safe.SafeName].Errors++
            Write-Log "Safe error [$($safe.SafeName)]: $_" "ERROR"
        }
    }

    # -------------------------------
    # Phase 2: Members
    # -------------------------------
    foreach ($row in $members) {
        Init-SafeSummary $row.SafeName

        try {
            if ($row.MemberType -eq "Group") {

                $group = Get-PASGroup -GroupName $row.SafeMember -ErrorAction Ignore
                if (-not $group) {
                    New-PASGroup -GroupName $row.SafeMember -Description "Auto-created" -ErrorAction Stop
                    Write-Log "Group created: $($row.SafeMember)" "INFO"

                    if ($row.Users) {
                        foreach ($u in ($row.Users -split ";")) {
                            Add-PASGroupMember -GroupName $row.SafeMember -MemberName $u.Trim() -ErrorAction Ignore
                        }
                    }
                }

                Add-PASSafeMember `
                    -SafeName $row.SafeName `
                    -MemberName $row.SafeMember `
                    -Permissions (Get-CACConfig).SafePermissionSets.$($row.PermissionKey) `
                    -SearchInVault $true `
                    -ErrorAction Stop

                $summary[$row.SafeName].MembersAdded++
            }
            else {
                Add-PASSafeMember `
                    -SafeName $row.SafeName `
                    -MemberName $row.SafeMember `
                    -Permissions (Get-CACConfig).SafePermissionSets.$($row.PermissionKey) `
                    -SearchInVault $true `
                    -ErrorAction Stop

                $summary[$row.SafeName].MembersAdded++
            }
        }
        catch {
            if ($_.Exception.Message -match "already exists|409") {
                $summary[$row.SafeName].MembersSkipped++
            }
            else {
                $summary[$row.SafeName].Errors++
                Write-Log "Member error [$($row.SafeMember)]: $_" "ERROR"
            }
        }
    }

    # -------------------------------
    # Write summary CSV
    # -------------------------------
    $summaryPath = Join-Path $baseDir "$baseName-summary.csv"
    $summary.Values | Export-Csv $summaryPath -NoTypeInformation

    Write-Host "`nBatch onboarding completed." -ForegroundColor Cyan
    Write-Host "Summary written to: $summaryPath" -ForegroundColor Green
}

Export-ModuleMember -Function Invoke-CACBatchOnboarding
