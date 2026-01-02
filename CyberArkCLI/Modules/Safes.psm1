# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: CyberArk Safe Management
# FEATURES: Consolidated Export, Progress Bars, Deep Logging, Permission Fixes
# ============================================================================

# ----------------------------------------------------------------------------
# HELPER: Flatten Safe Member Permissions
# ----------------------------------------------------------------------------
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj,
        [hashtable]$SafeProps = @{} 
    )

    # 1. Locate Permissions
    $perms = $null
    if ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions) {
        $perms = $MemberObj.Permissions
    }
    else {
        $perms = $MemberObj
    }

    # 2. Local Helper
    function Get-Perm ($obj, $name) {
        if ($obj.PSObject.Properties.Match($name)) { return [bool]$obj.$name }
        if ($obj -is [System.Collections.IDictionary] -and $obj.Contains($name)) { return [bool]$obj[$name] }
        return $false
    }

    # 3. Base Object (Permissions)
    $baseObj = [ordered]@{
        MemberName                  = $MemberObj.MemberName
        MemberType                  = $MemberObj.MemberType
        MembershipExpirationDate    = $MemberObj.MembershipExpirationDate
        
        # Permissions
        UseAccounts                 = Get-Perm $perms "UseAccounts"
        RetrieveAccounts            = Get-Perm $perms "RetrieveAccounts"
        ListAccounts                = Get-Perm $perms "ListAccounts"
        AddAccounts                 = Get-Perm $perms "AddAccounts"
        UpdateAccountContent        = Get-Perm $perms "UpdateAccountContent"
        UpdateAccountProperties     = Get-Perm $perms "UpdateAccountProperties"
        InitiateCPMOps              = Get-Perm $perms "InitiateCPMAccountManagementOperations"
        SpecifyNextAccountContent   = Get-Perm $perms "SpecifyNextAccountContent"
        RenameAccounts              = Get-Perm $perms "RenameAccounts"
        DeleteAccounts              = Get-Perm $perms "DeleteAccounts"
        UnlockAccounts              = Get-Perm $perms "UnlockAccounts"
        MoveAccountsAndFolders      = Get-Perm $perms "MoveAccountsAndFolders"
        AccessWithoutConfirmation   = Get-Perm $perms "AccessWithoutConfirmation"
        ManageSafe                  = Get-Perm $perms "ManageSafe"
        ManageSafeMembers           = Get-Perm $perms "ManageSafeMembers"
        BackupSafe                  = Get-Perm $perms "BackupSafe"
        ViewAuditLog                = Get-Perm $perms "ViewAuditLog"
        ViewSafeMembers             = Get-Perm $perms "ViewSafeMembers"
        CreateFolders               = Get-Perm $perms "CreateFolders"
        DeleteFolders               = Get-Perm $perms "DeleteFolders"
        RequestsAuthorizationLevel1 = Get-Perm $perms "RequestsAuthorizationLevel1"
        RequestsAuthorizationLevel2 = Get-Perm $perms "RequestsAuthorizationLevel2"
    }

    # 4. Merge Safe Properties at the start
    $finalObj = [ordered]@{}
    
    # Always put SafeName first
    $finalObj["SafeName"] = $SafeName

    # Add optional Safe Attributes if provided
    foreach ($key in $SafeProps.Keys) {
        $finalObj[$key] = $SafeProps[$key]
    }

    # Add Member/Permission attributes
    foreach ($key in $baseObj.Keys) {
        $finalObj[$key] = $baseObj[$key]
    }

    return [PSCustomObject]$finalObj
}

