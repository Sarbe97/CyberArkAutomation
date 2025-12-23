# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: Functions for Managing CyberArk Safes via psPAS
# FEATURES: Progress Bars, Detailed Permission Flattening, CSV Reporting
# ============================================================================

# ============================================================================
# HELPER: Flatten Safe Member Permissions
# Converts the nested psPAS permission object into flat CSV columns
# ============================================================================
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj
    )

    # 1. Identify where the permissions are stored based on API version/response type
    $perms = $null
    if ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions -is [System.Collections.IDictionary]) {
        $perms = $MemberObj.Permissions
    }
    elseif ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions -is [object]) {
        $perms = $MemberObj.Permissions
    }
    else {
        $perms = $MemberObj
    }

    # 2. Return a flat object with explicit columns for every permission
    return [PSCustomObject]@{
        SafeName                       = $SafeName
        MemberName                     = $MemberObj.MemberName
        MemberType                     = $MemberObj.MemberType
        MembershipExpirationDate       = $MemberObj.MembershipExpirationDate

        # --- Standard Permissions ---
        UseAccounts                    = [bool]$perms['UseAccounts']
        RetrieveAccounts               = [bool]$perms['RetrieveAccounts']
        ListAccounts                   = [bool]$perms['ListAccounts']
        AddAccounts                    = [bool]$perms['AddAccounts']
        UpdateAccountContent           = [bool]$perms['UpdateAccountContent']
        UpdateAccountProperties        = [bool]$perms['UpdateAccountProperties']
        InitiateCPMAccountManagementOperations = [bool]$perms['InitiateCPMAccountManagementOperations']
        SpecifyNextAccountContent      = [bool]$perms['SpecifyNextAccountContent']
        RenameAccounts                 = [bool]$perms['RenameAccounts']
        DeleteAccounts                 = [bool]$perms['DeleteAccounts']
        MoveAccounts                   = [bool]$perms['MoveAccounts']
        
        # --- Administrative Permissions ---
        ManageSafe                     = [bool]$perms['ManageSafe']
        ManageSafeMembers              = [bool]$perms['ManageSafeMembers']
        BackupSafe                     = [bool]$perms['BackupSafe']
        ViewAuditLog                   = [bool]$perms['ViewAuditLog']
        ViewSafeMembers                = [bool]$perms['ViewSafeMembers']
        AccessSafeWithoutConfirmation  = [bool]$perms['AccessSafeWithoutConfirmation']
        
        # --- Folder Permissions ---
        CreateFolders                  = [bool]$perms['CreateFolders']
        DeleteFolders                  = [bool]$perms['DeleteFolders']
        MoveFolders                    = [bool]$perms['MoveFolders']
        
        # --- Advanced ---
        UnlockAccounts                 = [bool]$perms['UnlockAccounts']
        RequestsAuthorizationLevel1    = [bool]$perms['RequestsAuthorizationLevel1']
        RequestsAuthorizationLevel2    = [bool]$perms['RequestsAuthorizationLevel2']
    }
}

# =========================================================
# 1. Export ALL Safes
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    
    # Initial Progress for API Call
    Write-Progress -Activity "Fetching Safes" -Status "Querying Vault (this may take time)..." -PercentComplete 0
    Write-Log "Fetching all safes using Get-PASSafe" "INFO"

    try {
        $safes = Get-PASSafe
        Write-Progress -Activity "Fetching Safes" -Completed

        if (-not $safes -or $safes.Count -eq 0) {
            Write-Log "No safes returned" "WARN"
            Write-Host "No safes found." -ForegroundColor Yellow
            return
        }

        $totalSafes = $safes.Count
        Write-Log "Total safes retrieved: $totalSafes" "INFO"
        Write-Host "Processing $totalSafes safes..." -ForegroundColor Cyan

        # Setup Output
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

        $formatted = @()
        $successCount = 0
        $errorCount = 0
        $i = 0

        foreach ($safe in $safes) {
            $i++
            $percent = ($i / $totalSafes) * 100
            
            # --- PROGRESS BAR ---
            Write-Progress -Activity "Exporting Safes" `
                -Status "Processing $i of $totalSafes : $($safe.safeName)" `
                -PercentComplete $percent

            try {
                Write-Log "Processing safe $i/$totalSafes: $($safe.safeName)" "DEBUG"
                $formattedSafe = Format-CACSafe -Safe $safe

                if ($formattedSafe) {
                    $formatted += $formattedSafe
                    $successCount++
                }
                else {
                    $errorCount++
                    Write-Log "Format-CACSafe returned null for safe: $($safe.safeName)" "WARN"
                }
            }
            catch {
                $errorCount++
                Write-Log "Error processing safe $($safe.safeName): $($_.Exception.Message)" "ERROR"
            }
        }
        Write-Progress -Activity "Exporting Safes" -Completed

        # Export
        if ($formatted.Count -gt 0) {
            $outputFile = "$outputDir/all_safes_$timestamp.csv"
            Write-Log "Exporting to CSV: $outputFile" "INFO"
            $formatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export Successful: $outputFile" -ForegroundColor Green
        }
        else {
            Write-Host "No data to export." -ForegroundColor Yellow
        }

        # Summary
        Write-Host "Summary: Success [$successCount] | Errors [$errorCount]" -ForegroundColor Cyan
    }
    catch {
        Write-Log "Error during Export-CACAllSafes(): $($_.Exception.Message)" "ERROR"
        throw
    }
}

