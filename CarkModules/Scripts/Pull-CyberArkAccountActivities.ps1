# Pull-CyberArkAccountActivities.ps1 - Search for accounts and retrieve activities for all found accounts

# Reload modules
$modulesToReload = @('Auth', 'CyberArkAPIs', 'Utils')
foreach ($mod in $modulesToReload) {
    if (Get-Module -Name $mod) {
        Remove-Module -Name $mod -Force -ErrorAction SilentlyContinue
        Write-Verbose "Unloaded module $mod"
    }
}

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Helpers\Utils.psm1" -Verbose -DisableNameChecking

$configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Config\config.json"
$lastPvwaUrl = $null

if (Test-Path $configPath) {
    $configJson = Get-Content $configPath -Raw | ConvertFrom-Json
    $lastPvwaUrl = $configJson.PvwaUrl
}

if ($lastPvwaUrl) {
    Write-Host "Previous PVWA URL: $lastPvwaUrl"
    $pvwaUrl = Read-Host "Enter PVWA URL (or press Enter to use previous)"
    if ([string]::IsNullOrWhiteSpace($pvwaUrl)) {
        $pvwaUrl = $lastPvwaUrl
    }
}
else {
    $pvwaUrl = Read-Host "Enter PVWA URL (e.g. https://pvwa.myorg.com)"
}

# Save PVWA URL to config
$configObj = @{ PvwaUrl = $pvwaUrl }
if (-not (Test-Path (Split-Path $configPath))) {
    New-Item -ItemType Directory -Path (Split-Path $configPath) -Force | Out-Null
}
$configObj | ConvertTo-Json | Set-Content $configPath

$searchQuery = Read-Host "Enter search query for accounts (e.g., 'domain\*' or '*admin*')"

$session = Connect-CyberArk -PvwaUrl $pvwaUrl

try {
    $allAccounts = @()
    $limit = 25
    $offset = 0

    # Search for all accounts matching the query with pagination
    do {
        $accountsPage = Search-CyberArkAccounts -PvwaUrl $pvwaUrl -Token $session.Token -SearchQuery $searchQuery -Limit $limit -Offset $offset

        if ($null -eq $accountsPage -or $accountsPage.Count -eq 0) {
            break
        }

        $count = $accountsPage.Count
        $allAccounts += $accountsPage
        $offset += $count

        Write-Host "Retrieved $count accounts in this page, total so far: $($allAccounts.Count)"
    }
    while ($count -eq $limit)

    if ($allAccounts.Count -gt 0) {
        Write-Host "Found $($allAccounts.Count) accounts matching query '$searchQuery'"

        $allActivities = @()

        # For each account, retrieve its activities
        foreach ($account in $allAccounts) {
            Write-Host "Retrieving activities for account: $($account.name) (ID: $($account.id))"

            try {
                $activities = Get-CyberArkAccountActivities -PvwaUrl $pvwaUrl -Token $session.Token -AccountID $account.id

                if ($activities) {
                    # Handle single object or array
                    if ($activities -isnot [System.Collections.IEnumerable] -or $activities -is [string]) {
                        $activities = @($activities)
                    }

                    # Add account info to each activity record
                    $activities | ForEach-Object {
                        $activityRecord = [PSCustomObject]@{
                            AccountName      = $account.name
                            AccountID        = $account.id
                            AccountAddress   = $account.address
                            AccountUserName  = $account.userName
                            SafeName         = $account.safeName
                            PlatformID       = $account.platformId
                            ActivityCode     = $_.ActivityCode
                            Activity         = $_.Activity
                            Time             = $_.Time
                            UserName         = $_.UserName
                            ClientID         = $_.ClientID
                            Reason           = $_.Reason
                            MoreInfo         = $_.MoreInfo
                        }
                        $allActivities += $activityRecord
                    }
                }
            }
            catch {
                Write-Warning "Failed to get activities for account $($account.name): $_"
            }
        }

        if ($allActivities.Count -gt 0) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $csvPath = Join-Path -Path (Get-Location) -ChildPath "AccountActivities_$timestamp.csv"
            $allActivities | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-Host "Activities for $($allActivities.Count) records exported to $csvPath"

            # Display sample
            $allActivities | Format-Table -AutoSize | Out-Host
        }
        else {
            Write-Host "No activities found for the searched accounts."
        }
    }
    else {
        Write-Host "No accounts found matching query '$searchQuery'"
    }
}
finally {
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
}
