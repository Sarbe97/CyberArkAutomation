# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: Safe Management using raw CyberArk REST API
# NOTE: Uses Format-CACSafe and New-CACSafeMemberRow from Models.psm1
#       Uses Get-CACPermissionSet from Config.psm1
# ============================================================================


# =========================================================
# 1. Export ALL Safes
# =========================================================
function Export-CACAllSafes {
   
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    
    $chunkSize = 100
    $offset = 0
    $totalFetched = 0
    $allFormatted = [System.Collections.Generic.List[PSObject]]::new()
    
    $outputDir = Get-CACOutputDir
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Write-Host "Starting Safe Export..." -ForegroundColor Cyan

    do {
        Write-Progress -Activity "Exporting Safes" -Status "Fetched: $totalFetched" -CurrentOperation "Querying..."
        
        try {
            $endpoint = "/API/Safes?limit=$chunkSize&offset=$offset"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
            
            $safesChunk = Get-CACResponseData -Response $response -PropertyNames @("value", "Safes")

            if (-not $safesChunk -or $safesChunk.Count -eq 0) { break }
        }
        catch { 
            Write-Log "Error fetching safes: $($_.Exception.Message)" "ERROR"
            break 
        }

        $chunkCount = $safesChunk.Count
        $totalFetched += $chunkCount

        foreach ($safe in $safesChunk) {
            try { 
                $allFormatted.Add((Format-CACSafe -Safe $safe)) 
            } 
            catch {
                Write-Log "Failed to format safe '$($safe.safeName)': $($_.Exception.Message)" "WARN"
            }
        }

        $offset += $chunkSize

    } while ($chunkCount -ge $chunkSize)

    Write-Progress -Activity "Exporting Safes" -Completed

    if ($allFormatted.Count -gt 0) {
        $outputFile = "$outputDir/all_safes_$timestamp.csv"
        $allFormatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        Write-Log "Exported $($allFormatted.Count) safes to $outputFile" "SUCCESS"
        Write-Host "Export Complete: $outputFile" -ForegroundColor Green
    }
    else {
        Write-Host "No safes found." -ForegroundColor Yellow
    }
}

# =========================================================
# 2. Export Safe Account Counts
# =========================================================
function Export-CACSafeAccountCounts {
    <#
    .SYNOPSIS
        Scan safes and count accounts in each.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeAccountCounts()" "DEBUG"

    # Input selection
    Write-Host "=== Safe Account Inventory ===" -ForegroundColor Cyan
    Write-Host "1. Manual List (Comma separated)"
    Write-Host "2. CSV Input (Header: SafeName)"
    $mode = Read-Host "Select Input Mode"

    $safesInput = @()
    $outPathBase = Get-CACOutputDir

    if ($mode -eq '1') {
        $safesInput = (Read-Host "Enter Safe Names") -split "," | ForEach-Object { $_.Trim() }
    }
    elseif ($mode -eq '2') {
        $csvPath = Read-Host "Enter CSV Path"
        if (!(Test-Path $csvPath)) { Write-Host "File not found!" -ForegroundColor Red; return }
        $safesInput = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
    }
    else { return }

    if ($safesInput.Count -eq 0) {
        Write-Host "No safes to process." -ForegroundColor Yellow
        return
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $i = 0
    $total = $safesInput.Count

    foreach ($safeName in $safesInput) {
        $i++
        Write-Progress -Activity "Inventory Scan" -Status "Processing $i/$total : $safeName" -PercentComplete (($i / $total) * 100)
        
        try {
            # Fetch Safe Details
            $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))"
            
            # Fetch Account Count
            $accountCount = 0
            try { 
                $accounts = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Accounts?filter=safeName eq $([System.Web.HttpUtility]::UrlEncode($safeName))&limit=1"
                if ($accounts.count) { $accountCount = $accounts.count }
                elseif ($accounts.value) { $accountCount = $accounts.value.Count }
            }
            catch {
                Write-Log "Failed to get account count for $safeName : $($_.Exception.Message)" "WARN"
            }

            $results.Add([PSCustomObject]@{ 
                    SafeName     = $safeName
                    AccountCount = $accountCount
                    Description  = $safe.description
                    ManagingCPM  = $safe.managingCPM
                })
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "WARN"
            $results.Add([PSCustomObject]@{ 
                    SafeName     = $safeName
                    AccountCount = "ERROR"
                    Description  = $_.Exception.Message
                    ManagingCPM  = ""
                })
        }
    }
    Write-Progress -Activity "Inventory Scan" -Completed
    
    if ($results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outFile = "$outPathBase/Safe_Account_Counts_$timestamp.csv"
        $results | Export-Csv $outFile -NoTypeInformation -Encoding UTF8
        
        Write-Host ""
        $results | Format-Table -AutoSize
        Write-Host "Report Generated: $outFile" -ForegroundColor Green
    }
    else {
        Write-Host "No data found." -ForegroundColor Yellow
    }
}

