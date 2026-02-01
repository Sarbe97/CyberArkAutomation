param ()

# ------------------------
# Script Identity
# ------------------------
$ScriptName = "LDAPUserAnalysis"
$RootPath = $PSScriptRoot
$ConfigPath = Join-Path $RootPath "config.json"
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"
$OutputPath = Join-Path $RootPath "Output"

# ------------------------
# Load Utils
# ------------------------
. (Join-Path $RootPath "Utils.ps1")

Write-Log -Message "Execution started" -ScriptName $ScriptName -LogPath $LogPath

# ------------------------
# Load Config
# ------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Log -Message "Config file not found: $ConfigPath" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$BaseUrl = $config.BaseUrl
$featureConfig = $config.Features.LDAPUserAnalysis

if (-not $featureConfig.Enabled) {
    Write-Log -Message "LDAPUserAnalysis feature disabled. Skipping." -ScriptName $ScriptName -LogPath $LogPath
    exit 0
}

# Ensure Output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ------------------------
# Helper Functions
# ------------------------

# Normalize domain to base name (NADEV.abc.net -> NADEV)
function Get-BaseDomain {
    param ([string]$Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return "" }
    return $Domain.Split('.')[0].ToUpper()
}

# Generate date string for file names
$DateStamp = Get-Date -Format "yyyy-MM-dd"

# Check if account should be excluded
function Test-ShouldExclude {
    param (
        [string]$Username,
        [string]$Domain,
        [PSCustomObject]$Exclusions
    )
    
    $baseDomain = Get-BaseDomain $Domain
    
    # Domain exclusion
    if ($Exclusions.Domains -and $baseDomain -in $Exclusions.Domains) {
        return $true
    }
    
    # Username pattern exclusion
    if ($Exclusions.UsernamePatterns) {
        foreach ($pattern in $Exclusions.UsernamePatterns) {
            if ($Username -match $pattern) { return $true }
        }
    }
    
    # Username+Domain combo exclusion
    if ($Exclusions.UsernameDomainCombos) {
        foreach ($combo in $Exclusions.UsernameDomainCombos) {
            if ($Username -match $combo.Username -and $baseDomain -eq $combo.Domain) {
                return $true
            }
        }
    }
    
    return $false
}

# ------------------------
# CyberArk API Functions
# ------------------------

# Get all CyberArk users (paginated)
function Get-CyberArkUsers {
    param ([string]$BaseUrl, [pscredential]$Credential)
    
    Write-Log -Message "Fetching all CyberArk users..." -ScriptName $ScriptName -LogPath $LogPath
    
    $allUsers = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit = 100
    
    do {
        $uri = "$BaseUrl/PasswordVault/api/Users?limit=$limit&offset=$offset"
        $response = Invoke-CyberArkApi -Uri $uri -Credential $Credential
        $users = if ($response.Users) { $response.Users } else { @() }
        
        foreach ($user in $users) { $allUsers.Add($user) }
        $offset += $limit
        Write-Log -Message "Fetched $($allUsers.Count) users so far..." -ScriptName $ScriptName -LogPath $LogPath
    } while ($users.Count -eq $limit)
    
    Write-Log -Message "Total users fetched: $($allUsers.Count)" -ScriptName $ScriptName -LogPath $LogPath
    return $allUsers.ToArray()
}

# Get all CyberArk accounts (paginated)
function Get-AllCyberArkAccounts {
    param ([string]$BaseUrl, [pscredential]$Credential)
    
    Write-Log -Message "Fetching all CyberArk accounts..." -ScriptName $ScriptName -LogPath $LogPath
    
    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $limit = 1000
    
    do {
        $uri = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset"
        $response = Invoke-CyberArkApi -Uri $uri -Credential $Credential
        $accounts = if ($response.value) { $response.value } else { @() }
        
        foreach ($acc in $accounts) { $allAccounts.Add($acc) }
        $offset += $limit
        Write-Log -Message "Fetched $($allAccounts.Count) accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
    } while ($accounts.Count -eq $limit)
    
    Write-Log -Message "Total accounts fetched: $($allAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath
    return $allAccounts.ToArray()
}