# =========================================================
# 2. Search Safe by Name
# =========================================================
function Search-CACSafeByName {
    param( [Parameter(Mandatory)][string]$SafeName )

    Write-Log "Search-CACSafeByName() started for: $SafeName" "INFO"
    Write-Host "Searching for safe '$SafeName'..." -ForegroundColor Cyan

    try {
        $resp = Get-PASSafe -SafeName $SafeName
        
        if (-not $resp) {
            Write-Host "Safe not found!" -ForegroundColor Yellow
            return
        }

        Write-Host "Safe found. Formatting..." -ForegroundColor Cyan
        $formatted = Format-CACSafe -Safe $resp

        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

        $file = "$outputDir/search_safe_${SafeName}.csv"
        $formatted | Export-Csv -Path $file -NoTypeInformation

        Write-Log "Export completed: $file" "SUCCESS"
        Write-Host "Exported to: $file" -ForegroundColor Green
    }
    catch {
        Write-Log "Error searching safe '$SafeName': $($_.Exception.Message)" "ERROR"
        throw
    }
}

# ============================================================
# 3. Export Safe Members (WITH FLATTENED PERMISSIONS)
# ============================================================
function Export-CACSafeMembers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeMembers()" "DEBUG"

    Write-Host "Choose Input Mode:" -ForegroundColor Cyan
    Write-Host "1 = Enter safe names manually"
    Write-Host "2 = Load safe names from CSV (Column: SafeName)"
    $mode = Read-Host "Enter option (1 or 2)"

    switch ($mode) {
        '1' {
            $safeNames = (Read-Host "Enter safe names (comma separated)") -split "," | ForEach-Object { $_.Trim() }
            $outputToCsv = $false
        }
        '2' {
            $csvPath = Read-Host "Enter full CSV path"
            if (!(Test-Path $csvPath)) { Write-Host "CSV not found!"; return }
            $safeNames = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
            $inputPath = Split-Path -Path $csvPath -Parent
            $outputToCsv = $true
        }
        default { return }
    }

    $rows = @()
    $totalSafes = $safeNames.Count
    $currentSafeIndex = 0

    foreach ($safeName in $safeNames) {
        $currentSafeIndex++
        $pct = ($currentSafeIndex / $totalSafes) * 100
        
        # --- PROGRESS BAR ---
        Write-Progress -Activity "Fetching Safe Permissions" `
            -Status "Safe $currentSafeIndex of $totalSafes : $safeName" `
            -PercentComplete $pct

        Write-Log "Processing safe: $safeName" "INFO"

        try {
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
        }
        catch {
            Write-Log "Failed to fetch members for '$safeName': $($_.Exception.Message)" "ERROR"
            continue
        }

        if ($members) {
            foreach ($member in $members) {
                # USE THE HELPER FUNCTION HERE TO FLATTEN PERMISSIONS
                $row = New-CACSafeMemberDetailedRow -SafeName $safeName -MemberObj $member
                $rows += $row
            }
        }
    }
    Write-Progress -Activity "Fetching Safe Permissions" -Completed

    if ($rows.Count -eq 0) {
        Write-Host "No members found." -ForegroundColor Yellow
        return
    }

    if ($outputToCsv) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFileName = "safe_members_detailed_$timestamp.csv"
        $outputPath = Join-Path -Path $inputPath -ChildPath $outputFileName
        
        Write-Host "Exporting CSV..." -ForegroundColor Cyan
        $rows | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Done: $outputPath" -ForegroundColor Green
    }
    else {
        # Using GridView because detailed permissions are too wide for the console
        $rows | Out-GridView -Title "Safe Member Permissions"
    }
}

