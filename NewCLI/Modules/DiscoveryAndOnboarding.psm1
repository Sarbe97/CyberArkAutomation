# ============================================================================
# MODULE: DiscoveryAndOnboarding.psm1
# DESCRIPTION: Discovery and Onboarding operations using CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get Discovered Accounts (with full details)
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

        # Format output with expanded fields
        $formattedAccounts = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($acct in $accounts) {
            $formattedAccounts.Add([PSCustomObject]@{
                    # Basic Info
                    Id                      = $acct.id
                    UserName                = $acct.userName
                    Description             = $acct.description
                    AccountType             = $acct.additionalProperties.AccountType
                    Address                 = $acct.address
                    Domain                  = $acct.domain
                    OU                      = $acct.organizationalUnit
                
                    # Platform Info
                    PlatformType            = $acct.platformType
                    OSFamily                = $acct.osFamily
                    OSVersion               = $acct.osVersion
                    OsGroups                = $acct.osGroups
                
                    # Status Info
                    AccountEnabled          = $acct.accountEnabled
                    Privileged              = $acct.privileged
                    PasswordNeverExpires    = $acct.passwordNeverExpires
                    NumberOfDependencies    = $acct.numberOfDependencies
                
                    # Timestamps
                    DiscoveryDateTime       = Convert-CACTimestamp $acct.discoveryDateTime
                    LastLogonDateTime       = Convert-CACTimestamp $acct.lastLogonDateTime
                    LastPasswordSetDateTime = Convert-CACTimestamp $acct.lastPasswordSetDateTime
                })
        }

        # Display summary
        Write-Host ""
        Write-Host "===== Discovered Accounts =====" -ForegroundColor Cyan
        Write-Host "Total Found: $($formattedAccounts.Count)"
        Write-Host ""

        # Display basic table in console (key columns)
        $formattedAccounts | Format-Table UserName, Address, Domain, PlatformType, Privileged, AccountEnabled -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export full details to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/discovered_accounts_$timestamp.csv"

            $formattedAccounts | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
            Write-Log "Exported $($formattedAccounts.Count) discovered accounts to $outputFile" "INFO"
        }

        return $formattedAccounts
    }
    catch {
        Write-Log "Error in Get-CACDiscoveredAccounts(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 2. Get Onboarding Rules
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

function Remove-CACDiscoveredAccounts {
    [CmdletBinding()]
    param()

    Write-Log "Started Remove-CACDiscoveredAccounts()" "DEBUG"

    try {
        Write-Host ""
        Write-Host "===== DELETE ALL DISCOVERED ACCOUNTS =====" -ForegroundColor Red
        Write-Host ""
        Write-Host "WARNING: This will DELETE ALL discovered accounts from the vault!" -ForegroundColor Yellow
        Write-Host "This action cannot be undone." -ForegroundColor Yellow
        Write-Host ""

        $confirm = Read-Host "Type 'DELETE' to confirm"
        if ($confirm -ne 'DELETE') {
            Write-Host "Operation cancelled." -ForegroundColor Cyan
            return
        }

        Write-Host ""
        Write-Host "Deleting all discovered accounts..." -ForegroundColor Cyan

        # CyberArk API call - DELETE /API/DiscoveredAccounts/
        Invoke-CACAPIRequest -Method DELETE -Endpoint "/API/DiscoveredAccounts/" | Out-Null

        Write-Log "All discovered accounts deleted successfully" "SUCCESS"
        Write-Host "All discovered accounts have been deleted." -ForegroundColor Green
    }
    catch {
        Write-Log "Error in Remove-CACDiscoveredAccounts(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Get-CACDiscoveredAccounts, `
    Get-CACOnboardingRules, `
    Remove-CACDiscoveredAccounts
