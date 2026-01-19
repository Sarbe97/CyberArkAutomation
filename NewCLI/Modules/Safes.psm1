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

    # --- INPUT SELECTION ---
    Write-Host "=== Safe Export Wizard ===" -ForegroundColor Cyan
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
        $outPathBase = Split-Path $csvPath -Parent
    }
    else { return }

    if ($safesInput.Count -eq 0) {
        Write-Host "No safes to process." -ForegroundColor Yellow
        return
    }

    # --- LOGIC PROMPTS ---
    Write-Host ""
    $reqMembers = Read-Host "1. Include Member Details? (y/n)"
    
    $reqSafeAttrs = 'n'
    $reqPerms = 'n'
    $reqDetailUsers = 'n'
    $includeDefaultGroupUsers = 'n'

    # Get default groups from config
    $defaultGroups = Get-CACDefaultGroups

    if ($reqMembers -eq 'y') {
        $reqSafeAttrs = Read-Host "2. Include Safe Attributes in Report? (y/n)"
        $reqPerms = Read-Host "3. Include Permission Details? (y/n)"
        
        if ($reqPerms -ne 'y') {
            $reqDetailUsers = Read-Host "4. Detailed User Information Required? (y/n)"
        }

        # Show default groups prompt if user details are being fetched
        if ($reqDetailUsers -eq 'y' -or $reqPerms -ne 'y') {
            if ($defaultGroups.Count -gt 0) {
                Write-Host ""
                Write-Host "--- Default Groups (from config.json) ---" -ForegroundColor Yellow
                $defaultGroups | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
                Write-Host ""
                $includeDefaultGroupUsers = Read-Host "5. Include user details for default groups? (y/n)"
            }
        }
    }
    else {
        # Safe Attributes forced if no members requested (otherwise report is empty)
        $reqSafeAttrs = 'y' 
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $total = $safesInput.Count
    $i = 0

    # --- PROCESSING LOOP ---
    foreach ($safeName in $safesInput) {
        $i++
        Write-Progress -Activity "Generating Report" -Status "Processing Safe $i/$total : $safeName" -PercentComplete (($i / $total) * 100)
        Write-Log "Processing Safe: $safeName" "INFO"

        try {
            # 1. Fetch Safe Object (Always needed for attributes or validation)
            $safeObj = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))"
            
            # Prepare Safe Attributes Hashtable if requested
            $safePropsHash = [ordered]@{}
            if ($reqSafeAttrs -eq 'y') {
                $safePropsHash["Description"] = $safeObj.description
                $safePropsHash["Location"] = $safeObj.location
                $safePropsHash["ManagingCPM"] = $safeObj.managingCPM
                $safePropsHash["OLACEnabled"] = $safeObj.olacEnabled
                $safePropsHash["NumberOfDaysRetention"] = $safeObj.numberOfDaysRetention
                $safePropsHash["AutoPurgeEnabled"] = $safeObj.autoPurgeEnabled
            }

            # --- BRANCH 1: Safe Attributes Only (No Members) ---
            if ($reqMembers -ne 'y') {
                $row = [ordered]@{ SafeName = $safeName }
                foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                $results.Add([PSCustomObject]$row)
                continue
            }

            # Fetch Members
            $membersResponse = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members"
            $members = @(Get-CACResponseData -Response $membersResponse -PropertyNames @("value", "members"))
            
            if ($members.Count -eq 0) { 
                # Add a row indicating no members if safe attrs are requested
                $row = [ordered]@{ SafeName = $safeName; MemberInfo = "NO MEMBERS FOUND" }
                foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                $results.Add([PSCustomObject]$row)
                continue 
            }

            # --- BRANCH 2: Permissions Included ---
            if ($reqPerms -eq 'y') {
                foreach ($m in $members) {
                    # Build detailed row with permissions
                    $results.Add((New-CACSafeMemberDetailedRow -SafeName $safeName -MemberObj $m -SafeProps $safePropsHash))
                }
                continue
            }

            # --- BRANCH 3: Detailed User Info (Rows per user) ---
            if ($reqDetailUsers -eq 'y') {
                foreach ($m in $members) {
                    # Check if this is a default group that should be skipped
                    $isDefaultGroup = ($m.memberType -eq "Group") -and ($m.memberName -in $defaultGroups)
                    
                    if ($isDefaultGroup -and $includeDefaultGroupUsers -ne 'y') {
                        # Just add the group name without fetching users
                        $row = [ordered]@{ SafeName = $safeName }
                        foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                        $row["SafeMemberName"] = $m.memberName
                        $row["SafeMemberType"] = $m.memberType
                        $row["Status"] = "DefaultGroup"
                        $row["UserName"] = "(Skipped - Default Group)"
                        $results.Add([PSCustomObject]$row)
                        continue
                    }

                    # 1. Resolve Users for this member
                    $usersToProcess = @()
                    if ($m.memberType -eq "User") {
                        $usersToProcess += $m.memberName
                    }
                    elseif ($m.memberType -eq "Group") {
                        $gUsers = Get-CACGroupUsers -GroupName $m.memberName
                        if ($gUsers) { $usersToProcess += $gUsers.UserName }
                    }

                    # 2. Handle Empty Groups
                    if ($usersToProcess.Count -eq 0) {
                        $row = [ordered]@{ SafeName = $safeName }
                        foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                         
                        $row["SafeMemberName"] = $m.memberName
                        $row["SafeMemberType"] = $m.memberType
                        $row["Status"] = "Empty"
                        $row["UserName"] = "-"
                         
                        $results.Add([PSCustomObject]$row)
                        continue
                    }

                    # 3. Process Users
                    foreach ($uName in $usersToProcess) {
                        # Fetch User Details
                        $uDetails = Get-CACUserDetailsFromStore -InputValue $uName
                        
                        # Build Row from Scratch
                        $row = [ordered]@{ SafeName = $safeName }
                        foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                        
                        $row["SafeMemberName"] = $m.memberName
                        $row["SafeMemberType"] = $m.memberType
                        $row["Status"] = "HasMembers"
                        
                        if ($uDetails) {
                            $row["UserName"] = $uDetails.UserName
                            $row["FullName"] = $uDetails.FullName
                            $row["Email"] = $uDetails.Email
                            $row["Department"] = $uDetails.Department
                        }
                        else {
                            $row["UserName"] = $uName
                            $row["FullName"] = ""
                            $row["Email"] = ""
                            $row["Department"] = ""
                        }
                        
                        $results.Add([PSCustomObject]$row)
                    }
                }
                continue
            }

            # --- BRANCH 4: Group-wise User List (Row per Member/Group) ---
            foreach ($m in $members) {
                $row = [ordered]@{ SafeName = $safeName }
                foreach ($k in $safePropsHash.Keys) { $row[$k] = $safePropsHash[$k] }
                
                $row["MemberName"] = $m.memberName
                $row["MemberType"] = $m.memberType

                if ($m.memberType -eq "Group") {
                    # Check if this is a default group that should be skipped
                    $isDefaultGroup = $m.memberName -in $defaultGroups
                    
                    if ($isDefaultGroup -and $includeDefaultGroupUsers -ne 'y') {
                        $row["Status"] = "DefaultGroup"
                        $row["SafeUsers"] = "(Skipped - Default Group)"
                    }
                    else {
                        $gUsers = Get-CACGroupUsers -GroupName $m.memberName
                        if ($gUsers) {
                            $row["Status"] = "HasMembers"
                            $row["SafeUsers"] = ($gUsers.UserName -join ";")
                        }
                        else {
                            $row["Status"] = "Empty"
                            $row["SafeUsers"] = "-"
                        }
                    }
                }
                else {
                    # Singular User
                    $row["Status"] = "User"
                    $row["SafeUsers"] = $m.memberName
                }
                
                $results.Add([PSCustomObject]$row)
            }
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "ERROR"
            $row = [ordered]@{ SafeName = $safeName; Error = $_.Exception.Message }
            $results.Add([PSCustomObject]$row)
        }
    }
    Write-Progress -Activity "Generating Report" -Completed

    # --- EXPORT ---
    if ($results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outFile = "$outPathBase/Consolidated_SafeReport_$timestamp.csv"
        
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