# =========================================================
# 1. Export ALL Safes (Standard Vault Dump)
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    
    # Session handling
    $chunkSize = 100
    $offset = 0
    $totalFetched = 0
    $allFormatted = [System.Collections.Generic.List[PSObject]]::new()
    
    $outputDir = "$PSScriptRoot/../Output"
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Write-Host "Starting Safe Export (Chunk Size: $chunkSize)..." -ForegroundColor Cyan
    
    # Session
    try {
        $session = Get-PASSession
        if (-not $session) { throw "No active psPAS session." }
    }
    catch { Write-Log "Session Error: $_" "ERROR"; return }

    do {
        Write-Progress -Activity "Exporting Safes" -Status "Fetched: $totalFetched" -CurrentOperation "Querying..."
        
        try {
            $endpoint = "/API/Safes?limit=$chunkSize&offset=$offset"
            $response = Invoke-CACAPIRequest -Method "GET" -Endpoint $endpoint
            
            $safesChunk = $null
            if ($null -ne $response.value) { $safesChunk = $response.value }
            elseif ($null -ne $response.Safes) { $safesChunk = $response.Safes }

            if (-not $safesChunk) { break }
        }
        catch { break }

        $chunkCount = $safesChunk.Count
        $totalFetched += $chunkCount

        foreach ($safe in $safesChunk) {
            try { $allFormatted.Add((Format-CACSafe -Safe $safe)) } catch {}
        }

        $offset += $chunkSize

    } while ($chunkCount -ge $chunkSize)

    Write-Progress -Activity "Exporting Safes" -Completed

    if ($allFormatted.Count -gt 0) {
        $outputFile = "$outputDir/all_safes_$timestamp.csv"
        $allFormatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        Write-Host "Export Complete: $outputFile" -ForegroundColor Green
    }
}

