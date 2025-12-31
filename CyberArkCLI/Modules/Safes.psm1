# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: CyberArk Safe Management
# FEATURES: Progress Bars, Deep Logging, Correct Permissions, Inventory Scan
# ============================================================================

# ----------------------------------------------------------------------------
# Helper function for mapping safe Permissions 
#Safe Member Permissions without safe meber-user details
# ----------------------------------------------------------------------------
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj
    )

    # 1. Locate the permissions container
    $perms = $null
    if ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions) {
        $perms = $MemberObj.Permissions
    }
    else {
        $perms = $MemberObj
    }

    # 2. Local Helper to extract bool safely
    function Get-Perm ($obj, $name) {
        if ($obj.PSObject.Properties.Match($name)) { return [bool]$obj.$name }
        if ($obj -is [System.Collections.IDictionary] -and $obj.Contains($name)) { return [bool]$obj[$name] }
        return $false
    }

    # 3. Return Flat Object with Correct Column Names
    return [PSCustomObject]@{
        SafeName                               = $SafeName
        MemberName                             = $MemberObj.MemberName
        MemberType                             = $MemberObj.MemberType
        MembershipExpirationDate               = $MemberObj.MembershipExpirationDate

        # --- Standard User Permissions ---
        UseAccounts                            = Get-Perm $perms "UseAccounts"
        RetrieveAccounts                       = Get-Perm $perms "RetrieveAccounts"
        ListAccounts                           = Get-Perm $perms "ListAccounts"
        AddAccounts                            = Get-Perm $perms "AddAccounts"
        UpdateAccountContent                   = Get-Perm $perms "UpdateAccountContent"
        UpdateAccountProperties                = Get-Perm $perms "UpdateAccountProperties"
        InitiateCPMAccountManagementOperations = Get-Perm $perms "InitiateCPMAccountManagementOperations"
        SpecifyNextAccountContent              = Get-Perm $perms "SpecifyNextAccountContent"
        RenameAccounts                         = Get-Perm $perms "RenameAccounts"
        DeleteAccounts                         = Get-Perm $perms "DeleteAccounts"
        UnlockAccounts                         = Get-Perm $perms "UnlockAccounts"
        
        # --- Combined / Specific Corrections ---
        MoveAccountsAndFolders                 = Get-Perm $perms "MoveAccountsAndFolders"
        
        # --- Admin Permissions ---
        ManageSafe                             = Get-Perm $perms "ManageSafe"
        ManageSafeMembers                      = Get-Perm $perms "ManageSafeMembers"
        BackupSafe                             = Get-Perm $perms "BackupSafe"
        ViewAuditLog                           = Get-Perm $perms "ViewAuditLog"
        ViewSafeMembers                        = Get-Perm $perms "ViewSafeMembers"
        
        # --- Corrected Access Name ---
        AccessWithoutConfirmation              = Get-Perm $perms "AccessWithoutConfirmation"
        
        # --- Folder Permissions ---
        CreateFolders                          = Get-Perm $perms "CreateFolders"
        DeleteFolders                          = Get-Perm $perms "DeleteFolders"
        
        # --- Authorization Workflow ---
        RequestsAuthorizationLevel1            = Get-Perm $perms "RequestsAuthorizationLevel1"
        RequestsAuthorizationLevel2            = Get-Perm $perms "RequestsAuthorizationLevel2"
    }
}


