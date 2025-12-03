# ==========================
# Accounts.psm1 - Account Management
# ==========================
 

Import-Module psPAS -ErrorAction Stop

# ============================================================
# 1. Get Accounts by Search/Safe with Pagination (limit 100 per page)
# ============================================================
function Get-CACAccounts {
    param(
        [string]$Search,
        [string]$SafeName,
        [int]$LimitPerPage = 100
    )

    Write-Log "Started Get-CACAccounts()" "DEBUG"
    Write-Log "Search: '$Search', Safe: '$SafeName', Limit: $LimitPerPage" "INFO"

    try {
        # Validate inputs
        if ([string]::IsNullOrWhiteSpace($Search) -and [string]::IsNullOrWhiteSpace($SafeName)) {
            Write-Log "Neither Search nor SafeName provided; asking user" "DEBUG"
            Write-Host "Choose search method:" -ForegroundColor Cyan
            Write-Host "1 = Search by keyword"
            Write-Host "2 = Search by safe name"
            $method = Read-Host "Enter choice (1 or 2)"

            switch ($method) {
                '1' {
                    $Search = Read-Host "Enter search keywords"
                    if ([string]::IsNullOrWhiteSpace($Search)) {
                        Write-Log "Search keywords empty after prompt" "WARN"
                        Write-Host "Search keywords cannot be empty." -ForegroundColor Yellow
                        return
                    }
                }
                '2' {
                    $SafeName = Read-Host "Enter safe name"
                    if ([string]::IsNullOrWhiteSpace($SafeName)) {
                        Write-Log "Safe name empty after prompt" "WARN"
                        Write-Host "Safe name cannot be empty." -ForegroundColor Yellow
                        return
                    }
                }
                default {
                    Write-Log "Invalid search method selected" "WARN"
                    Write-Host "Invalid choice." -ForegroundColor Yellow
                    return
                }
            }
        }

        # Initialize output directory
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $allAccounts = @()
        $offset = 0
        $pageCount = 0
        $totalRetrieved = 0

        Write-Log "Starting account retrieval with pagination" "INFO"

        # Pagination loop
        while ($true) {
            $pageCount++
            Write-Log "Fetching page $pageCount (offset: $offset)" "DEBUG"

            try {
                # Build parameters
                $params = @{
                    Limit  = $LimitPerPage
                    Offset = $offset
                }

                # Add search/safe filter if provided
                if (-not [string]::IsNullOrWhiteSpace($Search)) {
                    $params['Keywords'] = $Search
                }
                if (-not [string]::IsNullOrWhiteSpace($SafeName)) {
                    $params['Safe'] = $SafeName
                }

                Write-Log "Calling Get-PASAccount with params: $(ConvertTo-Json $params)" "DEBUG"

                # Call psPAS
                $accounts = Get-PASAccount @params -ErrorAction Stop

                if (-not $accounts -or $accounts.Count -eq 0) {
                    Write-Log "Page $pageCount returned 0 accounts; ending pagination" "INFO"
                    break
                }

                Write-Log "Page $pageCount returned $($accounts.Count) accounts" "DEBUG"
                $allAccounts += $accounts
                $totalRetrieved += $accounts.Count

                # Check if we got fewer than requested; if so, this is the last page
                if ($accounts.Count -lt $LimitPerPage) {
                    Write-Log "Received $($accounts.Count) accounts (less than limit $LimitPerPage); ending pagination" "DEBUG"
                    break
                }

                $offset += $LimitPerPage
            }
            catch {
                Write-Log "Error fetching page $pageCount`: $($_.Exception.Message)" "ERROR"
                Write-Host "Error during account retrieval: $($_.Exception.Message)" -ForegroundColor Red
                if ($totalRetrieved -eq 0) {
                    return
                }
                # Continue with what we have so far
                break
            }
        }

        if ($totalRetrieved -eq 0) {
            Write-Log "No accounts found matching criteria" "WARN"
            Write-Host "No accounts found." -ForegroundColor Yellow
            return
        }

        Write-Log "Total accounts retrieved: $totalRetrieved across $pageCount pages" "INFO"

        # Format accounts for output
        Write-Log "Formatting $totalRetrieved accounts for export" "INFO"

        $formatted = @()
        $successCount = 0
        $errorCount = 0

        foreach ($account in $allAccounts) {
            try {
                $formattedAccount = [PSCustomObject]@{
                    AccountID                  = $account.id
                    AccountName                = $account.name
                    UserName                   = $account.userName
                    Address                    = $account.address
                    PlatformID                 = $account.platformId
                    SafeName                   = $account.safeName
                    PolicyID                   = $account.policyId
                    AutomaticManagementEnabled = $account.automaticManagementEnabled
                    ManualManagementReason     = $account.manualManagementReason
                    CreatedDate                = Convert-CACTimestamp $account.createdTime
                    LastModifiedDate           = Convert-CACTimestamp $account.lastModifiedTime
                }

                $formatted += $formattedAccount
                $successCount++
            }
            catch {
                $errorCount++
                Write-Log "Error formatting account $($account.id): $($_.Exception.Message)" "WARN"
            }
        }

        Write-Log "Formatting complete. Success: $successCount, Errors: $errorCount" "INFO"

        # Export to CSV
        if ($formatted.Count -eq 0) {
            Write-Log "No successfully formatted accounts to export" "WARN"
            return
        }

        $searchDesc = if ($Search) { "keyword_$Search" } else { "safe_$SafeName" }
        $outputFile = "$outputDir/accounts_${searchDesc}_$totalRetrieved`_$timestamp.csv"
        
        Write-Log "Exporting $($formatted.Count) accounts to CSV: $outputFile" "INFO"
        $formatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "CSV export successful: $outputFile" "SUCCESS"

        # Summary
        Write-Host "Export Summary" -ForegroundColor Cyan
        Write-Host "  Search/Safe: $(if ($Search) { "Keyword: $Search" } else { "Safe: $SafeName" })"
        Write-Host "  Total Accounts: $totalRetrieved"
        Write-Host "  Successfully Formatted: $successCount"
        Write-Host "  Formatting Errors: $errorCount"
        Write-Host "  Output File: $outputFile" -ForegroundColor Green

        Write-Log "Completed Get-CACAccounts()" "DEBUG"
    }
    catch {
        Write-Log "Fatal error in Get-CACAccounts(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
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
# 3. Get Account Activity by Account ID
# ============================================================
function Get-CACAccountActivity {
    param(
        [string]$AccountID
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

        # Optional: Export to CSV
        Write-Host ""
        $exportChoice = Read-Host "Export to CSV? (Y/N)"

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
# EXPORT ALL PUBLIC FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    Get-CACAccounts, `
    Get-CACAccountById, `
    Get-CACAccountActivity, `
    Invoke-CACAccountReconcile, `
    New-CACPSMConnection, `
    New-CACAccountsFromCsv, `
    New-CACAccountTemplate
