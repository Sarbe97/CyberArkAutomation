# =============================================================================
# DR_Summary.ps1
# Builds the $SummaryRows array with the exact metric names used in
# the SharePoint Excel dashboard and email report.
# Exposes: Build-SummaryRows
# =============================================================================

function Build-SummaryRows {
    param(
        # Account Metrics
        [int]$TotalAccounts,
        [int]$DomainAccountsCount,
        [int]$FailedAccountsCount,
        [int]$DiscoveryOnboardedCount,
        [int]$DiscoveryPendingCount,
        [hashtable]$TrackedFailures,

        # Safe Metrics
        [int]$SharedSafesCount,
        [int]$PersonalSafesCount,
        [int]$MigratedSharedSafes,

        # Platform Metrics
        [int]$ActivePlatformsCount,
        [int]$MigratedPlatformsCount,
        [int]$InUsePlatformsCount,

        # Failure Comparison
        [int]$FixedCount,
        [int]$NewCount,
        [int]$ExistingCount
    )

    $rows = @()

    # ---- Safe Statistics ----
    $rows += [PSCustomObject]@{ Category = "SectionHeader"; Metric = "Safe Statistics";   Value = "" }
    $rows += [PSCustomObject]@{ Category = "Safe Metrics";  Metric = "Total Shared Safes"; Value = $SharedSafesCount }
    $rows += [PSCustomObject]@{ Category = "Safe Metrics";  Metric = "Total Personal Safes"; Value = $PersonalSafesCount }
    $rows += [PSCustomObject]@{ Category = "Safe Metrics";  Metric = "Migrated Safes";    Value = $MigratedSharedSafes }

    # ---- Platform Statistics ----
    $rows += [PSCustomObject]@{ Category = "SectionHeader";    Metric = "Platform Statistics"; Value = "" }
    # ActivePlatformsCount = all platforms fetched via ?active=true = Total Platforms
    $rows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "Total Platforms";    Value = $ActivePlatformsCount }
    $rows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "Migrated Platforms"; Value = $MigratedPlatformsCount }
    $rows += [PSCustomObject]@{ Category = "Platform Metrics"; Metric = "InUse Platforms";    Value = $InUsePlatformsCount }

    # ---- Accounts Statistics ----
    $rows += [PSCustomObject]@{ Category = "SectionHeader";   Metric = "Accounts Statistics"; Value = "" }
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Total Accounts";       Value = $TotalAccounts }
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Domain Accounts";      Value = $DomainAccountsCount }
    # CPM Failure = accounts failing their CPM rotation (PolicyFailures endpoint)
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "CPM Failure";          Value = $FailedAccountsCount }

    # Tracked account failures inline (e.g. Goldmember, srmdata, root (Unix))
    if ($TrackedFailures -and $TrackedFailures.Count -gt 0) {
        foreach ($accName in $TrackedFailures.Keys) {
            $rows += [PSCustomObject]@{ Category = "Tracked Account Metrics"; Metric = $accName; Value = $TrackedFailures[$accName] }
        }
    }

    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Total Discovered Accounts Onboarded (NA)"; Value = $DiscoveryOnboardedCount }
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "PendingAccounts (Other Domains)";          Value = $DiscoveryPendingCount }
    # Placeholder rows - not currently available via API; populate manually or extend script
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "Licenses Consumed";        Value = "" }
    $rows += [PSCustomObject]@{ Category = "Account Metrics"; Metric = "PAM Groups missing owners"; Value = "" }

    # ---- Failure Comparison (email delta tracking) ----
    $rows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "Fixed_Resolved";  Value = "-$FixedCount" }
    $rows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "New_Added";       Value = "+$NewCount" }
    $rows += [PSCustomObject]@{ Category = "Failure Comparison"; Metric = "Existing_Pending"; Value = $ExistingCount }

    $rows += [PSCustomObject]@{ Category = "Metadata"; Metric = "Timestamp"; Value = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

    return $rows
}
