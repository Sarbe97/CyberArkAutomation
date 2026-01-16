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
    <#
    .SYNOPSIS
        Export all safes from CyberArk to CSV.
    #>
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
# 2. Search Safe By Name
# =========================================================
function Search-CACSafeByName {
    <#
    .SYNOPSIS
        Search for a safe by name.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName
    )

    Write-Log "Started Search-CACSafeByName()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name to search"
            if ([string]::IsNullOrWhiteSpace($SafeName)) {
                Write-Host "Safe name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Searching for safe: $SafeName..." -ForegroundColor Cyan

        $endpoint = "/API/Safes?search=$([System.Web.HttpUtility]::UrlEncode($SafeName))"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $safes = @(Get-CACResponseData -Response $response -PropertyNames @("value", "Safes"))

        if ($safes.Count -eq 0) {
            Write-Host "No safes found matching '$SafeName'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Search Results =====" -ForegroundColor Cyan
        Write-Host "Found $($safes.Count) safe(s)"
        Write-Host ""

        $safes | ForEach-Object { Format-CACSafe -Safe $_ } | Format-Table -AutoSize

        return $safes
    }
    catch {
        Write-Log "Error in Search-CACSafeByName(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 3. Get Safe Details
# =========================================================
function Get-CACSafeDetails {
    <#
    .SYNOPSIS
        Get detailed information about a specific safe.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName
    )

    Write-Log "Started Get-CACSafeDetails()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name"
            if ([string]::IsNullOrWhiteSpace($SafeName)) {
                Write-Host "Safe name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Fetching safe details: $SafeName..." -ForegroundColor Cyan

        $safe = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))"

        if (-not $safe) {
            Write-Host "Safe not found." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Safe Details =====" -ForegroundColor Cyan
        Write-Host "Safe Name:        $($safe.safeName)"
        Write-Host "Safe Number:      $($safe.safeNumber)"
        Write-Host "Description:      $($safe.description)"
        Write-Host "Location:         $($safe.location)"
        Write-Host "Managing CPM:     $($safe.managingCPM)"
        Write-Host "Retention Days:   $($safe.numberOfDaysRetention)"
        Write-Host "OLAC Enabled:     $($safe.olacEnabled)"
        Write-Host "Auto Purge:       $($safe.autoPurgeEnabled)"
        Write-Host "Created:          $(Convert-CACTimestamp $safe.creationTime)"
        Write-Host ""

        return $safe
    }
    catch {
        Write-Log "Error in Get-CACSafeDetails(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 4. Create New Safe
# =========================================================
function New-CACSafe {
    <#
    .SYNOPSIS
        Create a new safe in CyberArk.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName,
        [string]$Description,
        [string]$ManagingCPM,
        [int]$NumberOfDaysRetention = 7
    )

    Write-Log "Started New-CACSafe()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name"
            if ([string]::IsNullOrWhiteSpace($SafeName)) {
                Write-Host "Safe name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        if ([string]::IsNullOrWhiteSpace($Description)) {
            $Description = Read-Host "Enter Description (optional)"
        }

        if ([string]::IsNullOrWhiteSpace($ManagingCPM)) {
            $ManagingCPM = Read-Host "Enter Managing CPM (optional)"
        }

        Write-Host ""
        Write-Host "===== Create Safe Confirmation =====" -ForegroundColor Yellow
        Write-Host "Safe Name:      $SafeName"
        Write-Host "Description:    $Description"
        Write-Host "Managing CPM:   $ManagingCPM"
        Write-Host "Retention Days: $NumberOfDaysRetention"
        Write-Host ""

        $confirm = Read-Host "Create this safe? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Safe creation cancelled." -ForegroundColor Yellow
            return
        }

        $body = @{
            safeName              = $SafeName
            numberOfDaysRetention = $NumberOfDaysRetention
        }

        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $body["description"] = $Description
        }
        if (-not [string]::IsNullOrWhiteSpace($ManagingCPM)) {
            $body["managingCPM"] = $ManagingCPM
        }

        Write-Host "Creating safe..." -ForegroundColor Cyan
        $result = Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes" -Body $body

        Write-Log "Safe created successfully: $SafeName" "SUCCESS"
        Write-Host "Safe created successfully!" -ForegroundColor Green

        return $result
    }
    catch {
        Write-Log "Error in New-CACSafe(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 5. Get Safe Members (with pagination)
# =========================================================
function Get-CACSafeMembers {
    <#
    .SYNOPSIS
        Get members of a safe with their permissions.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName
    )

    Write-Log "Started Get-CACSafeMembers()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name"
            if ([string]::IsNullOrWhiteSpace($SafeName)) {
                Write-Host "Safe name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Fetching members for safe: $SafeName..." -ForegroundColor Cyan

        $allMembers = [System.Collections.Generic.List[PSObject]]::new()
        $offset = 0
        $limit = 100

        do {
            $endpoint = "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))/Members?limit=$limit&offset=$offset"
            $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

            $members = @(Get-CACResponseData -Response $response -PropertyNames @("value", "members"))
            
            if ($members.Count -eq 0) { break }
            
            foreach ($member in $members) {
                $allMembers.Add($member)
            }
            
            $offset += $limit
        } while ($members.Count -ge $limit)

        if ($allMembers.Count -eq 0) {
            Write-Host "No members found for safe '$SafeName'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Members of '$SafeName' =====" -ForegroundColor Cyan
        Write-Host "Total Members: $($allMembers.Count)"
        Write-Host ""

        $allMembers | ForEach-Object {
            [PSCustomObject]@{
                MemberName   = $_.memberName
                MemberType   = $_.memberType
                IsPredefined = $_.isPredefinedUser
            }
        } | Format-Table -AutoSize

        return $allMembers.ToArray()
    }
    catch {
        Write-Log "Error in Get-CACSafeMembers(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 6. Add Safe Member (Interactive - uses config permissions)
# =========================================================
function Add-CACSafeMember {
    <#
    .SYNOPSIS
        Add a member to a safe with specified permissions.
    .DESCRIPTION
        Interactive function to add a single member. For batch operations, use Import-CACSafeMembers.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName,
        [string]$MemberName,
        [ValidateSet("User", "Group")]
        [string]$MemberType = "User",
        [string]$PermissionSet,
        [string]$SearchIn
    )

    Write-Log "Started Add-CACSafeMember()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name"
        }
        if ([string]::IsNullOrWhiteSpace($MemberName)) {
            $MemberName = Read-Host "Enter Member Name (User or Group)"
        }

        # Get available permission sets from config
        $availableSets = Get-CACAvailablePermissionSets
        if ($availableSets.Count -eq 0) {
            Write-Host "No permission sets defined in config.json!" -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "Available Permission Sets:" -ForegroundColor Cyan
        $availableSets | ForEach-Object { Write-Host "  - $_" }
        Write-Host ""

        if ([string]::IsNullOrWhiteSpace($PermissionSet)) {
            $PermissionSet = Read-Host "Enter Permission Set name"
        }

        # Validate permission set exists
        if ($PermissionSet -notin $availableSets) {
            Write-Host "Invalid permission set: $PermissionSet" -ForegroundColor Red
            return
        }

        # Get permissions from config
        $permissions = Get-CACPermissionSet -SetName $PermissionSet
        if ($null -eq $permissions) {
            Write-Host "Failed to load permissions for set: $PermissionSet" -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "===== Add Member Confirmation =====" -ForegroundColor Yellow
        Write-Host "Safe:           $SafeName"
        Write-Host "Member:         $MemberName"
        Write-Host "Member Type:    $MemberType"
        Write-Host "Permission Set: $PermissionSet"
        Write-Host ""

        $confirm = Read-Host "Add this member? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }

        $body = @{
            memberName  = $MemberName
            memberType  = $MemberType
            permissions = $permissions
        }

        # Add searchIn for groups if specified
        if ($MemberType -eq "Group" -and -not [string]::IsNullOrWhiteSpace($SearchIn)) {
            $body["searchIn"] = $SearchIn
        }

        Write-Host "Adding member..." -ForegroundColor Cyan
        $result = Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))/Members" -Body $body

        Write-Log "Member added successfully: $MemberName to $SafeName" "SUCCESS"
        Write-Host "Member added successfully!" -ForegroundColor Green

        return $result
    }
    catch {
        Write-Log "Error in Add-CACSafeMember(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 7. Import Safe Members from CSV (Batch operation)
# =========================================================
function Import-CACSafeMembers {
    <#
    .SYNOPSIS
        Batch add safe members from CSV file.
    .DESCRIPTION
        CSV should have columns: SafeName, MemberName, MemberType, PermissionSet, SearchIn (optional)
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Import-CACSafeMembers()" "DEBUG"

    Write-Host "=== Import Safe Members from CSV ===" -ForegroundColor Cyan
    Write-Host "Required columns: SafeName, MemberName, MemberType, PermissionSet"
    Write-Host "Optional columns: SearchIn (Vault/Domain - for groups)"
    Write-Host ""

    $csvPath = Read-Host "Enter CSV Path"
    if (!(Test-Path $csvPath)) { 
        Write-Host "File not found!" -ForegroundColor Red
        return 
    }

    $csvData = Import-Csv $csvPath
    if ($csvData.Count -eq 0) {
        Write-Host "CSV file is empty." -ForegroundColor Yellow
        return
    }

    # Validate required columns
    $requiredCols = @("SafeName", "MemberName", "MemberType", "PermissionSet")
    foreach ($col in $requiredCols) {
        if ($col -notin $csvData[0].PSObject.Properties.Name) {
            Write-Host "Missing required column: $col" -ForegroundColor Red
            return
        }
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $i = 0
    $total = $csvData.Count

    foreach ($row in $csvData) {
        $i++
        Write-Progress -Activity "Importing Members" -Status "Processing $i/$total : $($row.MemberName)" -PercentComplete (($i / $total) * 100)
        
        $safeName = $row.SafeName.Trim()
        $memberName = $row.MemberName.Trim()
        $memberType = $row.MemberType.Trim()
        $permSetName = $row.PermissionSet.Trim()
        $searchIn = if ($row.PSObject.Properties.Match("SearchIn")) { $row.SearchIn.Trim() } else { "" }

        try {
            # Get permissions from config
            $permissions = Get-CACPermissionSet -SetName $permSetName
            if ($null -eq $permissions) {
                throw "Permission set '$permSetName' not found in config"
            }

            $body = @{
                memberName  = $memberName
                memberType  = $memberType
                permissions = $permissions
            }

            # Add searchIn for groups
            if ($memberType -eq "Group" -and -not [string]::IsNullOrWhiteSpace($searchIn)) {
                $body["searchIn"] = $searchIn
            }

            $null = Invoke-CACAPIRequest -Method POST -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members" -Body $body

            $results.Add([PSCustomObject]@{
                    SafeName      = $safeName
                    MemberName    = $memberName
                    MemberType    = $memberType
                    PermissionSet = $permSetName
                    Status        = "SUCCESS"
                    Message       = ""
                })
            Write-Log "Added $memberName to $safeName" "SUCCESS"
        }
        catch {
            $results.Add([PSCustomObject]@{
                    SafeName      = $safeName
                    MemberName    = $memberName
                    MemberType    = $memberType
                    PermissionSet = $permSetName
                    Status        = "ERROR"
                    Message       = $_.Exception.Message
                })
            Write-Log "Failed to add $memberName to safe $safeName : $($_.Exception.Message)" "ERROR"
        }
    }

    Write-Progress -Activity "Importing Members" -Completed

    # Generate report
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputDir = Get-CACOutputDir
    $outFile = "$outputDir/Import_SafeMembers_Report_$timestamp.csv"
    $results | Export-Csv $outFile -NoTypeInformation -Encoding UTF8

    $successCount = ($results | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count

    Write-Host ""
    Write-Host "===== Import Complete =====" -ForegroundColor Cyan
    Write-Host "Total Processed: $($results.Count)"
    Write-Host "Successful:      $successCount" -ForegroundColor Green
    Write-Host "Errors:          $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
    Write-Host "Report:          $outFile"
}

# =========================================================
# 8. Export Safe Account Counts
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

    if ($reqMembers -eq 'y') {
        $reqSafeAttrs = Read-Host "2. Include Safe Attributes in Report? (y/n)"
        $reqPerms = Read-Host "3. Include Permission Details? (y/n)"
        
        if ($reqPerms -ne 'y') {
            $reqDetailUsers = Read-Host "4. Detailed User Information Required? (y/n)"
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
                        $row["UserName"] = "EMPTY/NO MEMBERS"
                         
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
                    $gUsers = Get-CACGroupUsers -GroupName $m.memberName
                    if ($gUsers) {
                        $row["SafeUsers"] = ($gUsers.UserName -join ";")
                    }
                    else {
                        $row["SafeUsers"] = "EMPTY_GROUP"
                    }
                }
                else {
                    # Singular User
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
    Search-CACSafeByName, `
    Get-CACSafeDetails, `
    New-CACSafe, `
    Get-CACSafeMembers, `
    Add-CACSafeMember, `
    Import-CACSafeMembers, `
    Export-CACSafeAccountCounts, `
    Export-CACConsolidatedReport, `
    Get-CACResponseData