# =========================================================
# 1. Export ALL Safes (DEBUG MODE)
# =========================================================
# =========================================================
# 1. Export ALL Safes (Optimized: Handles 'value' or 'Safes')
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    
    # 1. Get Active Session
    try {
        $session = Get-PASSession
        if (-not $session) { throw "No active psPAS session found. Run New-PASSession first." }
        
        $webSession = $session.WebSession
        # Clean the BaseURI to ensure no double slashes
        $baseURI = $session.BaseURI.TrimEnd('/')
        
        Write-Log "Session found. BaseURI: $baseURI" "DEBUG"
    }
    catch {
        Write-Log "Failed to retrieve psPAS session: $($_.Exception.Message)" "ERROR"
        return
    }

    # Configuration
    $chunkSize = 100
    $offset = 0
    $totalFetched = 0
    $allFormatted = [System.Collections.Generic.List[PSObject]]::new()
    
    # Output Setup
    $outputDir = "$PSScriptRoot/../Output"
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Write-Host "Starting Safe Export (Chunk Size: $chunkSize)..." -ForegroundColor Cyan
    Write-Log "Starting pagination loop via Invoke-RestMethod" "INFO"

    do {
        # 2. Update Progress
        Write-Progress -Activity "Exporting Safes" `
            -Status "Fetched: $totalFetched | Current Batch: $offset - $($offset + $chunkSize)" `
            -CurrentOperation "Querying Vault API..." 

        try {
            # 3. Construct URL
            $url = "$baseURI/API/Safes?limit=$chunkSize&offset=$offset"
            
            # 4. Call API
            $response = Invoke-RestMethod -Uri $url -Method GET -WebSession $webSession -ContentType "application/json" -ErrorAction Stop
            
            # 5. Extract Data (Universal Logic)
            # Try 'Safes' (Gen2 standard), then 'value' (OData/Older standard)
            if ($response.PSObject.Properties.Match("Safes")) {
                $safesChunk = $response.Safes
            }
            elseif ($response.PSObject.Properties.Match("value")) {
                $safesChunk = $response.value
            }
            else {
                $safesChunk = $null
            }

            # Debug log to confirm which one worked
            if ($safesChunk) {
                Write-Log "Received $($safesChunk.Count) safes in this chunk." "DEBUG"
            }
        }
        catch {
            Write-Log "API Error at offset $offset : $($_.Exception.Message)" "ERROR"
            Write-Log "Failed URL: $url" "DEBUG"
            break 
        }

        # Break if no results
        if (-not $safesChunk -or $safesChunk.Count -eq 0) {
            break
        }

        $chunkCount = $safesChunk.Count
        $totalFetched += $chunkCount

        # 6. Process this chunk
        Write-Progress -Activity "Exporting Safes" `
            -Status "Total Safes: $totalFetched" `
            -CurrentOperation "Formatting chunk..."

        foreach ($safe in $safesChunk) {
            try {
                $formatted = Format-CACSafe -Safe $safe
                if ($formatted) {
                    $allFormatted.Add($formatted)
                }
            }
            catch {
                Write-Log "Error formatting safe $($safe.SafeName): $($_.Exception.Message)" "WARN"
            }
        }

        # 7. Prepare next batch
        $offset += $chunkSize

    } while ($chunkCount -ge $chunkSize)

    # Close Progress
    Write-Progress -Activity "Exporting Safes" -Completed

    # 8. Export
    if ($allFormatted.Count -gt 0) {
        $outputFile = "$outputDir/all_safes_$timestamp.csv"
        Write-Log "Exporting $($allFormatted.Count) safes to CSV: $outputFile" "INFO"
        
        $allFormatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        
        Write-Host "`nExport Complete!" -ForegroundColor Green
        Write-Host "  Total Safes: $($allFormatted.Count)"
        Write-Host "  File: $outputFile" -ForegroundColor Cyan
    }
    else {
        Write-Host "No safes found." -ForegroundColor Yellow
        Write-Log "Final count was 0." "WARN"
    }
}
function Export-CACAllSafes1 {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    
    Write-Progress -Activity "Fetching Safes" -Status "Querying Vault..." -PercentComplete 0
    Write-Log "Fetching all safes using Get-PASSafe" "INFO"

    try {
        $safes = Get-PASSafe
        Write-Progress -Activity "Fetching Safes" -Completed

        if (-not $safes -or $safes.Count -eq 0) {
            Write-Log "No safes returned from Vault" "WARN"
            Write-Host "No safes found." -ForegroundColor Yellow
            return
        }

        $total = $safes.Count
        Write-Log "Total safes retrieved: $total" "INFO"
        Write-Host "Processing $total safes..." -ForegroundColor Cyan

        # Output Setup
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { 
            New-Item -ItemType Directory -Path $outputDir | Out-Null 
            Write-Log "Created output directory: $outputDir" "DEBUG"
        }
        
        $formatted = @()
        $successCount = 0
        $errorCount = 0
        $i = 0

        foreach ($safe in $safes) {
            $i++
            $pct = ($i / $total) * 100
            Write-Progress -Activity "Exporting Safes" -Status "Processing $i of $total : $($safe.safeName)" -PercentComplete $pct

            try {
                Write-Log "Processing safe $i/$total : $($safe.safeName)" "DEBUG"
                $formattedSafe = Format-CACSafe -Safe $safe

                if ($formattedSafe) {
                    $formatted += $formattedSafe
                    $successCount++
                }
                else {
                    Write-Log "Format-CACSafe returned null for: $($safe.safeName)" "WARN"
                    $errorCount++
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
            $file = "$outputDir/all_safes_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            Write-Log "Exporting $successCount safes to CSV: $file" "INFO"
            
            $formatted | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
            
            Write-Host "Export Successful: $file" -ForegroundColor Green
            Write-Log "CSV export completed successfully" "SUCCESS"
        }
        else {
            Write-Log "No successfully formatted safes to export" "WARN"
        }

        Write-Log "Completed Export-CACAllSafes. Success: $successCount, Errors: $errorCount" "INFO"
    }
    catch {
        Write-Log "Fatal Error in Export-CACAllSafes: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# =========================================================
# 2. Search Safe
# =========================================================
function Search-CACSafeByName {
    param([Parameter(Mandatory)][string]$SafeName)

    Write-Log "Search-CACSafeByName() started for: $SafeName" "INFO"
    Write-Host "Searching..." -ForegroundColor Cyan

    try {
        $s = Get-PASSafe -SafeName $SafeName
        
        if ($s) {
            Write-Log "Safe found: $($s.SafeName). Formatting..." "DEBUG"
            
            $outputDir = "$PSScriptRoot/../Output"
            if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
            
            $out = "$outputDir/search_$SafeName.csv"
            Format-CACSafe -Safe $s | Export-Csv $out -NoTypeInformation
            
            Write-Log "Export completed: $out" "SUCCESS"
            Write-Host "Found & Exported: $out" -ForegroundColor Green
        }
        else { 
            Write-Log "Safe '$SafeName' not found" "WARN"
            Write-Host "Not Found" -ForegroundColor Yellow 
        }
    }
    catch { 
        Write-Log "Error searching safe '$SafeName': $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $_" -ForegroundColor Red 
    }
}

# =========================================================
# 3. Export Safe Members (Uses NEW Helper)
# =========================================================
function Export-CACSafeMembers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeMembers" "DEBUG"

    Write-Host "1. Manual List | 2. CSV Input" -ForegroundColor Cyan
    $mode = Read-Host "Choice"
    
    if ($mode -eq '1') { 
        $safes = (Read-Host "Safe Names (comma)") -split "," | ForEach { $_.Trim() }
        $toCsv = $false 
    }
    elseif ($mode -eq '2') { 
        $p = Read-Host "CSV Path"
        if (!(Test-Path $p)) { Write-Log "CSV not found: $p" "ERROR"; return }
        $safes = (Import-Csv $p).SafeName | ForEach { $_.Trim() }
        $toCsv = $true
        $parent = Split-Path $p -Parent 
    }
    else { return }

    $rows = @()
    $total = $safes.Count
    $i = 0

    foreach ($s in $safes) {
        $i++
        Write-Progress -Activity "Safe Members" -Status "Safe $i/$total : $s" -PercentComplete (($i / $total) * 100)
        Write-Log "Fetching members for safe: $s" "INFO"

        try {
            $mems = Get-PASSafeMember -SafeName $s -ErrorAction Stop
            if ($mems) {
                Write-Log "Found $($mems.Count) members in safe $s" "DEBUG"
                foreach ($m in $mems) {
                    $rows += New-CACSafeMemberDetailedRow -SafeName $s -MemberObj $m
                }
            }
            else {
                Write-Log "No members found in safe $s" "WARN"
            }
        }
        catch {
            Write-Log "Failed to fetch members for $s : $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Progress -Activity "Safe Members" -Completed

    if ($rows.Count -eq 0) { 
        Write-Log "No members found in any safe" "WARN"
        Write-Host "No members found." -ForegroundColor Yellow
        return 
    }

    if ($toCsv) {
        $out = Join-Path $parent "safe_members_detailed_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        Write-Log "Exporting $($rows.Count) rows to CSV: $out" "INFO"
        
        $rows | Export-Csv $out -NoTypeInformation -Encoding UTF8
        
        Write-Host "Exported: $out" -ForegroundColor Green
        Write-Log "Export successful" "SUCCESS"
    }
    else {
        $rows | Out-GridView -Title "Safe Permissions"
    }
}

# =========================================================
# 4. Export Safe Users (Nested Progress)
# =========================================================
function Export-CACSafeUsers {
    Write-Log "Started Export-CACSafeUsers" "DEBUG"

    Write-Host "1. Manual | 2. CSV" -ForegroundColor Cyan
    $mode = Read-Host "Choice"
    if ($mode -eq '1') { $safes = (Read-Host "Safe Names") -split ","; $toCsv = $false }
    elseif ($mode -eq '2') { 
        $p = Read-Host "CSV Path"
        if (!(Test-Path $p)) { Write-Log "CSV missing: $p" "ERROR"; return }
        $safes = (Import-Csv $p).SafeName
        $toCsv = $true 
        $outCsv = Read-Host "Output CSV Path" 
    }
    
    $rows = @()
    $i = 0; $total = $safes.Count

    foreach ($s in $safes) {
        $i++
        Write-Progress -Id 1 -Activity "Processing Safes" -Status "$s" -PercentComplete (($i / $total) * 100)
        Write-Log "Processing safe: $s" "INFO"

        try {
            $mems = Get-PASSafeMember -SafeName $s -ErrorAction Stop
            $j = 0; $mTotal = $mems.Count
            
            foreach ($m in $mems) {
                $j++
                Write-Progress -Id 2 -ParentId 1 -Activity "Resolving Users" -Status "$($m.MemberName)" -PercentComplete (($j / $mTotal) * 100)
                
                if ($m.MemberType -eq "User") {
                    Write-Log "Resolving User: $($m.MemberName)" "DEBUG"
                    $u = Get-CACUserDetailsFromStore -InputValue $m.MemberName
                    $rows += New-CACSafeUserRow -SafeName $s -SafeMember $m.MemberName -UserObj $u
                }
                elseif ($m.MemberType -eq "Group") {
                    Write-Log "Resolving Group: $($m.MemberName)" "DEBUG"
                    $gUsers = Get-CACGroupUsers -GroupName $m.MemberName
                    foreach ($gu in $gUsers) {
                        $u = Get-CACUserDetailsFromStore -InputValue $gu.Id
                        $rows += New-CACSafeUserRow -SafeName $s -SafeMember $m.MemberName -UserObj $u
                    }
                }
            }
        }
        catch {
            Write-Log "Error processing safe $s : $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Progress -Id 2 -Completed; Write-Progress -Id 1 -Completed

    if ($toCsv) { 
        $rows | Export-Csv $outCsv -NoTypeInformation
        Write-Log "Exported Safe Users to $outCsv" "SUCCESS"
        Write-Host "Done" -ForegroundColor Green 
    }
    else { $rows | Format-Table -AutoSize }
}

# =========================================================
# 5. Create Safes
# =========================================================
function New-CACSafe {
    Write-Log "Started New-CACSafe" "DEBUG"
    Write-Host "1. Manual | 2. CSV"
    
    if ((Read-Host) -eq '2') {
        $path = Read-Host "CSV Path"
        if (!(Test-Path $path)) { Write-Log "CSV not found: $path" "ERROR"; return }
        
        $data = Import-Csv $path
        $i = 0; $t = $data.Count
        
        foreach ($s in $data) {
            $i++
            Write-Progress -Activity "Creating Safes" -Status "$($s.SafeName)" -PercentComplete (($i / $t) * 100)
            try { 
                Add-PASSafe -SafeName $s.SafeName -Description $s.Description -ManagingCPM $s.ManagingCPM -ErrorAction Stop 
                Write-Log "Created Safe: $($s.SafeName)" "SUCCESS"
            }
            catch {
                Write-Log "Failed to create safe $($s.SafeName): $($_.Exception.Message)" "ERROR"
            }
        }
        Write-Progress -Activity "Creating Safes" -Completed
    }
}

# =========================================================
# 6. Add Members
# =========================================================
function Add-CACSafeMember {
    Write-Log "Started Add-CACSafeMember" "DEBUG"
    $conf = Get-CACConfig
    
    Write-Host "1. Manual | 2. CSV"
    if ((Read-Host) -eq '2') {
        $path = Read-Host "CSV Path"
        if (!(Test-Path $path)) { Write-Log "CSV not found: $path" "ERROR"; return }

        $data = Import-Csv $path
        $i = 0; $t = $data.Count
        
        foreach ($e in $data) {
            $i++
            Write-Progress -Activity "Adding Members" -Status "$($e.Member) -> $($e.SafeName)" -PercentComplete (($i / $t) * 100)
            
            if ($conf.SafePermissionSets[$e.PermissionKey]) {
                try { 
                    Add-PASSafeMember -SafeName $e.SafeName -MemberName $e.Member -SearchInVault $true -Permissions $conf.SafePermissionSets[$e.PermissionKey] -ErrorAction Stop 
                    Write-Log "Added $($e.Member) to $($e.SafeName)" "SUCCESS"
                }
                catch {
                    Write-Log "Failed to add $($e.Member) to $($e.SafeName): $($_.Exception.Message)" "ERROR"
                }
            }
            else {
                Write-Log "Invalid Permission Key: $($e.PermissionKey)" "WARN"
            }
        }
        Write-Progress -Activity "Adding Members" -Completed
    }
}

# =========================================================
# 7. Safe Account Counts (Detailed Logs)
# =========================================================
function Export-CACSafeAccountCounts {
    Write-Log "Started Export-CACSafeAccountCounts" "DEBUG"
    
    Write-Progress -Activity "Inventory" -Status "Fetching Safes..." -PercentComplete 0
    Write-Log "Fetching list of all safes..." "INFO"
    
    try { 
        $safes = Get-PASSafe -ErrorAction Stop 
        Write-Log "Retrieved $($safes.Count) safes." "INFO"
    }
    catch { 
        Write-Log "Error fetching safes: $($_.Exception.Message)" "ERROR"
        Write-Host "Error fetching safes" -ForegroundColor Red
        return 
    }

    $res = @()
    $i = 0; $t = $safes.Count
    Write-Host "Scanning $t safes..." -ForegroundColor Cyan
    
    foreach ($s in $safes) {
        $i++
        Write-Progress -Activity "Account Scan" -Status "Safe $i/$t : $($s.SafeName)" -PercentComplete (($i / $t) * 100)
        
        $count = 0
        try { 
            # SilentlyContinue used because empty safes can throw 404 in some versions
            $a = Get-PASAccount -SafeName $s.SafeName -ErrorAction SilentlyContinue
            if ($a) { $count = $a.Count }
            
            # LOG SUCCESS / INFO per safe
            Write-Log "Scanned Safe: $($s.SafeName) | Accounts: $count" "DEBUG"
        }
        catch {
            Write-Log "Error scanning content of safe $($s.SafeName): $($_.Exception.Message)" "WARN"
        }
        
        $res += [PSCustomObject]@{
            SafeName     = $s.SafeName
            AccountCount = $count
            Description  = $s.Description
            ManagingCPM  = $s.ManagingCPM
        }
    }
    Write-Progress -Activity "Account Scan" -Completed

    if ($res.Count -gt 0) {
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
        $out = "$outputDir/safe_counts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        
        Write-Log "Exporting scan results to $out" "INFO"
        $res | Export-Csv $out -NoTypeInformation -Encoding UTF8
        
        Write-Host "Scan Complete: $out" -ForegroundColor Green
        Write-Log "Account inventory scan completed successfully" "SUCCESS"
    }
    else {
        Write-Log "No results generated from scan." "WARN"
    }
}

Export-ModuleMember -Function `
    Export-CACAllSafes, `
    Search-CACSafeByName, `
    Export-CACSafeMembers, `
    Export-CACSafeUsers, `
    New-CACSafe, `
    Add-CACSafeMember, `
    Export-CACSafeAccountCounts

