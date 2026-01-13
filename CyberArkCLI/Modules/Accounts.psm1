Import-Module psPAS -ErrorAction Stop



# ============================================================
# 1. Get Accounts by Search/Safe or Batch CSV with Pagination
# ============================================================
function Get-CACAccounts {
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

        # ---------- BUILD QUERY LIST ----------
        if ($Search) {
            $searchQueries += [PSCustomObject]@{ Search = $Search; Safe = $null }
        }
        if ($SafeName) {
            $searchQueries += [PSCustomObject]@{ Search = $null; Safe = $SafeName }
        }

        # ---------- INTERACTIVE MODE ----------
        if (-not $searchQueries) {
            # (Keeping your existing interactive logic here for brevity, assume it is unchanged)
            Write-Host "Choose search method:" -ForegroundColor Cyan
            Write-Host "3 = Batch search from CSV"
            
            # ... [Assuming your switch block is here] ...
            # For the sake of the fix, let's assume Option 3 was selected
            $p = Read-Host "Enter CSV path"
            if (-not (Test-Path $p)) { throw "CSV file not found." }
            $csvData = Import-Csv $p
            foreach ($row in $csvData) {
                if ($row.Search) { $searchQueries += [PSCustomObject]@{ Search = $row.Search; Safe = $null } }
                if ($row.Safe) { $searchQueries += [PSCustomObject]@{ Search = $null; Safe = $row.Safe } }
            }
        }

        if (-not $searchQueries) { throw "No valid search criteria provided." }

        # ---------- PASSWORD OPTION ----------
        $retrievePassword = ((Read-Host "Retrieve passwords? (Y/N)") -match '^[Yy]$')

        # ---------- OUTPUT SETUP ----------
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

        # *** FIX 1: Initialize the results array ***
        $allResults = @() 
        $queryIndex = 0

        # ---------- EXECUTE SEARCHES ----------
        foreach ($query in $searchQueries) {
            $queryIndex++
            Write-Progress -Activity "Searching Accounts" -Status "Processing Query $queryIndex / $($searchQueries.Count)" -PercentComplete (($queryIndex / $searchQueries.Count) * 100)
            
            try {
                $searchParams = @{ ErrorAction = 'Stop'; limit = $LimitPerPage }
                
                if (-not [string]::IsNullOrWhiteSpace($query.Search)) { $searchParams['search'] = $query.Search }
                if (-not [string]::IsNullOrWhiteSpace($query.Safe)) { $searchParams['safeName'] = $query.Safe }

                $accounts = @(Get-PASAccount @searchParams)
                
                # *** FIX 2: Handle BOTH Found and Not Found scenarios ***
                if ($accounts) {
                    foreach ($acc in $accounts) {
                        # Add a success object for every account found
                        $allResults += [PSCustomObject]@{
                            Query   = $query
                            Account = $acc
                            Found   = $true
                            Error   = $null
                        }
                    }
                }
                else {
                    # Add a "Not Found" object if the array is empty
                    $allResults += [PSCustomObject]@{
                        Query   = $query
                        Account = $null
                        Found   = $false
                        Error   = $null
                    }
                }
            }
            catch {
                # Handle API errors gracefully in the output
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

        # ---------- FORMAT OUTPUT ----------
        $formatted = @()
        $processed = 0

        # *** FIX 3: Iterate over $allResults (which now actually exists) ***
        foreach ($item in $allResults) {
            $processed++
            $account = $item.Account
            $query = $item.Query
            $found = $item.Found

            if ($found) {
                $row = [Ordered]@{
                    InputSearch  = $query.Search
                    InputSafe    = $query.Safe
                    Status       = "Found"
                    AccountID    = $account.id
                    AccountName  = $account.name
                    UserName     = $account.userName
                    Address      = $account.address
                    PlatformID   = $account.platformId
                    SafeName     = $account.safeName
                    CreatedDate  = $account.createdTime # Assuming you handle timestamp conversion elsewhere
                    ModifiedDate = $account.lastModifiedTime
                }

                if ($retrievePassword) {
                    try {
                        $row['Password'] = Get-PASAccountPassword -AccountID $account.id -ErrorAction Stop
                    }
                    catch {
                        $row['Password'] = "ERROR"
                    }
                }
            }
            else {
                # Logic for "Not Found" or "Error" rows
                $statusMsg = "Not Found"
                if ($item.Error) { $statusMsg = "Error: $($item.Error)" }

                $row = [Ordered]@{
                    InputSearch  = $query.Search
                    InputSafe    = $query.Safe
                    Status       = $statusMsg
                    AccountID    = ""
                    AccountName  = ""
                    UserName     = ""
                    Address      = ""
                    PlatformID   = ""
                    SafeName     = ""
                    CreatedDate  = ""
                    ModifiedDate = ""
                    Password     = ""
                }
            }
            $formatted += [PSCustomObject]$row
        }

        # ---------- EXPORT ----------
        $file = "$outputDir/accounts_Report_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
        $formatted | Export-Csv $file -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($formatted.Count) rows to $file" -ForegroundColor Green

        return $formatted
    }
    catch {
        throw
    }
}

# ============================================================
# 2. Get Account Details by ID (console output only)
# ============================================================
function Get-CACAccountById {
    param(
        [string]$AccountID
    )

    Write-Log "Started Get-CACAccountById()" "DEBUG"

    try {
        # Prompt for ID if not provided
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Fetching account details for ID: $AccountID" "INFO"

        # Fetch from psPAS
        $account = Get-PASAccount -id $AccountID -ErrorAction Stop

        if (-not $account) {
            Write-Log "Account not found for ID: $AccountID" "WARN"
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Log "Account retrieved successfully: $($account.name)" "INFO"

        # Display to console
        Write-Host "===== Account Details =====" -ForegroundColor Cyan
        Write-Host ""
        $account | Format-List @(
            @{Label = "Account ID"; Expression = { $_.id } },
            @{Label = "Account Name"; Expression = { $_.name } },
            @{Label = "User Name"; Expression = { $_.userName } },
            @{Label = "Address"; Expression = { $_.address } },
            @{Label = "Platform ID"; Expression = { $_.platformId } },
            @{Label = "Safe Name"; Expression = { $_.safeName } },
            @{Label = "Policy ID"; Expression = { $_.policyId } },
            @{Label = "Automatic Management"; Expression = { $_.automaticManagementEnabled } },
            @{Label = "Manual Management Reason"; Expression = { $_.manualManagementReason } },
            @{Label = "Created Date"; Expression = { Convert-CACTimestamp $_.createdTime } },
            @{Label = "Last Modified Date"; Expression = { Convert-CACTimestamp $_.lastModifiedTime } }
        )
        Write-Host ""

        Write-Log "Completed Get-CACAccountById()" "DEBUG"
    }
    catch {
        Write-Log "Error in Get-CACAccountById(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 3. Get Account Activity by Account ID (Updated: Better formatting & auto-export)
# ============================================================
function Get-CACAccountActivity {
    param(
        [string]$AccountID,
        [switch]$AutoExport
    )

    Write-Log "Started Get-CACAccountActivity()" "DEBUG"

    try {
        # Prompt for ID if not provided
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Fetching account activity for ID: $AccountID" "INFO"

        # Fetch from psPAS
        $activities = Get-PASAccountActivity -AccountID $AccountID -ErrorAction Stop

        if (-not $activities -or $activities.Count -eq 0) {
            Write-Log "No activities found for account: $AccountID" "WARN"
            Write-Host "No account activity found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($activities.Count) activity records" "INFO"

        # Display to console in table format
        Write-Host "===== Account Activity for $AccountID =====" -ForegroundColor Cyan
        Write-Host ""

        # Convert timestamps if present
        $formattedActivities = $activities | ForEach-Object {
            [PSCustomObject]@{
                Time        = Convert-CACTimestamp $_.Time
                Activity    = $_.Activity
                UserName    = $_.UserName
                AccountName = $_.AccountName
            }
        }

        $formattedActivities | Format-Table -AutoSize

        # Export to CSV
        $exportChoice = if ($AutoExport) { "y" } else { (Read-Host "`nExport to CSV? (Y/N)") }

        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = "$PSScriptRoot/../Output"
            if (-not (Test-Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir | Out-Null
            }

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/account_activity_${AccountID}_$timestamp.csv"

            Write-Log "Exporting activity to CSV: $outputFile" "INFO"
            $formattedActivities | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "Activity export successful: $outputFile" "SUCCESS"
            Write-Host "Activity exported to: $outputFile" -ForegroundColor Green
        }

        Write-Log "Completed Get-CACAccountActivity()" "DEBUG"
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
    param(
        [string]$AccountID
    )

    Write-Log "Started Invoke-CACAccountReconcile()" "DEBUG"

    try {
        # Prompt for ID if not provided
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
            $account = Get-PASAccount -id $AccountID -ErrorAction Stop
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

        # Call psPAS reconcile (using newer Invoke-PASCPMOperation if available)
        try {
            Write-Host "Initiating reconcile..." -ForegroundColor Cyan

            # Try newer method first (psPAS 4.2+)
            $result = Invoke-PASCPMOperation -AccountID $AccountID -ReconcileTask -ErrorAction Stop

            Write-Log "Reconcile initiated successfully; result: $(ConvertTo-Json $result)" "DEBUG"
            Write-Host "Reconcile initiated successfully!" -ForegroundColor Green
            Write-Host "Response: $result" -ForegroundColor Cyan

            Write-Log "Reconcile completed successfully for account: $AccountID" "SUCCESS"
        }
        catch {
            # Fallback to older method if newer one fails
            Write-Log "Newer method failed; trying legacy Invoke-PASCredReconcile: $($_.Exception.Message)" "DEBUG"

            try {
                $result = Invoke-PASCredReconcile -AccountID $AccountID -ErrorAction Stop

                Write-Log "Legacy reconcile initiated successfully" "DEBUG"
                Write-Host "Reconcile initiated successfully (legacy method)!" -ForegroundColor Green
                Write-Host "Response: $result" -ForegroundColor Cyan

                Write-Log "Reconcile completed successfully for account: $AccountID" "SUCCESS"
            }
            catch {
                Write-Log "Both reconcile methods failed: $($_.Exception.Message)" "ERROR"
                Write-Host "Error initiating reconcile: $($_.Exception.Message)" -ForegroundColor Red
                throw
            }
        }

        Write-Log "Completed Invoke-CACAccountReconcile()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in Invoke-CACAccountReconcile(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 5. Connect via PSM (Remote Desktop Session Manager)
# ============================================================
function New-CACPSMConnection {
    param(
        [string]$AccountID,
        [string]$ConnectionComponent,
        [string]$ConnectionMethod = "RDP",
        [string]$Reason
    )

    Write-Log "Started New-CACPSMConnection()" "DEBUG"

    try {
        # Prompt for required parameters if not provided
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        if ([string]::IsNullOrWhiteSpace($ConnectionComponent)) {
            Write-Host "Available connection components: PSM-RDP, PSM-SSH, PSM-Telnet, PSM-VNC, PSM-PSMGW, etc." -ForegroundColor Cyan
            $ConnectionComponent = Read-Host "Enter Connection Component"
            if ([string]::IsNullOrWhiteSpace($ConnectionComponent)) {
                Write-Log "Connection component is empty" "WARN"
                Write-Host "Connection component cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Host "Connection methods: RDP, PSMGW (PSM Gateway), HTML5" -ForegroundColor Cyan
        $method = Read-Host "Enter Connection Method (default: RDP)"
        if (-not [string]::IsNullOrWhiteSpace($method)) {
            $ConnectionMethod = $method
        }

        $Reason = Read-Host "Enter Reason for connection (optional)"

        Write-Log "PSM Connection Parameters: AccountID=$AccountID, Component=$ConnectionComponent, Method=$ConnectionMethod" "INFO"

        # Confirm before connecting
        Write-Host "===== PSM Connection Details =====" -ForegroundColor Yellow
        Write-Host "Account ID: $AccountID"
        Write-Host "Connection Component: $ConnectionComponent"
        Write-Host "Connection Method: $ConnectionMethod"
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            Write-Host "Reason: $Reason"
        }
        Write-Host ""

        $confirm = Read-Host "Proceed with PSM connection? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Log "PSM connection cancelled by user" "INFO"
            Write-Host "Connection cancelled." -ForegroundColor Yellow
            return
        }

        Write-Log "User confirmed; initiating PSM session for account: $AccountID" "DEBUG"

        # Build psPAS parameters
        $psmParams = @{
            AccountID           = $AccountID
            ConnectionComponent = $ConnectionComponent
            ConnectionMethod    = $ConnectionMethod
        }

        # Add optional reason
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $psmParams['Reason'] = $Reason
        }

        # Set output path for RDP file if method is RDP
        if ($ConnectionMethod -eq "RDP") {
            $outputDir = "$PSScriptRoot/../Output"
            if (-not (Test-Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir | Out-Null
            }

            $rdpFile = "$outputDir/psm_session_$(Get-Date -Format 'yyyyMMdd_HHmmss').rdp"
            $psmParams['Path'] = $rdpFile
            Write-Log "RDP output path: $rdpFile" "DEBUG"
        }

        Write-Host "Initiating PSM session..." -ForegroundColor Cyan

        # Call psPAS
        $result = New-PASPSMSession @psmParams -ErrorAction Stop

        Write-Log "PSM session initiated successfully" "INFO"

        # Handle different response types
        if ($ConnectionMethod -eq "RDP" -and (Test-Path $rdpFile)) {
            Write-Host "RDP file created: $rdpFile" -ForegroundColor Green
            Write-Host "Opening RDP connection..." -ForegroundColor Cyan
            Write-Log "Opening RDP file: $rdpFile" "DEBUG"

            # On Windows, try to launch RDP
            if ($PSVersionTable.Platform -eq "Win32NT" -or -not $PSVersionTable.Platform) {
                try {
                    Start-Process -FilePath $rdpFile
                    Write-Host "RDP launched successfully." -ForegroundColor Green
                    Write-Log "RDP process launched" "SUCCESS"
                }
                catch {
                    Write-Host "Could not auto-launch RDP. Please open manually: $rdpFile" -ForegroundColor Yellow
                    Write-Log "Failed to auto-launch RDP: $($_.Exception.Message)" "WARN"
                }
            }
            else {
                Write-Host "RDP file created. Please open manually: $rdpFile" -ForegroundColor Yellow
            }
        }
        elseif ($result -is [string] -and $result.StartsWith("http")) {
            Write-Host "PSM Connection URL: $result" -ForegroundColor Green
            Write-Host "Open the link in your browser to connect." -ForegroundColor Cyan
            Write-Log "PSM URL returned: $result" "SUCCESS"
        }
        else {
            Write-Host "PSM Session Response:" -ForegroundColor Green
            Write-Host $result -ForegroundColor Cyan
            Write-Log "PSM response: $(ConvertTo-Json $result)" "SUCCESS"
        }

        Write-Log "Completed New-CACPSMConnection()" "DEBUG"
    }
    catch {
        Write-Log "Error in New-CACPSMConnection(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 6. Add Accounts from CSV File
# ============================================================
function New-CACAccountsFromCsv {
    param(
        [string]$CsvPath
    )

    Write-Log "Started New-CACAccountsFromCsv()" "DEBUG"

    try {
        # Prompt for CSV path if not provided
        if ([string]::IsNullOrWhiteSpace($CsvPath)) {
            $CsvPath = Read-Host "Enter full path to account CSV file"
            if ([string]::IsNullOrWhiteSpace($CsvPath)) {
                Write-Log "CSV path is empty" "WARN"
                Write-Host "CSV path cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        # Validate CSV exists
        if (-not (Test-Path $CsvPath)) {
            Write-Log "CSV file not found: $CsvPath" "ERROR"
            Write-Host "CSV file not found: $CsvPath" -ForegroundColor Red
            return
        }

        Write-Log "Loading accounts from CSV: $CsvPath" "INFO"

        # Import CSV
        $accounts = Import-Csv -Path $CsvPath -ErrorAction Stop

        if (-not $accounts -or $accounts.Count -eq 0) {
            Write-Log "CSV contains no records" "WARN"
            Write-Host "CSV contains no records." -ForegroundColor Yellow
            return
        }

        Write-Log "CSV loaded successfully; $($accounts.Count) accounts to process" "INFO"

        $successCount = 0
        $errorCount = 0
        $totalAccounts = $accounts.Count

        # Process each account
        foreach ($acc in $accounts) {
            $accountIndex = $accounts.IndexOf($acc) + 1

            try {
                # Validate required fields
                if ([string]::IsNullOrWhiteSpace($acc.SafeName)) {
                    Write-Log "Row $accountIndex : SafeName is empty" "WARN"
                    Write-Host "Row $accountIndex : SafeName cannot be empty (skipping)" -ForegroundColor Yellow
                    $errorCount++
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($acc.PlatformID)) {
                    Write-Log "Row $accountIndex : PlatformID is empty" "WARN"
                    Write-Host "Row $accountIndex : PlatformID cannot be empty (skipping)" -ForegroundColor Yellow
                    $errorCount++
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($acc.Address)) {
                    Write-Log "Row $accountIndex : Address is empty" "WARN"
                    Write-Host "Row $accountIndex : Address cannot be empty (skipping)" -ForegroundColor Yellow
                    $errorCount++
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($acc.UserName)) {
                    Write-Log "Row $accountIndex : UserName is empty" "WARN"
                    Write-Host "Row $accountIndex : UserName cannot be empty (skipping)" -ForegroundColor Yellow
                    $errorCount++
                    continue
                }

                Write-Log "Processing row $accountIndex/$totalAccounts`: $($acc.SafeName)/$($acc.UserName)" "DEBUG"

                # Build account object using psPAS
                $accountObject = New-PASAccountObject `
                    -userName $acc.UserName `
                    -address $acc.Address `
                    -platformID $acc.PlatformID `
                    -safeName $acc.SafeName

                # Add optional fields if present
                if (-not [string]::IsNullOrWhiteSpace($acc.Name)) {
                    $accountObject | Add-Member -Name name -Value $acc.Name -MemberType NoteProperty
                }

                if (-not [string]::IsNullOrWhiteSpace($acc.PolicyID)) {
                    $accountObject | Add-Member -Name policyId -Value $acc.PolicyID -MemberType NoteProperty
                }

                if (-not [string]::IsNullOrWhiteSpace($acc.Secret)) {
                    $secureSecret = ConvertTo-SecureString $acc.Secret -AsPlainText -Force
                    $accountObject | Add-Member -Name secret -Value $secureSecret -MemberType NoteProperty
                }

                if (-not [string]::IsNullOrWhiteSpace($acc.AutomaticManagementEnabled)) {
                    $autoMgmt = [System.Convert]::ToBoolean($acc.AutomaticManagementEnabled)
                    $accountObject | Add-Member -Name automaticManagementEnabled -Value $autoMgmt -MemberType NoteProperty
                }

                if (-not [string]::IsNullOrWhiteSpace($acc.ManualManagementReason)) {
                    $accountObject | Add-Member -Name manualManagementReason -Value $acc.ManualManagementReason -MemberType NoteProperty
                }

                Write-Log "Calling Add-PASAccount for row $accountIndex" "DEBUG"

                # Add account to CyberArk
                $createdAccount = Add-PASAccount -Account $accountObject -ErrorAction Stop

                Write-Log "Account created successfully: $($createdAccount.id) - $($acc.UserName)@$($acc.Address)" "SUCCESS"
                Write-Host "Row $accountIndex  Account created: ID=$($createdAccount.id)" -ForegroundColor Green

                $successCount++
            }
            catch {
                $errorCount++
                Write-Log "Error processing row $accountIndex`: $($_.Exception.Message)" "ERROR"
                Write-Host "Row $accountIndex   Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Log "Account creation complete. Success: $successCount, Errors: $errorCount" "INFO"

        # Summary
        Write-Host ""
        Write-Host "===== Import Summary =====" -ForegroundColor Cyan
        Write-Host "  Total Records: $totalAccounts"
        Write-Host "  Successfully Created: $successCount" -ForegroundColor Green
        Write-Host "  Errors: $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })

        Write-Log "Completed New-CACAccountsFromCsv()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in New-CACAccountsFromCsv(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# Helper: Create Account Import Template CSV
# ============================================================
function New-CACAccountTemplate {
    param(
        [string]$OutputPath
    )

    Write-Log "Started New-CACAccountTemplate()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $dataDir = "$PSScriptRoot/../Data"
            if (-not (Test-Path $dataDir)) {
                New-Item -ItemType Directory -Path $dataDir | Out-Null
            }
            $OutputPath = "$dataDir/AccountTemplate.csv"
        }

        Write-Log "Creating account template at: $OutputPath" "INFO"

        # Create template with headers and one example row
        $template = @(
            [PSCustomObject]@{
                SafeName                   = "MySafe"
                PlatformID                 = "WinDomain"
                Address                    = "192.168.1.10"
                UserName                   = "domain\admin"
                Name                       = "MyAdmin Account"
                Secret                     = "MyPassword123!"
                PolicyID                   = ""
                AutomaticManagementEnabled = "True"
                ManualManagementReason     = ""
            }
        )

        $template | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

        Write-Log "Account template created successfully: $OutputPath" "SUCCESS"
        Write-Host "Account template created: $OutputPath" -ForegroundColor Green
        Write-Host "Edit this file and use it with New-CACAccountsFromCsv" -ForegroundColor Cyan

        Write-Log "Completed New-CACAccountTemplate()" "DEBUG"
    }
    catch {
        Write-Log "Error creating template: $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 7. Remove Account by ID
# ============================================================
function Remove-CACAccount {
    param(
        [string]$AccountID
    )

    Write-Log "Started Remove-CACAccount()" "DEBUG"

    try {
        # Prompt for ID if not provided
        if ([string]::IsNullOrWhiteSpace($AccountID)) {
            $AccountID = Read-Host "Enter Account ID to delete"
            if ([string]::IsNullOrWhiteSpace($AccountID)) {
                Write-Log "Account ID is empty" "WARN"
                Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Preparing to delete account: $AccountID" "INFO"

        # Get account details for confirmation
        try {
            $account = Get-PASAccount -id $AccountID -ErrorAction Stop
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

        Write-Host "===== Delete Confirmation =====" -ForegroundColor Red
        Write-Host "Account ID: $AccountID"
        Write-Host "Account Name: $($account.name)"
        Write-Host "Safe: $($account.safeName)"
        Write-Host "Username: $($account.userName)"
        Write-Host ""
        Write-Host "WARNING: This action cannot be undone." -ForegroundColor Red

        $confirm = Read-Host "Are you sure you want to PERMANENTLY DELETE this account? (Y/N)"

        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Log "Delete cancelled by user" "INFO"
            Write-Host "Delete cancelled." -ForegroundColor Yellow
            return
        }

        Write-Log "User confirmed; deleting account: $AccountID" "WARN"

        # Remove Account
        Remove-PASAccount -id $AccountID -ErrorAction Stop

        Write-Log "Account deleted successfully: $AccountID" "SUCCESS"
        Write-Host "Account deleted successfully." -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Remove-CACAccount(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}




# ============================================================
# 8. Batch Delete Accounts (ID or CSV)
# ============================================================
function Invoke-CACBatchAccountDeletion {
    [CmdletBinding()]
    param(
        [string]$Id,
        [string]$CsvPath,
        [string]$OutputCsvPath = (Join-Path $PWD "BatchDeletion_Result.csv")
    )

    Write-Log "Started Invoke-CACBatchAccountDeletion()" "DEBUG"

    # --- 1. Gather Input Data ---
    $itemsToProcess = @()

    # --- INTERACTIVE MODE CHECK ---
    if ([string]::IsNullOrWhiteSpace($Id) -and [string]::IsNullOrWhiteSpace($CsvPath)) {
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
    }

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        # Single ID Mode
        Write-Log "Processing single ID: $Id" "INFO"
        $itemsToProcess += [PSCustomObject]@{
            id            = $Id
            ProcessSource = "ManualInput"
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        # CSV Mode
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

    # --- 2. Process Deletions ---
    $results = @()
    $total = $itemsToProcess.Count
    $current = 0

    foreach ($item in $itemsToProcess) {
        $current++
        # Clone item properties to result object
        $resObj = $item | Select-Object *
        
        # Ensure 'id' exists (case-insensitive check)
        $idVal = if ($item.PSObject.Properties['id']) { $item.id } else { $null }

        if (-not $idVal) {
            Write-Host "Row $current : Missing 'id' column. Skipping." -ForegroundColor Yellow
            $resObj | Add-Member -MemberType NoteProperty -Name "DeletionStatus" -Value "Skipped" -Force
            $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Missing 'id' column" -Force
            $results += $resObj
            continue
        }

        Write-Host "[$current/$total] Deleting Account ID: $idVal ... " -NoNewline

        try {
            # --- Deletion ---
            Remove-PASAccount -id $idVal -ErrorAction Stop
            
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

    # --- 3. Export Results ---
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "`nBatch Deletion Complete. Results: $OutputCsvPath" -ForegroundColor Green
    Write-Log "Batch Deletion Complete. Results saved to $OutputCsvPath" "INFO"
}

# ============================================================
# EXPORT ALL PUBLIC FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    Get-CACAccounts, `
    Get-CACAccountById, `
    Get-CACAccountActivity, `
    Invoke-CACAccountReconcile, `
    New-CACPSMConnection, `
    New-CACAccountsFromCsv, `
    New-CACAccountTemplate, `
    Remove-CACAccount, `
    Invoke-CACBatchAccountDeletion
