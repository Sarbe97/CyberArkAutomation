# ============================================================================
# MODULE: Accounts.psm1
# DESCRIPTION: Account operations using raw CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get Accounts by Search/Safe with Pagination
# ============================================================
function Get-CACAccounts {
    <#
    .SYNOPSIS
        Search for accounts by keyword, safe name, or batch CSV.
    #>
    [CmdletBinding()]
    param(
        [string]$Search,
        [string]$SafeName,
        [int]$LimitPerPage = 1000
    )

    Write-Log "Started Get-CACAccounts()" "DEBUG"
    Write-Log "Search='$Search', Safe='$SafeName', Limit=$LimitPerPage" "INFO"

    try {
        $searchQueries = @()

        # ---------- 1. BUILD QUERY LIST ----------
        if ($Search) {
            $searchQueries += [PSCustomObject]@{ Search = $Search; Safe = $null }
        }
        if ($SafeName) {
            $searchQueries += [PSCustomObject]@{ Search = $null; Safe = $SafeName }
        }

        # ---------- 2. INTERACTIVE MODE ----------
        if (-not $searchQueries) {
            Write-Host "Choose search method:" -ForegroundColor Cyan
            Write-Host "1 = Search by keyword"
            Write-Host "2 = Search by safe name"
            Write-Host "3 = Batch search from CSV"

            switch (Read-Host "Enter choice") {
                '1' {
                    $k = Read-Host "Enter search keywords"
                    if ($k) { $searchQueries += [PSCustomObject]@{ Search = $k; Safe = $null } }
                }
                '2' {
                    $s = Read-Host "Enter safe name"
                    if ($s) { $searchQueries += [PSCustomObject]@{ Search = $null; Safe = $s } }
                }
                '3' {
                    $p = Read-Host "Enter CSV path"
                    if (-not (Test-Path $p)) { throw "CSV file not found." }

                    $csvData = Import-Csv $p
                    foreach ($row in $csvData) {
                        $sVal = if ($row.Search) { $row.Search } elseif ($row.Keywords) { $row.Keywords } else { $null }
                        $safeVal = if ($row.Safe) { $row.Safe } elseif ($row.SafeName) { $row.SafeName } else { $null }

                        if ($sVal) {
                            $searchQueries += [PSCustomObject]@{ Search = $sVal; Safe = $null }
                        }
                        if ($safeVal) {
                            $searchQueries += [PSCustomObject]@{ Search = $null; Safe = $safeVal }
                        }
                    }
                }
                default { throw "Invalid selection." }
            }
        }

        if (-not $searchQueries) { throw "No valid search criteria provided." }

        # ---------- 3. PASSWORD OPTION (TEMPORARILY DISABLED) ----------
        # $retrievePassword = ((Read-Host "Retrieve passwords? (Y/N)") -match '^[Yy]$')
        # if ($retrievePassword) {
        #     Write-Log "Password retrieval enabled for all accounts." "WARN"
        # }
        $retrievePassword = $false

        # ---------- 3b. JSON OUTPUT OPTION ----------
        $exportJson = ((Read-Host "Also export raw JSON output? (Y/N)") -match '^[Yy]$')

        # ---------- 4. OUTPUT SETUP ----------
        $outputDir = Get-CACOutputDir
        $allResults = @() 
        $queryIndex = 0

        # ---------- 5. EXECUTE SEARCHES ----------
        foreach ($query in $searchQueries) {
            $queryIndex++
            $statusMsg = "Processing Query $queryIndex / $($searchQueries.Count)"
            Write-Progress -Activity "Searching Accounts" -Status $statusMsg -PercentComplete (($queryIndex / $searchQueries.Count) * 100)
            Write-Log $statusMsg "INFO"

            try {
                # Build API endpoint with query parameters
                $queryParams = @()
                if (-not [string]::IsNullOrWhiteSpace($query.Search)) { 
                    $queryParams += "search=$([System.Web.HttpUtility]::UrlEncode($query.Search))" 
                }
                if (-not [string]::IsNullOrWhiteSpace($query.Safe)) { 
                    $queryParams += "filter=safeName eq $([System.Web.HttpUtility]::UrlEncode($query.Safe))" 
                }
                if ($LimitPerPage) { 
                    $queryParams += "limit=$LimitPerPage" 
                }

                $endpoint = "/api/Accounts"
                if ($queryParams.Count -gt 0) {
                    $endpoint += "?" + ($queryParams -join "&")
                }

                Write-Log "Calling endpoint: $endpoint" "DEBUG"

                # Call API
                $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

                # Parse accounts from response
                $accounts = @()
                if ($response.value) {
                    $accounts = @($response.value)
                }
                elseif ($response -is [array]) {
                    $accounts = @($response)
                }

                if ($accounts.Count -gt 0) {
                    foreach ($acc in $accounts) {
                        $allResults += [PSCustomObject]@{
                            Query   = $query
                            Account = $acc
                            Found   = $true
                            Error   = $null
                        }
                    }
                }
                else {
                    Write-Log "No accounts found for criteria: $($query.Search) $($query.Safe)" "WARN"
                    $allResults += [PSCustomObject]@{
                        Query   = $query
                        Account = $null
                        Found   = $false
                        Error   = "No accounts found"
                    }
                }
            }
            catch {
                Write-Host "`nError in search [Search=$($query.Search), Safe=$($query.Safe)]: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "Error processing query: $($_.Exception.Message)" "ERROR"
                
                $allResults += [PSCustomObject]@{
                    Query   = $query
                    Account = $null
                    Found   = $false
                    Error   = $_.Exception.Message
                }
            }
        }
        Write-Progress -Activity "Searching Accounts" -Completed

        if ($allResults.Count -eq 0) {
            Write-Host "No results generated." -ForegroundColor Yellow
            return
        }

        # ---------- 6. FORMAT OUTPUT ----------
        $formatted = @()
        $processed = 0

        foreach ($item in $allResults) {
            $processed++
            $account = $item.Account
            $query = $item.Query
            $found = $item.Found

            if ($processed % 10 -eq 0) {
                Write-Progress -Activity "Formatting Output" -Status "$processed / $($allResults.Count)" -PercentComplete (($processed / $allResults.Count) * 100)
            }

            $inputSearch = if ($query.Search) { $query.Search } else { "N/A" }
            $inputSafe = if ($query.Safe) { $query.Safe } else { "N/A" }

            if ($found) {
                $createdStr = Convert-CACTimestamp $account.createdTime
                $modifiedStr = Convert-CACTimestamp $account.lastModifiedTime

                $row = [Ordered]@{
                    InputSearch  = $inputSearch
                    InputSafe    = $inputSafe
                    Status       = "Found"
                    AccountID    = $account.id
                    AccountName  = $account.name
                    UserName     = $account.userName
                    Address      = $account.address
                    PlatformID   = $account.platformId
                    SafeName     = $account.safeName
                    CreatedDate  = $createdStr
                    ModifiedDate = $modifiedStr
                }

                if ($retrievePassword) {
                    try {
                        $pwdResponse = Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts/$($account.id)/Password/Retrieve"
                        $row['Password'] = $pwdResponse
                    }
                    catch {
                        $row['Password'] = "ERROR: $($_.Exception.Message)"
                        Write-Log "Password fetch failed for $($account.id)" "WARN"
                    }
                }
            }
            else {
                $row = [Ordered]@{
                    InputSearch  = $inputSearch
                    InputSafe    = $inputSafe
                    Status       = if ($item.Error) { "Error: $($item.Error)" } else { "Not Found" }
                    AccountID    = ""
                    AccountName  = ""
                    UserName     = ""
                    Address      = ""
                    PlatformID   = ""
                    SafeName     = ""
                    CreatedDate  = ""
                    ModifiedDate = ""
                }
                if ($retrievePassword) { $row['Password'] = "" }
            }

            $formatted += [PSCustomObject]$row
        }
        Write-Progress -Activity "Formatting Output" -Completed

        # ---------- 7. EXPORT ----------
        $timestamp = Get-Date -Format yyyyMMdd_HHmmss
        
        # CSV Export (Always generated - mandatory for validation/error tracking)
        $csvFile = "$outputDir/accounts_Batch_Search_$($allResults.Count)_$timestamp.csv"
        $formatted | Export-Csv $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log "CSV Export successful: $csvFile" "SUCCESS"
        Write-Host "CSV Report: $csvFile" -ForegroundColor Green

        # JSON Export (Optional - only if user confirmed)
        if ($exportJson) {
            $jsonFile = "$outputDir/accounts_Batch_Search_$($allResults.Count)_$timestamp.json"
            
            # Build raw JSON data with all account details
            $jsonData = @{
                ExportedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                TotalResults = $allResults.Count
                Accounts     = @($allResults | Where-Object { $_.Found -eq $true } | ForEach-Object { $_.Account })
                Errors       = @($allResults | Where-Object { $_.Found -eq $false } | ForEach-Object { 
                        @{
                            Query = @{ Search = $_.Query.Search; Safe = $_.Query.Safe }
                            Error = $_.Error
                        }
                    })
            }
            $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8
            Write-Log "JSON Export successful: $jsonFile" "SUCCESS"
            Write-Host "JSON Report: $jsonFile" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "Exported $($allResults.Count) rows" -ForegroundColor Cyan

        return $formatted
    }
    catch {
        Write-Log "Fatal error in Get-CACAccounts: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# ============================================================
# 2. Get Account Details by ID
# ============================================================
function Get-CACAccountById {
    <#
    .SYNOPSIS
        Get detailed account information by account ID.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID
    )

    Write-Log "Started Get-CACAccountById()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Fetching account details for ID: $AccountID" "INFO"

        $account = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID"

        if (-not $account) {
            Write-Log "Account not found for ID: $AccountID" "WARN"
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Log "Account retrieved successfully: $($account.name)" "INFO"

        # Display to console
        Write-Host "===== Account Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Account ID:                $($account.id)"
        Write-Host "Account Name:              $($account.name)"
        Write-Host "User Name:                 $($account.userName)"
        Write-Host "Address:                   $($account.address)"
        Write-Host "Platform ID:               $($account.platformId)"
        Write-Host "Safe Name:                 $($account.safeName)"
        Write-Host "Policy ID:                 $($account.policyId)"
        Write-Host "Automatic Management:      $($account.secretManagement.automaticManagementEnabled)"
        Write-Host "Manual Management Reason:  $($account.secretManagement.manualManagementReason)"
        Write-Host "Created Date:              $(Convert-CACTimestamp $account.createdTime)"
        Write-Host "Last Modified Date:        $(Convert-CACTimestamp $account.lastModifiedTime)"
        Write-Host ""

        Write-Log "Completed Get-CACAccountById()" "DEBUG"
        return $account
    }
    catch {
        Write-Log "Error in Get-CACAccountById(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 3. Get Account Activity
# ============================================================
function Get-CACAccountActivity {
    <#
    .SYNOPSIS
        Get activity log for an account.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID,
        [switch]$AutoExport
    )

    Write-Log "Started Get-CACAccountActivity()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Fetching account activity for ID: $AccountID" "INFO"

        $response = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID/Activities"

        $activities = @()
        if ($response.value) {
            $activities = @($response.value)
        }
        elseif ($response -is [array]) {
            $activities = @($response)
        }

        if (-not $activities -or $activities.Count -eq 0) {
            Write-Log "No activities found for account: $AccountID" "WARN"
            Write-Host "No account activity found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($activities.Count) activity records" "INFO"

        # Display to console
        Write-Host "===== Account Activity for $AccountID =====" -ForegroundColor Cyan
        Write-Host ""

        $formattedActivities = $activities | ForEach-Object {
            [PSCustomObject]@{
                Time        = Convert-CACTimestamp $_.Time
                Activity    = $_.Activity
                UserName    = $_.UserName
                AccountName = $_.AccountName
            }
        }

        $formattedActivities | Format-Table -AutoSize

        # Export option
        $exportChoice = if ($AutoExport) { "y" } else { (Read-Host "`nExport to CSV? (Y/N)") }

        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/account_activity_${AccountID}_$timestamp.csv"

            Write-Log "Exporting activity to CSV: $outputFile" "INFO"
            $formattedActivities | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "Activity export successful: $outputFile" "SUCCESS"
            Write-Host "Activity exported to: $outputFile" -ForegroundColor Green
        }

        Write-Log "Completed Get-CACAccountActivity()" "DEBUG"
        return $formattedActivities
    }
    catch {
        Write-Log "Error in Get-CACAccountActivity(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 4. Reconcile Account Credentials
# ============================================================
function Invoke-CACAccountReconcile {
    <#
    .SYNOPSIS
        Trigger CPM reconcile for an account.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID
    )

    Write-Log "Started Invoke-CACAccountReconcile()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID to reconcile"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Preparing to reconcile account: $AccountID" "INFO"

        # Get account details for confirmation
        try {
            $account = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID"
            if (-not $account) {
                Write-Log "Account not found for ID: $AccountID" "WARN"
                Write-Host "Account not found." -ForegroundColor Yellow
                return
            }
        }
        catch {
            Write-Log "Error retrieving account details: $($_.Exception.Message)" "ERROR"
            Write-Host "Error retrieving account: $($_.Exception.Message)" -ForegroundColor Red
            return
        }

        Write-Host "===== Reconcile Confirmation =====" -ForegroundColor Yellow
        Write-Host "Account ID: $AccountID"
        Write-Host "Account Name: $($account.name)"
        Write-Host "User Name: $($account.userName)"
        Write-Host "Address: $($account.address)"
        Write-Host ""

        $confirm = Read-Host "Proceed with reconcile? (Y/N)"

        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Log "Reconcile cancelled by user" "INFO"
            Write-Host "Reconcile cancelled." -ForegroundColor Yellow
            return
        }

        Write-Log "User confirmed; initiating reconcile for account: $AccountID" "DEBUG"
        Write-Host "Initiating reconcile..." -ForegroundColor Cyan

        # Call reconcile API
        $result = Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts/$AccountID/Reconcile"

        Write-Log "Reconcile initiated successfully" "SUCCESS"
        Write-Host "Reconcile initiated successfully!" -ForegroundColor Green

        Write-Log "Completed Invoke-CACAccountReconcile()" "DEBUG"
    }
    catch {
        Write-Log "Error in Invoke-CACAccountReconcile(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 5. Change Account Password
# ============================================================
function Invoke-CACAccountChange {
    <#
    .SYNOPSIS
        Trigger CPM password change for an account.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID
    )

    Write-Log "Started Invoke-CACAccountChange()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID to change password"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        # Get account details for confirmation
        $account = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID"
        if (-not $account) {
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Host "===== Change Password Confirmation =====" -ForegroundColor Yellow
        Write-Host "Account ID: $AccountID"
        Write-Host "Account Name: $($account.name)"
        Write-Host "User Name: $($account.userName)"
        Write-Host ""

        $confirm = Read-Host "Proceed with password change? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Password change cancelled." -ForegroundColor Yellow
            return
        }

        Write-Host "Initiating password change..." -ForegroundColor Cyan
        Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts/$AccountID/Change"

        Write-Log "Password change initiated for account: $AccountID" "SUCCESS"
        Write-Host "Password change initiated successfully!" -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Invoke-CACAccountChange(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 6. Verify Account Password
# ============================================================
function Invoke-CACAccountVerify {
    <#
    .SYNOPSIS
        Trigger CPM password verification for an account.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID
    )

    Write-Log "Started Invoke-CACAccountVerify()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID to verify"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        # Get account details for confirmation
        $account = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID"
        if (-not $account) {
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Host "===== Verify Password Confirmation =====" -ForegroundColor Yellow
        Write-Host "Account ID: $AccountID"
        Write-Host "Account Name: $($account.name)"
        Write-Host ""

        $confirm = Read-Host "Proceed with password verification? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Verification cancelled." -ForegroundColor Yellow
            return
        }

        Write-Host "Initiating password verification..." -ForegroundColor Cyan
        Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts/$AccountID/Verify"

        Write-Log "Password verification initiated for account: $AccountID" "SUCCESS"
        Write-Host "Password verification initiated successfully!" -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Invoke-CACAccountVerify(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 7. Add New Account
# ============================================================
function New-CACAccount {
   
    [CmdletBinding()]
    param(
        [string]$SafeName,
        [string]$PlatformID,
        [string]$Address,
        [string]$UserName,
        [string]$Password,
        [string]$Name
    )

    Write-Log "Started New-CACAccount()" "DEBUG"

    try {
        # Prompt for required fields if not provided
        if ([string]::IsNullOrWhiteSpace($SafeName)) { $SafeName = Read-Host "Safe Name" }
        if ([string]::IsNullOrWhiteSpace($PlatformID)) { $PlatformID = Read-Host "Platform ID" }
        if ([string]::IsNullOrWhiteSpace($Address)) { $Address = Read-Host "Address" }
        if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = Read-Host "User Name" }
        if ([string]::IsNullOrWhiteSpace($Password)) { $Password = Read-Host "Password (leave blank for no password)" }
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "$UserName@$Address" }

        # Validate required fields
        if ([string]::IsNullOrWhiteSpace($SafeName)) { throw "SafeName is required" }
        if ([string]::IsNullOrWhiteSpace($PlatformID)) { throw "PlatformID is required" }
        if ([string]::IsNullOrWhiteSpace($Address)) { throw "Address is required" }
        if ([string]::IsNullOrWhiteSpace($UserName)) { throw "UserName is required" }

        Write-Host "===== Create Account Confirmation =====" -ForegroundColor Yellow
        Write-Host "Safe Name:    $SafeName"
        Write-Host "Platform ID:  $PlatformID"
        Write-Host "Address:      $Address"
        Write-Host "User Name:    $UserName"
        Write-Host "Account Name: $Name"
        Write-Host ""

        $confirm = Read-Host "Create this account? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Account creation cancelled." -ForegroundColor Yellow
            return
        }

        # Build account object
        $accountBody = @{
            safeName   = $SafeName
            platformId = $PlatformID
            name       = $Name
            address    = $Address
            userName   = $UserName
        }

        if (-not [string]::IsNullOrWhiteSpace($Password)) {
            $accountBody["secret"] = $Password
        }

        Write-Host "Creating account..." -ForegroundColor Cyan
        $result = Invoke-CACAPIRequest -Method POST -Endpoint "/api/Accounts" -Body $accountBody

        Write-Log "Account created successfully: $($result.id)" "SUCCESS"
        Write-Host "Account created successfully! ID: $($result.id)" -ForegroundColor Green

        return $result
    }
    catch {
        Write-Log "Error in New-CACAccount(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 8. Remove Account by ID
# ============================================================
function Remove-CACAccount {
    <#
    .SYNOPSIS
        Delete an account from CyberArk.
    #>
    [CmdletBinding()]
    param(
        [string]$AccountID
    )

    Write-Log "Started Remove-CACAccount()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID to delete"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        # Get account details for confirmation
        try {
            $account = Invoke-CACAPIRequest -Method GET -Endpoint "/api/Accounts/$AccountID"
            if (-not $account) {
                Write-Host "Account not found." -ForegroundColor Yellow
                return
            }
        }
        catch {
            Write-Host "Error retrieving account: $($_.Exception.Message)" -ForegroundColor Red
            return
        }

        Write-Host "===== Delete Confirmation =====" -ForegroundColor Red
        Write-Host "Account ID:   $AccountID"
        Write-Host "Account Name: $($account.name)"
        Write-Host "Safe:         $($account.safeName)"
        Write-Host "Username:     $($account.userName)"
        Write-Host ""
        Write-Host "WARNING: This action cannot be undone." -ForegroundColor Red

        $confirm = Read-Host "Are you sure you want to PERMANENTLY DELETE this account? (Y/N)"

        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Log "Delete cancelled by user" "INFO"
            Write-Host "Delete cancelled." -ForegroundColor Yellow
            return
        }

        Write-Log "User confirmed; deleting account: $AccountID" "WARN"

        Invoke-CACAPIRequest -Method DELETE -Endpoint "/api/Accounts/$AccountID"

        Write-Log "Account deleted successfully: $AccountID" "SUCCESS"
        Write-Host "Account deleted successfully." -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Remove-CACAccount(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 9. Batch Delete Accounts
# ============================================================
function Invoke-CACBatchAccountDeletion {
    <#
    .SYNOPSIS
        Delete multiple accounts by ID or from CSV.
    #>
    [CmdletBinding()]
    param()

    $outputDir = Get-CACOutputDir
    $OutputCsvPath = "$outputDir/BatchDeletion_Result_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    Write-Log "Started Invoke-CACBatchAccountDeletion()" "DEBUG"

    $itemsToProcess = @()
    $Id = $null
    $CsvPath = $null

    # Interactive mode
    Write-Host "Select Deletion Mode:" -ForegroundColor Cyan
    Write-Host "1. Single Account ID"
    Write-Host "2. Batch CSV File"
    
    $mode = Read-Host "Mode (1/2)"
    if ($mode -eq '1') {
        $val = Read-Host "Enter Account ID"
        if (-not [string]::IsNullOrWhiteSpace($val)) { $Id = $val }
    }
    elseif ($mode -eq '2') {
        $val = Read-Host "Enter CSV Path"
        if (-not [string]::IsNullOrWhiteSpace($val)) { $CsvPath = $val }
    }
    else {
        Write-Warning "Invalid selection."
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        Write-Log "Processing single ID: $Id" "INFO"
        $itemsToProcess += [PSCustomObject]@{
            id            = $Id
            ProcessSource = "ManualInput"
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        if (-not (Test-Path $CsvPath)) {
            Write-Error "CSV file not found: $CsvPath"
            return
        }
        Write-Log "Processing CSV: $CsvPath" "INFO"
        $itemsToProcess = Import-Csv $CsvPath
    }
    else {
        Write-Error "No valid ID or CSV path provided."
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Warning "No items to process."
        return
    }

    # Process deletions
    $results = @()
    $total = $itemsToProcess.Count
    $current = 0

    foreach ($item in $itemsToProcess) {
        $current++
        $resObj = $item | Select-Object *
        
        $idVal = if ($item.PSObject.Properties['AccountID']) { $item.AccountID } elseif ($item.PSObject.Properties['id']) { $item.id } else { $null }

        if (-not $idVal) {
            Write-Host "Row $current : Missing 'id' column. Skipping." -ForegroundColor Yellow
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Skipped" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Missing 'id' column" -Force
            $results += $resObj
            continue
        }

        Write-Progress -Activity "Deleting Accounts (Batch)" -Status "Processing: $idVal" -PercentComplete (($current / $total) * 100)
        Write-Host "[$current/$total] Deleting Account ID: $idVal ... " -NoNewline

        try {
            Invoke-CACAPIRequest -Method DELETE -Endpoint "/api/Accounts/$idVal"
            
            Write-Host "Success" -ForegroundColor Green
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Success" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Deleted" -Force
            Write-Log "Deleted Account: $idVal" "SUCCESS"
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "Failed ($errMsg)" -ForegroundColor Red
            
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Failed" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value $errMsg -Force
            Write-Log "Failed to delete $idVal : $errMsg" "ERROR"
        }

        $results += $resObj
    }
    Write-Progress -Activity "Deleting Accounts (Batch)" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch Deletion Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Batch Deletion Complete. Results saved to $OutputCsvPath" "INFO"
}

# ============================================================
# 10. PSM Connect
# ============================================================
function Invoke-CACPSMConnect {
    <#
    .SYNOPSIS
        Connect to an account via PSM (Privileged Session Manager).
    .DESCRIPTION
        Initiates a PSM connection to the specified account.
        Returns an RDP file that can be launched for connection.
    #>
    [CmdletBinding()]
    param()

    Write-Log "Started Invoke-CACPSMConnect()" "DEBUG"

    try {
        $accountId = Read-Host "Enter Account ID"
        if ([string]::IsNullOrWhiteSpace($accountId)) {
            Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
            return
        }

        # Get account details for confirmation
        Write-Host "Fetching account details..." -ForegroundColor Cyan
        $account = Invoke-CACAPIRequest -Method GET -Endpoint "/API/Accounts/$accountId"
        
        if (-not $account) {
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== PSM Connect =====" -ForegroundColor Cyan
        Write-Host "Account ID:   $accountId"
        Write-Host "Account Name: $($account.name)"
        Write-Host "User Name:    $($account.userName)"
        Write-Host "Address:      $($account.address)"
        Write-Host "Platform:     $($account.platformId)"
        Write-Host ""

        # Optional parameters
        $reason = Read-Host "Enter reason for connection (optional)"
        $connectionComponent = Read-Host "Enter Connection Component ID (optional, press Enter for default)"

        # Build body
        $body = @{}
        
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            $body["reason"] = $reason
        }
        if (-not [string]::IsNullOrWhiteSpace($connectionComponent)) {
            $body["ConnectionComponent"] = $connectionComponent
        }

        Write-Host ""
        $confirm = Read-Host "Initiate PSM connection? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Connection cancelled." -ForegroundColor Yellow
            return
        }

        Write-Host "Initiating PSM connection..." -ForegroundColor Cyan

        # Call PSM Connect API
        $session = Get-CACSession
        $endpoint = "/API/Accounts/$accountId/PSMConnect/"
        $connectUrl = "$($session.BaseURI)$endpoint"

        # Request RDP file
        $headers = @{
            "Authorization" = $session.Token
            "Content-Type"  = "application/json"
            "Accept"        = "* / *"
        }

        $response = Invoke-WebRequest -Uri $connectUrl -Method POST -Headers $headers -Body ($body | ConvertTo-Json) -UseBasicParsing

        # Check response type
        $contentType = $response.Headers["Content-Type"]
        
        if ($contentType -like "*application/octet-stream*" -or $contentType -like "*application/rdp*") {
            # Save as RDP file
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $rdpFile = "$outputDir/PSMConnect_${accountId}_$timestamp.rdp"
            
            [System.IO.File]::WriteAllBytes($rdpFile, $response.Content)
            
            Write-Log "RDP file saved: $rdpFile" "SUCCESS"
            Write-Host ""
            Write-Host "RDP file saved: $rdpFile" -ForegroundColor Green
            Write-Host ""
            
            $launchChoice = Read-Host "Launch RDP connection now? (Y/N)"
            if ($launchChoice -eq 'Y' -or $launchChoice -eq 'y') {
                Start-Process $rdpFile
                Write-Host "RDP connection launched." -ForegroundColor Green
            }
        }
        else {
            # JSON response (possibly HTML5 gateway)
            $jsonResponse = $response.Content | ConvertFrom-Json
            
            if ($jsonResponse.PSMGWURL) {
                Write-Host ""
                Write-Host "HTML5 Gateway URL: $($jsonResponse.PSMGWURL)" -ForegroundColor Cyan
                Write-Host ""
                
                $openChoice = Read-Host "Open in browser? (Y/N)"
                if ($openChoice -eq 'Y' -or $openChoice -eq 'y') {
                    Start-Process $jsonResponse.PSMGWURL
                }
            }
            else {
                Write-Host "Connection response received." -ForegroundColor Green
                $jsonResponse | ConvertTo-Json | Write-Host
            }
        }

        Write-Log "PSM Connect completed for account: $accountId" "SUCCESS"
    }
    catch {
        Write-Log "Error in Invoke-CACPSMConnect(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 11. Batch Account Onboarding
# ============================================================
function Invoke-CACBatchAccountOnboarding {
    <#
    .SYNOPSIS
        Onboard multiple accounts to CyberArk from a CSV file.
    .DESCRIPTION
        Reads account details from CSV and creates accounts via REST API.
        Required CSV columns: SafeName, PlatformId, Address, UserName
        Optional CSV columns: Name, Password (secret)
        Output CSV includes all input columns plus OnboardingStatus and Message.
    #>
    [CmdletBinding()]
    param()

    $outputDir = Get-CACOutputDir
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputCsvPath = "$outputDir/AccountOnboarding_Result_$timestamp.csv"

    Write-Log "Started Invoke-CACBatchAccountOnboarding()" "DEBUG"

    # Prompt for CSV path
    Write-Host "===== Batch Account Onboarding =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Required CSV columns: SafeName, PlatformId, Address, UserName" -ForegroundColor Yellow
    Write-Host "Optional CSV columns: Name, Password" -ForegroundColor Yellow
    Write-Host ""

    $CsvPath = Read-Host "Enter CSV Path"
    
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host "CSV path cannot be empty." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV file not found: $CsvPath" -ForegroundColor Red
        return
    }

    Write-Log "Processing CSV: $CsvPath" "INFO"
    
    try {
        $itemsToProcess = Import-Csv $CsvPath
    }
    catch {
        Write-Host "Error reading CSV: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Host "No items found in CSV." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Found $($itemsToProcess.Count) account(s) to onboard." -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "Proceed with onboarding? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Onboarding cancelled." -ForegroundColor Yellow
        return
    }

    # Process onboarding
    $results = @()
    $total = $itemsToProcess.Count
    $current = 0
    $successCount = 0
    $failCount = 0

    foreach ($item in $itemsToProcess) {
        $current++
        $resObj = $item | Select-Object *

        # Get required fields
        $safeName = $item.SafeName
        $platformId = $item.PlatformId
        $address = $item.Address
        $userName = $item.UserName
        
        # Get optional fields
        $name = if ($item.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($item.Name)) { 
            $item.Name 
        }
        else { 
            "$userName@$address" 
        }
        $password = if ($item.PSObject.Properties['Password']) { $item.Password } else { $null }

        # Validate required fields
        $missingFields = @()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $missingFields += "SafeName" }
        if ([string]::IsNullOrWhiteSpace($platformId)) { $missingFields += "PlatformId" }
        if ([string]::IsNullOrWhiteSpace($address)) { $missingFields += "Address" }
        if ([string]::IsNullOrWhiteSpace($userName)) { $missingFields += "UserName" }

        if ($missingFields.Count -gt 0) {
            Write-Host "[$current/$total] $userName@$address ... " -NoNewline
            Write-Host "Skipped (Missing: $($missingFields -join ', '))" -ForegroundColor Yellow
            
            $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Skipped" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Missing required fields: $($missingFields -join ', ')" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
            $results += $resObj
            $failCount++
            continue
        }

        Write-Progress -Activity "Onboarding Accounts" -Status "Processing: $name" -PercentComplete (($current / $total) * 100)
        Write-Host "[$current/$total] $name ... " -NoNewline

        try {
            # Build account body
            $accountBody = @{
                safeName   = $safeName
                platformId = $platformId
                name       = $name
                address    = $address
                userName   = $userName
            }

            # Add password if provided
            if (-not [string]::IsNullOrWhiteSpace($password)) {
                $accountBody["secret"] = $password
            }

            # Create account via API
            $result = Invoke-CACAPIRequest -Method POST -Endpoint "/API/Accounts" -Body $accountBody

            Write-Host "Success (ID: $($result.id))" -ForegroundColor Green
            
            $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Success" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Account created" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value $result.id -Force
            
            Write-Log "Account created: $name (ID: $($result.id))" "SUCCESS"
            $successCount++
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "Failed ($errMsg)" -ForegroundColor Red
            
            $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Failed" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value $errMsg -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
            
            Write-Log "Failed to create $name : $errMsg" "ERROR"
            $failCount++
        }

        $results += $resObj
    }

    Write-Progress -Activity "Onboarding Accounts" -Completed

    # Export results
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8

    # Display summary
    Write-Host ""
    Write-Host "===== Onboarding Summary =====" -ForegroundColor Cyan
    Write-Host "  Total:     $total"
    Write-Host "  Success:   $successCount" -ForegroundColor Green
    Write-Host "  Failed:    $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "White" })
    Write-Host ""
    Write-Host "Results saved to: $OutputCsvPath" -ForegroundColor Green

    Write-Log "Batch Account Onboarding Complete. Success: $successCount, Failed: $failCount. Results: $OutputCsvPath" "INFO"
}

# ============================================================
# EXPORT ALL FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    Get-CACAccounts, `
    Get-CACAccountById, `
    Get-CACAccountActivity, `
    Invoke-CACAccountReconcile, `
    Invoke-CACAccountChange, `
    Invoke-CACAccountVerify, `
    New-CACAccount, `
    Remove-CACAccount, `
    Invoke-CACBatchAccountDeletion, `
    Invoke-CACPSMConnect, `
    Invoke-CACBatchAccountOnboarding
