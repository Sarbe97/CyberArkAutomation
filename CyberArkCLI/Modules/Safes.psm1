# ==========================
# Safes.psm1
# ==========================

# =========================================================
# 1. Export ALL Safes (native PAS pagination)
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    Write-Log "Fetching all safes using Get-PASSafe" "INFO"

    try {
        Write-Log "Calling Get-PASSafe" "DEBUG"
        $resp = Get-PASSafe

        if (-not $resp.value) {
            Write-Log "No safes returned" "WARN"
            return
        }

        Write-Log "Total safes returned: $($resp.value.Count)" "INFO"

        $formatted = $resp.value | ForEach-Object { Set-CACSafe $_ }

        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $outputFile = "$outputDir/all_safes.csv"
        Write-Log "Exporting safe details to: $outputFile" "INFO"
        $formatted | Export-Csv -Path $outputFile -NoTypeInformation

        Write-Log "Export complete: $outputFile" "SUCCESS"
    }
    catch {
        Write-Log "Error during Export-CACAllSafes(): $($_.Exception.Message)" "ERROR"
        throw
    }

    Write-Log "Completed Export-CACAllSafes()" "DEBUG"
}

# =========================================================
# 2. Search Safe by Name → CSV Output
# =========================================================
function Search-CACSafeByName {
    param(
        [Parameter(Mandatory)]
        [string]$SafeName
    )

    Write-Log "Search-CACSafeByName() started for Safe: $SafeName" "INFO"

    try {
        Write-Log "Calling Get-PASSafe -SafeName $SafeName" "DEBUG"
        $resp = Get-PASSafe -SafeName $SafeName
        Write-Host "$resp"
        if (-not $resp) {
            Write-Log "Safe '$SafeName' not found" "WARN"
            Write-Host "Safe not found!" -ForegroundColor Yellow
            return
        }

        Write-Log "Safe object received. Formatting..." "DEBUG"
        $formatted = Set-CACSafe -Safe $resp

        # Ensure output directory
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created" "DEBUG"
        }

        $file = "$outputDir/search_safe_${SafeName}.csv"
        Write-Log "Saving search results to: $file" "INFO"

        $formatted | Export-Csv -Path $file -NoTypeInformation

        Write-Log "Safe search export completed successfully  $file" "SUCCESS"
    }
    catch {
        Write-Log "Error searching safe '$SafeName': $($_.Exception.Message)" "ERROR"
        throw
    }
}
 


# --------------------------------------------------
# Export Safe Members (Users + Groups)
# --------------------------------------------------

# ============================================================
# Export Safe Members WITH PERMISSIONS (Direct from psPAS)
# ============================================================
function Export-CACSafeMembers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeMembers()" "DEBUG"

    Write-Host "Choose Input Mode:" -ForegroundColor Cyan
    Write-Host "1 = Enter safe names manually (comma separated)"
    Write-Host "2 = Load safe names from CSV (column: SafeName)"
    $mode = Read-Host "Enter option (1 or 2)"

    switch ($mode) {

        '1' {
            $safeNames = (Read-Host "Enter safe names (comma separated)") -split "," | ForEach-Object { $_.Trim() }
            $outputToCsv = $false
        }

        '2' {
            $csvPath = Read-Host "Enter full CSV path"
            if (!(Test-Path $csvPath)) { 
                Write-Host "CSV not found!" -ForegroundColor Red
                Write-Log "Input CSV not found: $csvPath" "ERROR"
                return 
            }

            $safeNames = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
            $outputToCsv = $true
            $outCsv = Read-Host "Enter output CSV path"
        }

        default { 
            Write-Host "Invalid option." -ForegroundColor Red
            Write-Log "Invalid mode selected" "WARN"
            return 
        }
    }

    $rows = @()

    foreach ($safeName in $safeNames) {

        Write-Log "Processing safe: $safeName" "INFO"

        try {
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
        }
        catch {
            Write-Host "Error fetching members for '$safeName' - $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Failed to fetch members for '$safeName' : $($_.Exception.Message)" "ERROR"
            continue
        }

        if (-not $members) {
            Write-Log "No members found for safe: $safeName" "WARN"
            continue
        }

        foreach ($member in $members) {

            Write-Log "Processing member: $($member.MemberName) (Type: $($member.MemberType))" "DEBUG"

            # Create row with all permissions directly from psPAS response
            $row = New-CACSafeMemberRowWithPermissions -SafeName $safeName -MemberObj $member
            $rows += $row
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host "No members found for the specified safes." -ForegroundColor Yellow
        Write-Log "No safe members found" "WARN"
        return
    }

    # Export or display results
    if ($outputToCsv) {
        Write-Log "Exporting $($rows.Count) members to CSV: $outCsv" "INFO"
        $rows | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Export completed: $outCsv" -ForegroundColor Green
        Write-Log "Safe members exported successfully to: $outCsv" "SUCCESS"
    }
    else {
        Write-Host "`n--- SAFE MEMBERS WITH PERMISSIONS ---" -ForegroundColor Yellow
        Write-Host "Total members found: $($rows.Count)" -ForegroundColor Cyan
        Write-Host ""
        $rows | Format-Table -AutoSize
    }

    Write-Log "Completed Export-CACSafeMembers()" "DEBUG"
}