# ============================================================
# 4. Export Safe Users (NESTED PROGRESS)
# ============================================================
function Export-CACSafeUsers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeUsers()" "DEBUG"

    Write-Host "Choose Input Mode:" -ForegroundColor Cyan
    Write-Host "1 = Manual Entry"
    Write-Host "2 = CSV Input"
    $mode = Read-Host "Enter option (1 or 2)"

    switch ($mode) {
        '1' {
            $safeNames = (Read-Host "Enter safe names (comma separated)") -split "," | ForEach-Object { $_.Trim() }
            $outputToCsv = $false
        }
        '2' {
            $csvPath = Read-Host "Enter full CSV path"
            if (!(Test-Path $csvPath)) { Write-Host "CSV not found!"; return }
            $safeNames = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
            $outputToCsv = $true
            $outCsv = Read-Host "Enter output CSV path"
        }
        default { return }
    }

    $rows = @()
    $totalSafes = $safeNames.Count
    $safeIndex = 0

    foreach ($safeName in $safeNames) {
        $safeIndex++
        $safePct = ($safeIndex / $totalSafes) * 100

        # --- OUTER PROGRESS ---
        Write-Progress -Id 1 -Activity "Processing Safes" `
            -Status "Safe $safeIndex of $totalSafes : $safeName" `
            -PercentComplete $safePct

        try {
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
        }
        catch { continue }

        if ($members) {
            $totalMembers = $members.Count
            $memIndex = 0

            foreach ($member in $members) {
                $memIndex++
                $memPct = ($memIndex / $totalMembers) * 100

                # --- INNER PROGRESS ---
                Write-Progress -Id 2 -ParentId 1 -Activity "Resolving Users" `
                    -Status "Member: $($member.MemberName)" `
                    -PercentComplete $memPct

                if ($member.MemberType -eq "User") {
                    $userDetails = Get-CACUserDetailsFromStore -InputValue $member.MemberName
                    $rows += New-CACSafeUserRow -SafeName $safeName -SafeMember $member.MemberName -UserObj $userDetails
                }
                elseif ($member.MemberType -eq "Group") {
                    $groupMembers = Get-CACGroupUsers -GroupName $member.MemberName
                    if ($groupMembers) {
                        foreach ($groupMember in $groupMembers) {
                            $userDetails = Get-CACUserDetailsFromStore -InputValue $groupMember.Id
                            $rows += New-CACSafeUserRow -SafeName $safeName -SafeMember $member.MemberName -UserObj $userDetails
                        }
                    }
                }
            }
        }
    }
    Write-Progress -Id 2 -Completed
    Write-Progress -Id 1 -Completed

    if ($rows.Count -eq 0) {
        Write-Host "No users found." -ForegroundColor Yellow
        return
    }

    if ($outputToCsv) {
        $rows | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Export completed: $outCsv" -ForegroundColor Green
    }
    else {
        $rows | Format-Table -AutoSize
    }
}

# ---------------------------------------------------------
# 5. Create Safes
# ---------------------------------------------------------
function New-CACSafe {
    Write-Host "Choose mode: 1. Manual, 2. CSV"
    $mode = Read-Host "Enter choice"
    $safeData = @()

    if ($mode -eq "1") {
        $safeData += [PSCustomObject]@{
            SafeName = Read-Host "Safe Name"
            Description = Read-Host "Description"
            ManagingCPM = Read-Host "Managing CPM"
        }
    }
    elseif ($mode -eq "2") {
        $csvPath = Read-Host "CSV Path"
        if (Test-Path $csvPath) { $safeData = Import-Csv $csvPath }
    }

    $total = $safeData.Count
    $i = 0
    foreach ($safe in $safeData) {
        $i++
        $pct = ($i / $total) * 100
        Write-Progress -Activity "Creating Safes" -Status "Creating $($safe.SafeName)" -PercentComplete $pct

        try {
            Add-PASSafe -SafeName $safe.SafeName -Description $safe.Description -ManagingCPM $safe.ManagingCPM -ErrorAction Stop
            Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
        }
        catch {
            Write-Log "Error creating $($safe.SafeName): $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Progress -Activity "Creating Safes" -Completed
}

# ---------------------------------------------------------
# 6. Add Safe Members
# ---------------------------------------------------------
function Add-CACSafeMember {
    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    Write-Host "Choose mode: 1. Manual, 2. CSV"
    $mode = Read-Host "Enter choice"
    $entries = @()

    if ($mode -eq "1") {
        $safe = Read-Host "Safe Name"
        $member = Read-Host "Member Name"
        $i=1; foreach($k in $permissionSets.Keys){Write-Host "$i. $k"; $i++}
        $sel = Read-Host "Select perm set"
        $permKey = $permissionSets.Keys[[int]$sel - 1]
        $entries += [PSCustomObject]@{SafeName=$safe; Member=$member; PermissionKey=$permKey}
    }
    elseif ($mode -eq "2") {
        $csvPath = Read-Host "CSV Path"
        if (Test-Path $csvPath) { $entries = Import-Csv $csvPath }
    }

    $total = $entries.Count
    $i = 0
    foreach ($e in $entries) {
        $i++
        $pct = ($i / $total) * 100
        Write-Progress -Activity "Adding Safe Members" -Status "Adding $($e.Member) to $($e.SafeName)" -PercentComplete $pct

        $permissions = $permissionSets[$e.PermissionKey]
        if ($permissions) {
            try {
                Add-PASSafeMember -SafeName $e.SafeName -MemberName $e.Member -SearchInVault $true -Permissions $permissions -ErrorAction Stop
                Write-Log "Member added: $($e.Member) -> $($e.SafeName)" "SUCCESS"
            }
            catch {
                Write-Log "Error adding member $($e.Member): $($_.Exception.Message)" "ERROR"
            }
        }
    }
    Write-Progress -Activity "Adding Safe Members" -Completed
}

# Export module members
Export-ModuleMember -Function `
    Export-CACAllSafes, `
    Search-CACSafeByName, `
    Export-CACSafeMembers, `
    Export-CACSafeUsers, `
    New-CACSafe, `
    Add-CACSafeMember
    