# =========================================================
# 3. CONSOLIDATED EXPORT FUNCTION
# Replaces Export-CACSafeMembers and Export-CACSafeUsers
# =========================================================
function Export-CACConsolidatedReport {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACConsolidatedReport" "DEBUG"

    # --- INPUT SELECTION ---
    Write-Host "=== Safe Export Wizard ===" -ForegroundColor Cyan
    Write-Host "1. Manual List (Comma separated)"
    Write-Host "2. CSV Input (Header: SafeName)"
    $mode = Read-Host "Select Input Mode"

    if ($mode -eq '1') {
        $safesInput = (Read-Host "Enter Safe Names") -split "," | ForEach-Object { $_.Trim() }
        $outPathBase = "$PSScriptRoot/../Output"
    }
    elseif ($mode -eq '2') {
        $csvPath = Read-Host "Enter CSV Path"
        if (!(Test-Path $csvPath)) { Write-Host "File not found!"; return }
        $safesInput = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
        $outPathBase = Split-Path $csvPath -Parent
    }
    else { return }

    if (-not (Test-Path $outPathBase)) { New-Item -ItemType Directory -Path $outPathBase | Out-Null }

    # --- LOGIC PROMPTS ---
    $reqMembers = Read-Host "1. Include Member Details? (y/n)"
    
    if ($reqMembers -eq 'y') {
        $reqSafeAttrs = Read-Host "2. Include Safe Attributes in Report? (y/n)"
        $reqPerms = Read-Host "3. Include Permission Details? (y/n)"
        
        $reqDetailUsers = 'n'
        if ($reqPerms -ne 'y') {
            $reqDetailUsers = Read-Host "4. Detailed User Information Required? (y/n)"
        }
    }
    else {
        # Safe Attributes forced if no members requested (otherwise report is empty)
        $reqSafeAttrs = 'y' 
        $reqPerms = 'n'
    }

    $results = @()
    $total = $safesInput.Count
    $i = 0

    # --- PROCESSING LOOP ---
    foreach ($safeName in $safesInput) {
        $i++
        Write-Progress -Activity "Generating Report" -Status "Processing Safe $i/$total : $safeName" -PercentComplete (($i / $total) * 100)
        Write-Log "Processing Safe: $safeName" "INFO"

        try {
            # 1. Fetch Safe Object (Always needed for attributes or validation)
            $safeObj = Get-PASSafe -SafeName $safeName -ErrorAction Stop
            
            # Prepare Safe Attributes Hashtable if requested
            $safePropsHash = @{}
            if ($reqSafeAttrs -eq 'y') {
                $safePropsHash = [ordered]@{}
                foreach ($prop in $safeObj.PSObject.Properties) {
                    if ($prop.Name -ne 'SafeName') {
                        $safePropsHash[$prop.Name] = $prop.Value
                    }
                }
            }

            # --- BRANCH 1: Safe Attributes Only (No Members) ---
            if ($reqMembers -ne 'y') {
                $row = [ordered]@{ SafeName = $safeName }
                foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                $results += [PSCustomObject]$row
                continue
            }

            # Fetch Members
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
            if (-not $members) { 
                # Add a row indicating no members if safe attrs are requested
                if ($reqSafeAttrs -eq 'y') {
                    $row = [ordered]@{ SafeName = $safeName; MemberInfo = "NO MEMBERS FOUND" }
                    foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                    $results += [PSCustomObject]$row
                }
                continue 
            }

            # --- BRANCH 2: Permissions Included ---
            if ($reqPerms -eq 'y') {
                foreach ($m in $members) {
                    # Use helper to flatten perms + merge safe attrs
                    $results += New-CACSafeMemberDetailedRow -SafeName $safeName -MemberObj $m -SafeProps $safePropsHash
                }
                continue
            }

            # --- BRANCH 3: Detailed User Info (Rows) ---
            if ($reqDetailUsers -eq 'y') {
                # Resolve all unique users for detailed report
                $resolvedUsers = @()
                foreach ($m in $members) {
                    if ($m.MemberType -eq "User") {
                        $resolvedUsers += $m.MemberName
                    }
                    elseif ($m.MemberType -eq "Group") {
                        $gUsers = Get-CACGroupUsers -GroupName $m.MemberName
                        if ($gUsers) { $resolvedUsers += $gUsers.UserName }
                    }
                }
                $resolvedUsers = $resolvedUsers | Select-Object -Unique

                foreach ($uName in $resolvedUsers) {
                    # Fetch User Details (from Users.psm1 cache function)
                    $uDetails = Get-CACUserDetailsFromStore -InputValue $uName
                    
                    # Create Row
                    $row = [ordered]@{ SafeName = $safeName }
                    foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                    
                    # Merge User Details
                    $row["UserName"] = $uDetails.UserName
                    $row["FullName"] = $uDetails.FullName
                    $row["Email"] = $uDetails.Email
                    $row["Department"] = $uDetails.Department
                    # $row["Status"] = $uDetails.Status
                    
                    $results += [PSCustomObject]$row
                }
            }
            # --- BRANCH 4: Group-wise User List (Row per Member/Group) ---
            else {
                foreach ($m in $members) {
                    $row = [ordered]@{ SafeName = $safeName }
                    foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                    
                    $row["MemberName"] = $m.MemberName
                    $row["MemberType"] = $m.MemberType

                    if ($m.MemberType -eq "Group") {
                        $gUsers = Get-CACGroupUsers -GroupName $m.MemberName
                        if ($gUsers) {
                            $row["SafeUsers"] = ($gUsers.UserName -join ";")
                        }
                        else {
                            $row["SafeUsers"] = "EMPTY_GROUP"
                        }
                    }
                    else {
                        # Singular User
                        $row["SafeUsers"] = $m.MemberName
                    }
                    
                    $results += [PSCustomObject]$row
                }
            }
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Progress -Activity "Generating Report" -Completed

    # --- EXPORT ---
    if ($results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outFile = "$outPathBase/Consolidated_SafeReport_$timestamp.csv"
        
        $results | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
        Write-Host "Report Generated: $outFile" -ForegroundColor Green
        Write-Log "Exported $($results.Count) rows to $outFile" "SUCCESS"
    }
    else {
        Write-Host "No data found to export." -ForegroundColor Yellow
    }
}
 
# =========================================================
# 4. Safe Account Counts
# =========================================================
function Export-CACSafeAccountCounts {
    Write-Log "Inventory Scan Started" "DEBUG"
    Write-Progress -Activity "Inventory" -Status "Fetching Safes..." -PercentComplete 0
    try { $safes = Get-PASSafe -ErrorAction Stop } catch { return }

    $res = @(); $i = 0; $t = $safes.Count
    foreach ($s in $safes) {
        $i++
        Write-Progress -Activity "Scanning" -Status "$($s.SafeName)" -PercentComplete (($i / $t) * 100)
        $c = 0
        try { $a = Get-PASAccount -SafeName $s.SafeName -ErrorAction SilentlyContinue; if ($a) { $c = $a.Count } } catch {}
        $res += [PSCustomObject]@{ SafeName = $s.SafeName; Count = $c; Desc = $s.Description; CPM = $s.ManagingCPM }
    }
    Write-Progress -Activity "Scanning" -Completed
    
    if ($res) {
        $out = "$PSScriptRoot/../Output/safe_counts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $res | Export-Csv $out -NoTypeInformation -Encoding UTF8
        Write-Host "Done: $out" -ForegroundColor Green
    }
}

Export-ModuleMember -Function Export-CACAllSafes, Export-CACConsolidatedReport, Export-CACSafeAccountCounts