# =========================================================
# 9. CONSOLIDATED EXPORT FUNCTION
# Replaces Export-CACSafeMembersReport and Export-CACSafeUsers
# =========================================================
function Export-CACConsolidatedReport {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACConsolidatedReport" "DEBUG"

    # ==========================================
    # 1. INPUT SELECTION
    # ==========================================
    Write-Host "=== Safe Export Wizard ===" -ForegroundColor Cyan
    Write-Host "1. Manual List (Comma separated)"
    Write-Host "2. CSV Input (Header: SafeName)"
    $inputMode = Read-Host "Select Input Source"

    $safesInput = @()
    $outPathBase = Get-CACOutputDir

    if ($inputMode -eq '1') {
        $safesInput = (Read-Host "Enter Safe Names") -split "," | ForEach-Object { $_.Trim() }
    }
    elseif ($inputMode -eq '2') {
        $csvPath = Read-Host "Enter CSV Path"
        if (!(Test-Path $csvPath)) { Write-Host "File not found!" -ForegroundColor Red; return }
        $safesInput = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
        $outPathBase = Split-Path $csvPath -Parent
    }
    else { return }

    if ($safesInput.Count -eq 0) {
        Write-Host "No safes to process." -ForegroundColor Yellow; return
    }

    # ==========================================
    # 2. REPORT CONFIGURATION (LOGIC GATES)
    # ==========================================
    Write-Host "`n=== Select Report Type ===" -ForegroundColor Cyan
    Write-Host "1. Safe Inventory Only" -ForegroundColor Gray
    Write-Host "   (Output: Safe Name + Description/Location/Retention)"
    Write-Host "2. Permissions Audit" -ForegroundColor Gray
    Write-Host "   (Output: Row per Member with Permissions)"
    Write-Host "3. Membership Summary (Compact)" -ForegroundColor Gray
    Write-Host "   (Output: Row per Member. Groups listed as 'UserA;UserB' in one cell)"
    Write-Host "4. Detailed User Audit (Expanded)" -ForegroundColor Gray
    Write-Host "   (Output: Row per User. Groups exploded into rows + Extended User Attributes)"
    
    $reportMode = Read-Host "Select Option (1-4)"
    if ($reportMode -notin '1', '2', '3', '4') { Write-Host "Invalid selection." -ForegroundColor Red; return }

    # --- Prompt A: Safe Attributes ---
    $reqSafeAttrs = 'y' # Default for Mode 1
    if ($reportMode -ne '1') {
        $reqSafeAttrs = Read-Host "`n> Include Safe Attributes (Location, Retention, etc.) in every row? (y/n)"
    }

    # --- Prompt B: Groups to Hide (Only for Modes 3 & 4) ---
    $includeHiddenGroupUsers = 'n'
    $groupsToHide = Get-CACGroupsToHide

    if ($reportMode -in '3', '4' -and $groupsToHide.Count -gt 0) {
        Write-Host "`n> Groups to Hide (from Config):" -ForegroundColor Yellow
        $groupsToHide | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        $includeHiddenGroupUsers = Read-Host "> Expand/List users for these hidden groups? (y/n)"
    }

    # ==========================================
    # 3. PROCESSING LOOP
    # ==========================================
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $total = $safesInput.Count
    $i = 0

    foreach ($safeName in $safesInput) {
        $i++
        Write-Progress -Activity "Generating Report (Mode $reportMode)" -Status "Processing Safe $i/$total : $safeName" -PercentComplete (($i / $total) * 100)
        Write-Log "Processing Safe: $safeName" "INFO"

        try {
            # --- Step A: Base Safe Data ---
            # We always fetch the safe object to verify existence and get attributes
            $safeObj = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))"
            
            # Create the Base Row (Common to all modes)
            $baseRow = [ordered]@{ SafeName = $safeName }
            
            if ($reqSafeAttrs -eq 'y') {
                $baseRow["Description"] = $safeObj.description
                $baseRow["Location"] = $safeObj.location
                $baseRow["ManagingCPM"] = $safeObj.managingCPM
                $baseRow["RetentionDays"] = $safeObj.numberOfDaysRetention
                $baseRow["AutoPurge"] = $safeObj.autoPurgeEnabled
            }

            # --- Step B: Logic Switch ---
            switch ($reportMode) {
                
                # --- MODE 1: Inventory Only ---
                '1' {
                    $results.Add([PSCustomObject]$baseRow)
                }

                # --- MODE 2: Permissions Audit ---
                '2' {
                    $membersResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members"
                    $members = @(Get-CACResponseData -Response $membersResponse -PropertyNames @("value", "members"))
                    
                    if ($members.Count -eq 0) {
                        $row = Copy-OrderedHashtable $baseRow; $row["MemberInfo"] = "NO MEMBERS"; $results.Add([PSCustomObject]$row)
                    }
                    else {
                        foreach ($m in $members) {
                            # Use your existing helper for granular permissions
                            # We pass safePropsHash as empty or filled based on user choice, but logic here assumes New-CACSafeMemberDetailedRow 
                            # might need to be adjusted or we construct the row manually here.
                            # Assuming New-CACSafeMemberDetailedRow returns a PSCustomObject:
                            $permRow = New-CACSafeMemberDetailedRow -SafeName $safeName -MemberObj $m -SafeProps $null
                            
                            # Merge BaseRow attributes into the perm row if requested
                            if ($reqSafeAttrs -eq 'y') {
                                # We reconstruct to put SafeName/Attrs first
                                $finalRow = [ordered]@{ SafeName = $safeName }
                                foreach ($k in $baseRow.Keys) { if ($k -ne 'SafeName') { $finalRow[$k] = $baseRow[$k] } }
                                $permRow.PSObject.Properties | Where-Object { $_.Name -ne 'SafeName' } | ForEach-Object { $finalRow[$_.Name] = $_.Value }
                                $results.Add([PSCustomObject]$finalRow)
                            }
                            else {
                                $results.Add($permRow)
                            }
                        }
                    }
                }

                # --- MODE 3: Membership Summary (Compact) ---
                '3' {
                    $membersResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members"
                    $members = @(Get-CACResponseData -Response $membersResponse -PropertyNames @("value", "members"))

                    foreach ($m in $members) {
                        $row = Copy-OrderedHashtable $baseRow
                        $row["MemberName"] = $m.memberName
                        $row["MemberType"] = $m.memberType
                        
                        if ($m.memberType -eq "Group") {
                            $isHidden = $m.memberName -in $groupsToHide
                            
                            if ($isHidden -and $includeHiddenGroupUsers -ne 'y') {
                                $row["SafeUsers"] = "(Skipped - Hidden Group)"
                            }
                            else {
                                $gUsers = Get-CACMembersOfGroup -GroupName $m.memberName
                                if ($gUsers) { $row["SafeUsers"] = ($gUsers.UserName -join ";") }
                                else { $row["SafeUsers"] = "-" }
                            }
                        }
                        else {
                            $row["SafeUsers"] = $m.memberName
                        }
                        $results.Add([PSCustomObject]$row)
                    }
                }

                # --- MODE 4: Detailed User Audit (Expanded) ---
                '4' {
                    $membersResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members"
                    $members = @(Get-CACResponseData -Response $membersResponse -PropertyNames @("value", "members"))

                    foreach ($m in $members) {
                        # Resolve Target Users List
                        $usersToProcess = @()
                        $status = "User"

                        if ($m.memberType -eq "User") {
                            $usersToProcess += $m.memberName
                        }
                        elseif ($m.memberType -eq "Group") {
                            $isHidden = $m.memberName -in $groupsToHide
                            if ($isHidden -and $includeHiddenGroupUsers -ne 'y') {
                                # Skip processing
                                $status = "SkippedGroup"
                            }
                            else {
                                $gUsers = Get-CACMembersOfGroup -GroupName $m.memberName
                                if ($gUsers) { 
                                    $usersToProcess += $gUsers.UserName 
                                    $status = "GroupMember"
                                }
                                else {
                                    $status = "EmptyGroup"
                                }
                            }
                        }

                        # Handle Skipped/Empty Groups (1 row)
                        if ($status -eq "SkippedGroup" -or $status -eq "EmptyGroup") {
                            $row = Copy-OrderedHashtable $baseRow
                            $row["OriginalMember"] = $m.memberName
                            $row["Type"] = $m.memberType
                            $row["ActualUser"] = if ($status -eq "SkippedGroup") { "(Hidden Group Skipped)" }else { "-" }
                            $row["FullName"] = ""
                            $row["Email"] = ""
                            $row["Department"] = ""
                            $results.Add([PSCustomObject]$row)
                            continue
                        }

                        # Handle Expanded Users (N rows)
                        foreach ($uName in $usersToProcess) {
                            $uDetails = Get-CACUserDetailsFromStore -InputValue $uName
                            
                            $row = Copy-OrderedHashtable $baseRow
                            $row["OriginalMember"] = $m.memberName
                            $row["Type"] = $m.memberType
                            
                            if ($uDetails) {
                                $row["ActualUser"] = $uDetails.UserName
                                $row["FullName"] = $uDetails.FullName
                                $row["Email"] = $uDetails.Email
                                $row["Department"] = $uDetails.Department
                            }
                            else {
                                $row["ActualUser"] = $uName
                                $row["FullName"] = "" # Or "Not Found"
                                $row["Email"] = ""
                                $row["Department"] = ""
                            }
                            $results.Add([PSCustomObject]$row)
                        }
                    }
                }
            } # End Switch
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "ERROR"
            $errRow = [ordered]@{ SafeName = $safeName; Error = $_.Exception.Message }
            $results.Add([PSCustomObject]$errRow)
        }
    }
    Write-Progress -Activity "Generating Report" -Completed

    # ==========================================
    # 4. EXPORT
    # ==========================================
    if ($results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outFile = "$outPathBase/Report_Mode${reportMode}_$timestamp.csv"
        
        $results | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "Report Generated: $outFile" -ForegroundColor Green
        Write-Log "Exported $($results.Count) rows to $outFile" "SUCCESS"
    }
    else {
        Write-Host "No data found to export." -ForegroundColor Yellow
    }
}

