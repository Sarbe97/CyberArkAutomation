# ============================================================================
# MODULE: DiscoveryAndOnboarding.psm1
# DESCRIPTION: Discovery and Onboarding operations using CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get Discovered Accounts
# ============================================================
function Get-CACDiscoveredAccounts {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACDiscoveredAccounts()" "DEBUG"

    try {
        Write-Host ""
        Write-Host "===== Search Discovered Accounts =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Filter Examples:" -ForegroundColor Yellow
        Write-Host "  - platformType eq Windows Server Local"
        Write-Host "  - privileged eq true"
        Write-Host "  - accountEnabled eq true"
        Write-Host "  - Combine: platformType eq Windows AND privileged eq true"
        Write-Host ""

        $search = Read-Host "Enter search term (username/address, or press Enter to skip)"
        $filter = Read-Host "Enter filter (optional, press Enter to skip)"

        # Build query parameters
        $queryParams = @()
        
        if (-not [string]::IsNullOrWhiteSpace($filter)) {
            $queryParams += "filter=$([System.Web.HttpUtility]::UrlEncode($filter))"
        }
        if (-not [string]::IsNullOrWhiteSpace($search)) {
            $queryParams += "search=$([System.Web.HttpUtility]::UrlEncode($search))"
        }
        $queryParams += "limit=100"

        $endpoint = "/API/DiscoveredAccounts/"
        if ($queryParams.Count -gt 0) {
            $endpoint += "?" + ($queryParams -join "&")
        }

        Write-Host ""
        Write-Host "Fetching discovered accounts..." -ForegroundColor Cyan

        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $accounts = @()
        if ($response.value) { $accounts = @($response.value) }
        elseif ($response -is [array]) { $accounts = @($response) }

        if ($accounts.Count -eq 0) {
            Write-Host "No discovered accounts found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($accounts.Count) discovered accounts" "INFO"

        # Format output
        $formattedAccounts = @()
        foreach ($acct in $accounts) {
            $formattedAccounts += [PSCustomObject]@{
                Id             = $acct.id
                UserName       = $acct.userName
                Address        = $acct.address
                DiscoveryDate  = Convert-CACTimestamp $acct.discoveryDate
                AccountEnabled = $acct.accountEnabled
                Privileged     = $acct.privileged
                PlatformType   = $acct.platformType
                Domain         = $acct.domain
                OU             = $acct.organizationalUnit
                OSFamily       = $acct.osFamily
            }
        }

        # Display summary
        Write-Host ""
        Write-Host "===== Discovered Accounts =====" -ForegroundColor Cyan
        Write-Host "Total Found: $($formattedAccounts.Count)"
        Write-Host ""

        $formattedAccounts | Format-Table UserName, Address, PlatformType, Privileged, AccountEnabled -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/discovered_accounts_$timestamp.csv"

            $formattedAccounts | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedAccounts
    }
    catch {
        Write-Log "Error in Get-CACDiscoveredAccounts(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 2. Get Discovered Account Details
# ============================================================
function Get-CACDiscoveredAccountDetails {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACDiscoveredAccountDetails()" "DEBUG"

    try {
        $AccountId = Read-Host "Enter Discovered Account ID"
        if ([string]::IsNullOrWhiteSpace($AccountId)) {
            Write-Host "Account ID cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching discovered account details..." -ForegroundColor Cyan

        $endpoint = "/API/DiscoveredAccounts/$([System.Web.HttpUtility]::UrlEncode($AccountId))/"
        $account = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        if (-not $account) {
            Write-Host "Account not found." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Discovered Account Details =====" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Account ID:         $($account.id)" -ForegroundColor White
        Write-Host "  User Name:          $($account.userName)" -ForegroundColor White
        Write-Host "  Address:            $($account.address)" -ForegroundColor White
        Write-Host "  Platform Type:      $($account.platformType)" -ForegroundColor White
        Write-Host "  Domain:             $($account.domain)" -ForegroundColor White
        Write-Host "  OS Family:          $($account.osFamily)" -ForegroundColor White
        Write-Host "  Machine Type:       $($account.machineType)" -ForegroundColor White
        Write-Host "  OU:                 $($account.organizationalUnit)" -ForegroundColor White
        Write-Host ""
        Write-Host "  Privileged:         $($account.privileged)" -ForegroundColor $(if ($account.privileged) { "Red" } else { "Green" })
        Write-Host "  Account Enabled:    $($account.accountEnabled)" -ForegroundColor White
        Write-Host ""
        Write-Host "  Discovery Date:     $(Convert-CACTimestamp $account.discoveryDate)" -ForegroundColor White
        Write-Host "  Last Logon:         $(if ($account.lastLogonDate) { Convert-CACTimestamp $account.lastLogonDate } else { 'N/A' })" -ForegroundColor White
        Write-Host "  Last Password Set:  $(if ($account.lastPasswordSetDate) { Convert-CACTimestamp $account.lastPasswordSetDate } else { 'N/A' })" -ForegroundColor White
        Write-Host ""

        # Display dependencies if present
        if ($account.dependencies) {
            Write-Host "  Dependencies:" -ForegroundColor Yellow
            foreach ($dep in $account.dependencies) {
                Write-Host "    - $($dep.name): $($dep.type)" -ForegroundColor White
            }
        }

        return $account
    }
    catch {
        Write-Log "Error in Get-CACDiscoveredAccountDetails(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 3. Get Onboarding Rules
# ============================================================
function Get-CACOnboardingRules {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACOnboardingRules()" "DEBUG"

    try {
        $ruleName = Read-Host "Enter rule name to filter (or press Enter for all)"
        
        $endpoint = "/API/AutomaticOnboardingRules/"
        
        if (-not [string]::IsNullOrWhiteSpace($ruleName)) {
            $endpoint += "?name=$([System.Web.HttpUtility]::UrlEncode($ruleName))"
        }

        Write-Host "Fetching onboarding rules..." -ForegroundColor Cyan

        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $rules = @()
        if ($response.AutomaticOnboardingRules) { $rules = @($response.AutomaticOnboardingRules) }
        elseif ($response.value) { $rules = @($response.value) }
        elseif ($response -is [array]) { $rules = @($response) }

        if ($rules.Count -eq 0) {
            Write-Host "No onboarding rules found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($rules.Count) onboarding rules" "INFO"

        # Format output
        $formattedRules = @()
        foreach ($rule in $rules) {
            $formattedRules += [PSCustomObject]@{
                RuleId            = $rule.RuleId
                RuleName          = $rule.RuleName
                TargetSafeName    = $rule.TargetSafeName
                TargetPlatformId  = $rule.TargetPlatformId
                TargetDeviceType  = $rule.TargetDeviceType
                UserNameFilter    = $rule.UserNameFilter
                AddressFilter     = $rule.AddressFilter
                SystemTypeFilter  = $rule.SystemTypeFilter
                MachineTypeFilter = $rule.MachineTypeFilter
                IsAdminIDFilter   = $rule.IsAdminIDFilter
                RulePrecedence    = $rule.RulePrecedence
                RuleDescription   = $rule.RuleDescription
            }
        }

        # Display summary
        Write-Host ""
        Write-Host "===== Onboarding Rules =====" -ForegroundColor Cyan
        Write-Host "Total Rules: $($formattedRules.Count)"
        Write-Host ""

        $formattedRules | Format-Table RuleName, TargetSafeName, TargetPlatformId, UserNameFilter, RulePrecedence -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/onboarding_rules_$timestamp.csv"

            $formattedRules | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedRules
    }
    catch {
        Write-Log "Error in Get-CACOnboardingRules(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Get-CACDiscoveredAccounts, `
    Get-CACDiscoveredAccountDetails, `
    Get-CACOnboardingRules
