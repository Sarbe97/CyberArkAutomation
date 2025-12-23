
# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: CyberArk Safe Management (Progress Bars + Fixed Permissions)
# ============================================================================

# ----------------------------------------------------------------------------
# HELPER: Flatten Safe Member Permissions (FIXED)
# ----------------------------------------------------------------------------
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj
    )

    # 1. Locate the permissions data
    $perms = $null
    if ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions) {
        $perms = $MemberObj.Permissions
    } else {
        $perms = $MemberObj
    }

    # 2. Local Helper to extract bool safely from Object OR Hashtable
    function Get-Perm ($obj, $name) {
        if ($obj.PSObject.Properties.Match($name)) { return [bool]$obj.$name }
        if ($obj -is [System.Collections.IDictionary] -and $obj.Contains($name)) { return [bool]$obj[$name] }
        return $false
    }

    # 3. Return Flat Object
    return [PSCustomObject]@{
        SafeName                       = $SafeName
        MemberName                     = $MemberObj.MemberName
        MemberType                     = $MemberObj.MemberType
        ExpirationDate                 = $MemberObj.MembershipExpirationDate

        # Permissions
        UseAccounts                    = Get-Perm $perms "UseAccounts"
        RetrieveAccounts               = Get-Perm $perms "RetrieveAccounts"
        ListAccounts                   = Get-Perm $perms "ListAccounts"
        AddAccounts                    = Get-Perm $perms "AddAccounts"
        UpdateAccountContent           = Get-Perm $perms "UpdateAccountContent"
        UpdateAccountProperties        = Get-Perm $perms "UpdateAccountProperties"
        InitiateCPMOps                 = Get-Perm $perms "InitiateCPMAccountManagementOperations"
        SpecifyNextAccountContent      = Get-Perm $perms "SpecifyNextAccountContent"
        RenameAccounts                 = Get-Perm $perms "RenameAccounts"
        DeleteAccounts                 = Get-Perm $perms "DeleteAccounts"
        MoveAccounts                   = Get-Perm $perms "MoveAccounts"
        ManageSafe                     = Get-Perm $perms "ManageSafe"
        ManageSafeMembers              = Get-Perm $perms "ManageSafeMembers"
        BackupSafe                     = Get-Perm $perms "BackupSafe"
        ViewAuditLog                   = Get-Perm $perms "ViewAuditLog"
        ViewSafeMembers                = Get-Perm $perms "ViewSafeMembers"
        AccessSafeWithoutConfirmation  = Get-Perm $perms "AccessSafeWithoutConfirmation"
        CreateFolders                  = Get-Perm $perms "CreateFolders"
        DeleteFolders                  = Get-Perm $perms "DeleteFolders"
        MoveFolders                    = Get-Perm $perms "MoveFolders"
        UnlockAccounts                 = Get-Perm $perms "UnlockAccounts"
    }
}

# =========================================================
# 1. Export ALL Safes
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes" "DEBUG"
    Write-Progress -Activity "Fetching Safes" -Status "Querying Vault..." -PercentComplete 0
    
    try {
        $safes = Get-PASSafe
        Write-Progress -Activity "Fetching Safes" -Completed

        if (-not $safes) { Write-Host "No safes found." -ForegroundColor Yellow; return }

        $total = $safes.Count
        Write-Host "Processing $total safes..." -ForegroundColor Cyan
        
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
        
        $formatted = @()
        $i = 0

        foreach ($safe in $safes) {
            $i++
            $pct = ($i / $total) * 100
            Write-Progress -Activity "Exporting Safes" -Status "Processing $i of $total : $($safe.safeName)" -PercentComplete $pct

            try { $formatted += Format-CACSafe -Safe $safe } catch {}
        }
        Write-Progress -Activity "Exporting Safes" -Completed

        if ($formatted.Count -gt 0) {
            $file = "$outputDir/all_safes_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            $formatted | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
            Write-Host "Success: $file" -ForegroundColor Green
        }
    }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

# =========================================================
# 2. Search Safe
# =========================================================
function Search-CACSafeByName {
    param([string]$SafeName)
    Write-Host "Searching..." -ForegroundColor Cyan
    try {
        $s = Get-PASSafe -SafeName $SafeName
        if ($s) {
            $out = "$PSScriptRoot/../Output/search_$SafeName.csv"
            Format-CACSafe -Safe $s | Export-Csv $out -NoTypeInformation
            Write-Host "Found & Exported: $out" -ForegroundColor Green
        } else { Write-Host "Not Found" -ForegroundColor Yellow }
    } catch { Write-Host "Error: $_" -ForegroundColor Red }
}

# =========================================================
# 3. Export Safe Members (Uses NEW Helper)
# =========================================================
function Export-CACSafeMembers {
    [CmdletBinding()]
    param()

    Write-Host "1. Manual List | 2. CSV Input" -ForegroundColor Cyan
    $mode = Read-Host "Choice"
    if ($mode -eq '1') { $safes = (Read-Host "Safe Names (comma)") -split "," | ForEach { $_.Trim() }; $toCsv=$false }
    elseif ($mode -eq '2') { $p = Read-Host "CSV Path"; $safes = (Import-Csv $p).SafeName; $toCsv=$true; $parent = Split-Path $p -Parent }
    else { return }

    $rows = @()
    $total = $safes.Count
    $i = 0

    foreach ($s in $safes) {
        $i++
        Write-Progress -Activity "Safe Members" -Status "Safe $i/$total : $s" -PercentComplete (($i/$total)*100)
        try {
            $mems = Get-PASSafeMember -SafeName $s -ErrorAction Stop
            if ($mems) {
                foreach ($m in $mems) {
                    $rows += New-CACSafeMemberDetailedRow -SafeName $s -MemberObj $m
                }
            }
        } catch {}
    }
    Write-Progress -Activity "Safe Members" -Completed

    if ($rows.Count -eq 0) { Write-Host "No members found." -ForegroundColor Yellow; return }

    if ($toCsv) {
        $out = Join-Path $parent "safe_members_detailed_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $rows | Export-Csv $out -NoTypeInformation -Encoding UTF8
        Write-Host "Exported: $out" -ForegroundColor Green
    } else {
        $rows | Out-GridView -Title "Safe Permissions"
    }
}