# ============================================================
# Export Safe Users (Users from Safes + Groups, with Details)
# ============================================================
function Export-CACSafeUsers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeUsers()" "DEBUG"

    Write-Host "Choose Input Mode:" -ForegroundColor Cyan
    Write-Host "1 = Enter safe names manually (comma separated)"
    Write-Host "2 = Load safe names from CSV (column: SafeName)"
    $mode = Read-Host "Enter option (1 or 2)"

    switch ($mode) {

        '1' {
            $safeNames = (Read-Host "Enter safe names (comma separated)") -split "," | ForEach-Object { $_.Trim() }
            $outputToCsv = $false
        }

        '2' {
            $csvPath = Read-Host "Enter full CSV path"
            if (!(Test-Path $csvPath)) { 
                Write-Host "CSV not found!" -ForegroundColor Red
                Write-Log "Input CSV not found: $csvPath" "ERROR"
                return 
            }

            $safeNames = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
            $outputToCsv = $true
            $outCsv = Read-Host "Enter output CSV path"
        }

        default { 
            Write-Host "Invalid option." -ForegroundColor Red
            Write-Log "Invalid mode selected" "WARN"
            return 
        }
    }

    $rows = @()

    foreach ($safeName in $safeNames) {

        Write-Log "Processing safe: $safeName" "INFO"

        try {
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
        }
        catch {
            Write-Host "Error retrieving members for '$safeName' - $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Failed to fetch members for '$safeName' : $($_.Exception.Message)" "ERROR"
            continue
        }

        if (-not $members) {
            Write-Log "No members found for safe: $safeName" "WARN"
            continue
        }

        foreach ($member in $members) {

            Write-Log "Processing member: $($member.MemberName) (Type: $($member.MemberType))" "DEBUG"

            # If member is a User
            if ($member.MemberType -eq "User") {

                Write-Log "Fetching user details for: $($member.MemberName)" "DEBUG"

                # Get user details from cache using MemberName (the user identifier)
                $userDetails = Get-CACUserDetailsFromStore -InputValue $member.MemberName

                # Create row with safe name, safe member (the user name), and user details
                $row = New-CACSafeUserRow `
                    -SafeName $safeName `
                    -SafeMember $member.MemberName `
                    -UserObj $userDetails

                $rows += $row
            }

            # If member is a Group
            elseif ($member.MemberType -eq "Group") {

                Write-Log "Fetching group members for group: $($member.MemberName)" "DEBUG"

                # Get all users in the group (returns user objects with Id and UserName)
                $groupMembers = Get-CACGroupUsers -GroupName $member.MemberName

                if ($groupMembers) {
                    foreach ($groupMember in $groupMembers) {

                        Write-Log "Processing group member: $($groupMember.UserName) (Id: $($groupMember.Id))" "DEBUG"

                        # Get user details from cache using the user ID (preferred method)
                        $userDetails = Get-CACUserDetailsFromStore -InputValue $groupMember.Id

                        # Create row with safe name, safe member (the group name), and user details
                        $row = New-CACSafeUserRow `
                            -SafeName $safeName `
                            -SafeMember $member.MemberName `
                            -UserObj $userDetails

                        $rows += $row
                    }
                }
                else {
                    Write-Log "No users found in group: $($member.MemberName)" "WARN"
                }
            }
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host "No users found for the specified safes." -ForegroundColor Yellow
        Write-Log "No safe users found" "WARN"
        return
    }

    # Export or display results
    if ($outputToCsv) {
        Write-Log "Exporting $($rows.Count) users to CSV: $outCsv" "INFO"
        $rows | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Export completed: $outCsv" -ForegroundColor Green
        Write-Log "Safe users exported successfully to: $outCsv" "SUCCESS"
    }
    else {
        Write-Host "`n--- SAFE USERS WITH DETAILS ---" -ForegroundColor Yellow
        Write-Host "Total users found: $($rows.Count)" -ForegroundColor Cyan
        Write-Host ""
        $rows | Format-Table -AutoSize
    }

    Write-Log "Completed Export-CACSafeUsers()" "DEBUG"
}



