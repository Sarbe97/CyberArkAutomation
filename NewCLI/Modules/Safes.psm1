# ============================================================================
# MODULE: Safes.psm1
# DESCRIPTION: Safe Management using raw CyberArk REST API
# NOTE: Uses Format-CACSafe and New-CACSafeMemberRow from Models.psm1
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
            
            $safesChunk = $null
            if ($null -ne $response.value) { $safesChunk = $response.value }
            elseif ($null -ne $response.Safes) { $safesChunk = $response.Safes }

            if (-not $safesChunk -or $safesChunk.Count -eq 0) { break }
        }
        catch { 
            Write-Log "Error fetching safes: $($_.Exception.Message)" "ERROR"
            break 
        }

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

        $safes = @()
        if ($response.value) { $safes = @($response.value) }
        elseif ($response.Safes) { $safes = @($response.Safes) }

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
# 5. Get Safe Members
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

        $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($SafeName))/Members"

        $members = @()
        if ($response.value) { $members = @($response.value) }
        elseif ($response -is [array]) { $members = @($response) }

        if ($members.Count -eq 0) {
            Write-Host "No members found for safe '$SafeName'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Members of '$SafeName' =====" -ForegroundColor Cyan
        Write-Host "Total Members: $($members.Count)"
        Write-Host ""

        $members | ForEach-Object {
            [PSCustomObject]@{
                MemberName   = $_.memberName
                MemberType   = $_.memberType
                IsPredefined = $_.isPredefinedUser
            }
        } | Format-Table -AutoSize

        return $members
    }
    catch {
        Write-Log "Error in Get-CACSafeMembers(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================================
# 6. Add Safe Member
# =========================================================
function Add-CACSafeMember {
    <#
    .SYNOPSIS
        Add a member to a safe with specified permissions.
    #>
    [CmdletBinding()]
    param(
        [string]$SafeName,
        [string]$MemberName,
        [string]$MemberType = "User",
        [string]$PermissionSet = "ReadOnly"
    )

    Write-Log "Started Add-CACSafeMember()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($SafeName)) {
            $SafeName = Read-Host "Enter Safe Name"
        }
        if ([string]::IsNullOrWhiteSpace($MemberName)) {
            $MemberName = Read-Host "Enter Member Name (User or Group)"
        }

        Write-Host "Permission Sets: ReadOnly, Full, Custom" -ForegroundColor Cyan
        $permChoice = Read-Host "Select Permission Set (default: ReadOnly)"
        if (-not [string]::IsNullOrWhiteSpace($permChoice)) {
            $PermissionSet = $permChoice
        }

        # Build permissions based on set
        $permissions = @{
            useAccounts      = $false
            retrieveAccounts = $false
            listAccounts     = $true
            viewSafeMembers  = $true
            viewAuditLog     = $true
        }

        if ($PermissionSet -eq "Full") {
            $permissions = @{
                useAccounts                            = $true
                retrieveAccounts                       = $true
                listAccounts                           = $true
                addAccounts                            = $true
                updateAccountContent                   = $true
                updateAccountProperties                = $true
                initiateCPMAccountManagementOperations = $true
                specifyNextAccountContent              = $true
                renameAccounts                         = $true
                deleteAccounts                         = $true
                unlockAccounts                         = $true
                manageSafe                             = $true
                manageSafeMembers                      = $true
                viewAuditLog                           = $true
                viewSafeMembers                        = $true
                accessWithoutConfirmation              = $true
                createFolders                          = $true
                deleteFolders                          = $true
                moveAccountsAndFolders                 = $true
            }
        }

        Write-Host ""
        Write-Host "===== Add Member Confirmation =====" -ForegroundColor Yellow
        Write-Host "Safe:        $SafeName"
        Write-Host "Member:      $MemberName"
        Write-Host "Permissions: $PermissionSet"
        Write-Host ""

        $confirm = Read-Host "Add this member? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }

        $body = @{
            memberName  = $MemberName
            permissions = $permissions
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
# 7. Export Safe Account Counts
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

    $results = @()
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
            catch {}

            $results += [PSCustomObject]@{ 
                SafeName     = $safeName
                AccountCount = $accountCount
                Description  = $safe.description
                ManagingCPM  = $safe.managingCPM
            }
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "WARN"
            $results += [PSCustomObject]@{ 
                SafeName     = $safeName
                AccountCount = "ERROR"
                Description  = $_.Exception.Message
                ManagingCPM  = ""
            }
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
# 8. Export Safe Members with Permissions
# =========================================================
function Export-CACSafeMembersReport {
    <#
    .SYNOPSIS
        Export safe members with full permission details.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeMembersReport()" "DEBUG"

    # Input selection
    Write-Host "=== Safe Members Report ===" -ForegroundColor Cyan
    Write-Host "1. Single Safe"
    Write-Host "2. CSV Input (Header: SafeName)"
    $mode = Read-Host "Select Input Mode"

    $safesInput = @()
    $outPathBase = Get-CACOutputDir

    if ($mode -eq '1') {
        $safeName = Read-Host "Enter Safe Name"
        if (-not [string]::IsNullOrWhiteSpace($safeName)) {
            $safesInput = @($safeName)
        }
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

    $results = @()
    $i = 0
    $total = $safesInput.Count

    foreach ($safeName in $safesInput) {
        $i++
        Write-Progress -Activity "Generating Report" -Status "Processing $i/$total : $safeName" -PercentComplete (($i / $total) * 100)
        Write-Log "Processing Safe: $safeName" "INFO"

        try {
            # Fetch members with permissions
            $response = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Safes/$([System.Web.HttpUtility]::UrlEncode($safeName))/Members"
            
            $members = @()
            if ($response.value) { $members = @($response.value) }
            elseif ($response -is [array]) { $members = @($response) }

            if ($members.Count -eq 0) {
                $results += [PSCustomObject]@{ SafeName = $safeName; MemberName = "NO MEMBERS"; MemberType = "" }
                continue
            }

            foreach ($member in $members) {
                $results += New-CACSafeMemberRow -SafeName $safeName -Member $member
            }
        }
        catch {
            Write-Log "Error processing $safeName : $($_.Exception.Message)" "ERROR"
            $results += [PSCustomObject]@{ SafeName = $safeName; MemberName = "ERROR"; MemberType = $_.Exception.Message }
        }
    }
    Write-Progress -Activity "Generating Report" -Completed

    if ($results.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outFile = "$outPathBase/Safe_Members_Report_$timestamp.csv"
        $results | Export-Csv $outFile -NoTypeInformation -Encoding UTF8
        
        Write-Host "Report Generated: $outFile" -ForegroundColor Green
        Write-Log "Exported $($results.Count) rows to $outFile" "SUCCESS"
    }
    else {
        Write-Host "No data found." -ForegroundColor Yellow
    }
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
    Export-CACSafeAccountCounts, `
    Export-CACSafeMembersReport