# =========================================================
# 4. Export Safe Users (Nested Progress)
# =========================================================
function Export-CACSafeUsers {
    Write-Host "1. Manual | 2. CSV" -ForegroundColor Cyan
    $mode = Read-Host "Choice"
    if ($mode -eq '1') { $safes = (Read-Host "Safe Names") -split ","; $toCsv=$false }
    elseif ($mode -eq '2') { $p = Read-Host "CSV Path"; $safes = (Import-Csv $p).SafeName; $toCsv=$true; $outCsv = Read-Host "Output CSV Path" }
    
    $rows = @()
    $i = 0; $total = $safes.Count

    foreach ($s in $safes) {
        $i++
        Write-Progress -Id 1 -Activity "Safes" -Status "$s" -PercentComplete (($i/$total)*100)
        
        try {
            $mems = Get-PASSafeMember -SafeName $s -ErrorAction Stop
            $j=0; $mTotal = $mems.Count
            foreach ($m in $mems) {
                $j++
                Write-Progress -Id 2 -ParentId 1 -Activity "Users" -Status "$($m.MemberName)" -PercentComplete (($j/$mTotal)*100)
                
                if ($m.MemberType -eq "User") {
                    $u = Get-CACUserDetailsFromStore -InputValue $m.MemberName
                    $rows += New-CACSafeUserRow -SafeName $s -SafeMember $m.MemberName -UserObj $u
                } elseif ($m.MemberType -eq "Group") {
                    $gUsers = Get-CACGroupUsers -GroupName $m.MemberName
                    foreach ($gu in $gUsers) {
                        $u = Get-CACUserDetailsFromStore -InputValue $gu.Id
                        $rows += New-CACSafeUserRow -SafeName $s -SafeMember $m.MemberName -UserObj $u
                    }
                }
            }
        } catch {}
    }
    Write-Progress -Id 2 -Completed; Write-Progress -Id 1 -Completed

    if ($toCsv) { $rows | Export-Csv $outCsv -NoTypeInformation; Write-Host "Done" -ForegroundColor Green }
    else { $rows | Format-Table -AutoSize }
}

# =========================================================
# 5. Create Safes
# =========================================================
function New-CACSafe {
    Write-Host "1. Manual | 2. CSV"
    if ((Read-Host) -eq '2') {
        $data = Import-Csv (Read-Host "CSV Path")
        $i=0; $t=$data.Count
        foreach ($s in $data) {
            $i++
            Write-Progress -Activity "Creating" -Status "$($s.SafeName)" -PercentComplete (($i/$t)*100)
            try { Add-PASSafe -SafeName $s.SafeName -Description $s.Description -ManagingCPM $s.ManagingCPM -ErrorAction Stop } catch {}
        }
        Write-Progress -Activity "Creating" -Completed
    }
}

# =========================================================
# 6. Add Members
# =========================================================
function Add-CACSafeMember {
    $conf = Get-CACConfig
    Write-Host "1. Manual | 2. CSV"
    if ((Read-Host) -eq '2') {
        $data = Import-Csv (Read-Host "CSV Path")
        $i=0; $t=$data.Count
        foreach ($e in $data) {
            $i++
            Write-Progress -Activity "Adding Members" -Status "$($e.Member) -> $($e.SafeName)" -PercentComplete (($i/$t)*100)
            if ($conf.SafePermissionSets[$e.PermissionKey]) {
                try { Add-PASSafeMember -SafeName $e.SafeName -MemberName $e.Member -SearchInVault $true -Permissions $conf.SafePermissionSets[$e.PermissionKey] -ErrorAction Stop } catch {}
            }
        }
        Write-Progress -Activity "Adding Members" -Completed
    }
}

# =========================================================
# 7. Safe Account Counts
# =========================================================
function Export-CACSafeAccountCounts {
    Write-Progress -Activity "Inventory" -Status "Fetching Safes..." -PercentComplete 0
    try { $safes = Get-PASSafe -ErrorAction Stop } catch { return }

    $res = @()
    $i = 0; $t = $safes.Count
    
    foreach ($s in $safes) {
        $i++
        Write-Progress -Activity "Account Scan" -Status "Safe $i/$t : $($s.SafeName)" -PercentComplete (($i/$t)*100)
        
        $count = 0
        try { $a = Get-PASAccount -SafeName $s.SafeName -ErrorAction SilentlyContinue; if($a){$count=$a.Count} } catch {}
        
        $res += [PSCustomObject]@{
            SafeName = $s.SafeName
            AccountCount = $count
            Description = $s.Description
            CPM = $s.ManagingCPM
        }
    }
    Write-Progress -Activity "Account Scan" -Completed

    $out = "$PSScriptRoot/../Output/safe_counts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $res | Export-Csv $out -NoTypeInformation -Encoding UTF8
    Write-Host "Scan Complete: $out" -ForegroundColor Green
}



Export-ModuleMember -Function Export-CACAllSafes, Search-CACSafeByName, Export-CACSafeMembers, Export-CACSafeUsers, New-CACSafe, Add-CACSafeMember, Export-CACSafeAccountCounts