# ---------------------------------------------------------
# Create Safes
# ---------------------------------------------------------
function New-CACSafe {
    Write-Log "Started New-CACSafe()" "DEBUG"

    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV"
    $mode = Read-Host "Enter choice"

    $safeData = @()

    switch ($mode) {
        "1" {
            $safeName = Read-Host "Safe Name"
            $desc = Read-Host "Description"
            $cpm = Read-Host "Managing CPM"
            if (-not $cpm) { $cpm = "" }

            $safeData += [PSCustomObject]@{
                SafeName    = $safeName
                Description = $desc
                ManagingCPM = $cpm
            }
        }

        "2" {
            $csvPath = Read-Host "CSV Path"
            if (-not (Test-Path $csvPath)) {
                Write-Log "CSV missing: $csvPath" "ERROR"
                return
            }
            $safeData = Import-Csv $csvPath
        }

        default {
            Write-Log "Invalid mode selected" "WARN"
            return
        }
    }

    foreach ($safe in $safeData) {
        Write-Log "Creating safe: $($safe.SafeName)" "INFO"

        try {
            Add-PASSafe -SafeName $safe.SafeName `
                -Description $safe.Description `
                -ManagingCPM $safe.ManagingCPM -ErrorAction Stop

            Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
        }
        catch {
            Write-Log "Error creating safe $($safe.SafeName): $($_.Exception.Message)" "ERROR"
        }
    }

    Write-Log "Completed New-CACSafe()" "DEBUG"
}

# ---------------------------------------------------------
# Add Safe Member(s)
# ---------------------------------------------------------
function Add-CACSafeMember {
    Write-Log "Started Add-CACSafeMember()" "DEBUG"

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    Write-Log "Loaded permission sets" "DEBUG"

    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV"
    $mode = Read-Host "Enter choice"

    $entries = @()

    switch ($mode) {
        "1" {
            $safe = Read-Host "Safe Name"
            $member = Read-Host "Member Name"

            Write-Host "Permission Sets:"
            $i = 1
            foreach ($key in $permissionSets.Keys) { Write-Host "$i. $key"; $i++ }

            $sel = Read-Host "Select permission set"
            $permKey = $permissionSets.Keys[[int]$sel - 1]

            $entries += [PSCustomObject]@{
                SafeName      = $safe
                Member        = $member
                PermissionKey = $permKey
            }
        }

        "2" {
            $csvPath = Read-Host "CSV Path"
            if (-not (Test-Path $csvPath)) {
                Write-Log "CSV missing: $csvPath" "ERROR"
                return
            }
            $entries = Import-Csv $csvPath
        }
    }

    foreach ($e in $entries) {
        Write-Log "Adding $($e.Member) to $($e.SafeName)" "INFO"

        $permissions = $permissionSets[$e.PermissionKey]
        if (-not $permissions) {
            Write-Log "Invalid permission key: $($e.PermissionKey)" "WARN"
            continue
        }

        try {
            Add-PASSafeMember -SafeName $e.SafeName `
                -MemberName $e.Member `
                -SearchInVault $true `
                -Permissions $permissions -ErrorAction Stop

            Write-Log "Member added: $($e.Member) → $($e.SafeName)" "SUCCESS"
        }
        catch {
            Write-Log "Error adding member $($e.Member): $($_.Exception.Message)" "ERROR"
        }
    }

    Write-Log "Completed Add-CACSafeMember()" "DEBUG"
}

# Export module members
Export-ModuleMember -Function `
    Export-CACAllSafes, `
    Search-CACSafeByName, `
    Export-CACSafeMembers, `
    Export-CACSafeUsers, `
    New-CACSafe, `
    Add-CACSafeMember