# =========================================================
# HELPER: Create detailed member row with permissions
# =========================================================
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj,
        [hashtable]$SafeProps = @{} 
    )

    # Get permissions from member object
    $perms = $MemberObj.permissions

    # Helper to safely get permission value
    function Get-Perm ($obj, $name) {
        if ($null -eq $obj) { return $false }
        if ($obj.PSObject.Properties.Match($name).Count -gt 0) { return [bool]$obj.$name }
        return $false
    }

    # Build the row
    $finalObj = [ordered]@{}
    
    # Always put SafeName first
    $finalObj["SafeName"] = $SafeName

    # Add optional Safe Attributes if provided
    foreach ($key in $SafeProps.Keys) {
        $finalObj[$key] = $SafeProps[$key]
    }

    # Add Member info
    $finalObj["MemberName"] = $MemberObj.memberName
    $finalObj["MemberType"] = $MemberObj.memberType
    $finalObj["MembershipExpirationDate"] = $MemberObj.membershipExpirationDate

    # Add Permissions
    $finalObj["UseAccounts"] = Get-Perm $perms "useAccounts"
    $finalObj["RetrieveAccounts"] = Get-Perm $perms "retrieveAccounts"
    $finalObj["ListAccounts"] = Get-Perm $perms "listAccounts"
    $finalObj["AddAccounts"] = Get-Perm $perms "addAccounts"
    $finalObj["UpdateAccountContent"] = Get-Perm $perms "updateAccountContent"
    $finalObj["UpdateAccountProperties"] = Get-Perm $perms "updateAccountProperties"
    $finalObj["InitiateCPMOps"] = Get-Perm $perms "initiateCPMAccountManagementOperations"
    $finalObj["SpecifyNextAccountContent"] = Get-Perm $perms "specifyNextAccountContent"
    $finalObj["RenameAccounts"] = Get-Perm $perms "renameAccounts"
    $finalObj["DeleteAccounts"] = Get-Perm $perms "deleteAccounts"
    $finalObj["UnlockAccounts"] = Get-Perm $perms "unlockAccounts"
    $finalObj["MoveAccountsAndFolders"] = Get-Perm $perms "moveAccountsAndFolders"
    $finalObj["AccessWithoutConfirmation"] = Get-Perm $perms "accessWithoutConfirmation"
    $finalObj["ManageSafe"] = Get-Perm $perms "manageSafe"
    $finalObj["ManageSafeMembers"] = Get-Perm $perms "manageSafeMembers"
    $finalObj["BackupSafe"] = Get-Perm $perms "backupSafe"
    $finalObj["ViewAuditLog"] = Get-Perm $perms "viewAuditLog"
    $finalObj["ViewSafeMembers"] = Get-Perm $perms "viewSafeMembers"
    $finalObj["CreateFolders"] = Get-Perm $perms "createFolders"
    $finalObj["DeleteFolders"] = Get-Perm $perms "deleteFolders"
    $finalObj["RequestsAuthorizationLevel1"] = Get-Perm $perms "requestsAuthorizationLevel1"
    $finalObj["RequestsAuthorizationLevel2"] = Get-Perm $perms "requestsAuthorizationLevel2"

    return [PSCustomObject]$finalObj
}

# =========================================================
# HELPER: Copy ordered hashtable (workaround for .Clone() issues)
# =========================================================
function Copy-OrderedHashtable {
    param([System.Collections.Specialized.OrderedDictionary]$Source)
    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) {
        $copy[$key] = $Source[$key]
    }
    return $copy
}

# =========================================================
# HELPER: Extract data from API response
# =========================================================
function Get-CACResponseData {
    <#
    .SYNOPSIS
        Standardized extraction of data from API response objects.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,
        [string[]]$PropertyNames = @("value", "Safes", "members", "accounts")
    )

    if ($null -eq $Response) { return @() }

    # Check each property name
    foreach ($prop in $PropertyNames) {
        if ($null -ne $Response.$prop) {
            return @($Response.$prop)
        }
    }

    # If response is already an array, return it
    if ($Response -is [array]) {
        return @($Response)
    }

    return @()
}

# ============================================================
# EXPORT ALL FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    Export-CACAllSafes, `
    Export-CACSafeAccountCounts, `
    Export-CACConsolidatedReport, `
    Get-CACResponseData