# Filter LDAP EPVUser type users
function Get-LDAPEPVUsers {
    param ([array]$AllUsers)
    
    Write-Log -Message "Filtering LDAP users with EPVUser type..." -ScriptName $ScriptName -LogPath $LogPath
    $pattern = "^[A-Za-z]\d{6}$"
    
    $filtered = $AllUsers | Where-Object {
        $_.source -eq "LDAP" -and 
        $_.userType -eq "EPVUser" -and
        $_.username -match $pattern
    }
    
    Write-Log -Message "Found $($filtered.Count) LDAP EPVUser users matching pattern" -ScriptName $ScriptName -LogPath $LogPath
    return $filtered
}

# Filter accounts in personal safes
function Get-PersonalSafeAccounts {
    param ([array]$AllAccounts, [string]$SafePattern)
    
    Write-Log -Message "Filtering accounts in personal safes (pattern: $SafePattern)..." -ScriptName $ScriptName -LogPath $LogPath
    
    $filtered = $AllAccounts | Where-Object { $_.safeName -match $SafePattern }
    
    Write-Log -Message "Found $($filtered.Count) accounts in personal safes" -ScriptName $ScriptName -LogPath $LogPath
    return $filtered
}

# ------------------------
# AD Query Functions
# ------------------------

function Get-AllADSecondaryAccounts {
    param ([array]$Domains)
    
    Write-Log -Message "Fetching secondary accounts from $($Domains.Count) domains..." -ScriptName $ScriptName -LogPath $LogPath
    
    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $pattern = "^[A-Za-z]\d{6}$"
    
    foreach ($domain in $Domains) {
        try {
            Write-Log -Message "Querying domain: $($domain.Name)" -ScriptName $ScriptName -LogPath $LogPath
            
            $filter = "SamAccountName -like '[A-Za-z]??????'"
            $accounts = Get-ADUser -Filter $filter -Server $domain.Server -Properties Enabled -ErrorAction Stop
            
            foreach ($acc in $accounts) {
                if ($acc.SamAccountName -match $pattern) {
                    $allAccounts.Add([PSCustomObject]@{
                            Username    = $acc.SamAccountName
                            DomainShort = $domain.Name        # For comparison (NADEV)
                            DomainFQDN  = $domain.FQDN        # For report (nadev.company.com)
                            Enabled     = $acc.Enabled
                            EmpNbr      = $acc.SamAccountName.Substring(1, 6)
                        })
                }
            }
            
            Write-Log -Message "Found $($accounts.Count) accounts in $($domain.Name)" -ScriptName $ScriptName -LogPath $LogPath
        }
        catch {
            Write-Log -Message "Error querying domain $($domain.Name): $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    
    Write-Log -Message "Total AD secondary accounts: $($allAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath
    return $allAccounts.ToArray()
}

# ------------------------
# Main Execution
# ------------------------
try {
    # Get Credential from CCP
    $Credential = Get-CCPCredential -CCPConfig $config.CCP -ScriptName $ScriptName -LogPath $LogPath
    
    # Step 1: Get all CyberArk LDAP users
    $allCyberArkUsers = Get-CyberArkUsers -BaseUrl $BaseUrl -Credential $Credential
    $targetUsers = Get-LDAPEPVUsers -AllUsers $allCyberArkUsers
    
    if ($targetUsers.Count -eq 0) {
        Write-Log -Message "No LDAP EPVUser users found. Exiting." -ScriptName $ScriptName -LogPath $LogPath
        exit 0
    }
    
    # Build map of CyberArk users by EmpNbr
    $cyberArkUserMap = @{}
    foreach ($user in $targetUsers) {
        $empNbr = $user.username.Substring(1, 6)
        $cyberArkUserMap[$empNbr] = $user.username
    }
    
    # Step 2: Fetch all CyberArk accounts and filter personal safes
    $allCyberArkAccounts = Get-AllCyberArkAccounts -BaseUrl $BaseUrl -Credential $Credential
    $personalSafeAccounts = Get-PersonalSafeAccounts -AllAccounts $allCyberArkAccounts -SafePattern $featureConfig.PersonalSafePattern
    
    # Save CyberArk personal accounts to CSV (date-based filename)
    $caAccountsFile = Join-Path $OutputPath "cyberark_personal_accounts_$DateStamp.csv"
    
    $caAccountsData = $personalSafeAccounts | ForEach-Object {
        [PSCustomObject]@{
            AccountId = $_.id
            Username  = $_.userName
            SafeName  = $_.safeName
            Platform  = $_.platformId
            Address   = $_.address
            EmpNbr    = if ($_.safeName -match '([A-Za-z])(\d{6})$') { $Matches[2] } else { "" }
        }
    }
    $caAccountsData | Export-Csv -Path $caAccountsFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "CyberArk personal accounts saved: $caAccountsFile" -ScriptName $ScriptName -LogPath $LogPath
    
    # Build CyberArk lookup: "USERNAME|BASEDOMAIN" -> SafeName (using Address, normalized via Get-BaseDomain)
    $cyberArkMap = @{}
    foreach ($acc in $caAccountsData) {
        if ([string]::IsNullOrWhiteSpace($acc.Address)) { continue }  # Skip empty address
        $key = "$($acc.Username.ToUpper())|$(Get-BaseDomain $acc.Address)"
        $cyberArkMap[$key] = $acc.SafeName
    }
    
    # Step 3: Fetch all AD secondary accounts
    $adSecondaryAccounts = Get-AllADSecondaryAccounts -Domains $featureConfig.Domains
    
    # Save AD secondary accounts to CSV (date-based filename)
    $adAccountsFile = Join-Path $OutputPath "ad_secondary_accounts_$DateStamp.csv"
    $adSecondaryAccounts | Export-Csv -Path $adAccountsFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "AD secondary accounts saved: $adAccountsFile" -ScriptName $ScriptName -LogPath $LogPath
    
    # Step 4: Compare and generate report
    $report = [System.Collections.Generic.List[object]]::new()
    $managedCount = 0
    $toOnboardCount = 0
    
    foreach ($ad in $adSecondaryAccounts) {
        # Skip excluded accounts (use short name for comparison)
        if (Test-ShouldExclude -Username $ad.Username -Domain $ad.DomainShort -Exclusions $featureConfig.Exclusions) {
            continue
        }
        
        # Check if this empNbr has a CyberArk user
        $primaryUser = $cyberArkUserMap[$ad.EmpNbr]
        if (-not $primaryUser) { continue }  # No matching CyberArk user
        
        # Check if onboarded (use short name for comparison)
        $key = "$($ad.Username.ToUpper())|$($ad.DomainShort.ToUpper())"
        $isOnboarded = $cyberArkMap.ContainsKey($key)
        $safeName = if ($isOnboarded) { $cyberArkMap[$key] } else { "" }
        $status = if ($isOnboarded) { "Managed" } else { "To Be Onboarded" }
        
        if ($isOnboarded) { $managedCount++ } else { $toOnboardCount++ }
        
        $report.Add([PSCustomObject]@{
                PrimaryUserID       = $primaryUser
                SecondaryAccountID  = $ad.Username
                Domain              = $ad.DomainFQDN   # Full domain for report
                ADEnabled           = $ad.Enabled
                OnboardedInCyberArk = $isOnboarded
                SafeName            = $safeName
                Status              = $status
            })
    }
    
    Write-Log -Message "Comparison complete. Managed: $managedCount, To Be Onboarded: $toOnboardCount" -ScriptName $ScriptName -LogPath $LogPath
    
    # Step 5: Export Report
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportFile = Join-Path $OutputPath "LDAPUserAnalysis_Report_$timestamp.csv"
    $report | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Report saved: $reportFile" -ScriptName $ScriptName -LogPath $LogPath
    
    # Step 6: Prepare Email Content
    $templateData = @{
        GeneratedDate     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TotalUsersScanned = $targetUsers.Count
        ManagedCount      = $managedCount
        ToOnboardCount    = $toOnboardCount
    }
    
    $EmailBody = Get-TemplateContent -TemplateName "LDAPUserAnalysis" -Data $templateData
    
    # Build attachment list
    $attachments = @($reportFile)
    
    # Step 7: Send Email with Attachments
    Send-SchedulerEmailWithAttachment `
        -Subject "CyberArk LDAP User Analysis Report - $(Get-Date -Format 'yyyy-MM-dd')" `
        -Body $EmailBody `
        -EmailConfig $config.Email `
        -Attachments $attachments `
        -IsHtml `
        -ScriptName $ScriptName `
        -LogPath $LogPath
    
    Write-Log -Message "Execution completed successfully" -ScriptName $ScriptName -LogPath $LogPath
}
catch {
    Write-Log -Message "Execution failed: $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}
