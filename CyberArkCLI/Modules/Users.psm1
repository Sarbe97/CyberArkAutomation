# ==========================
# User.psm1
# ==========================

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"
$Script:CacheExpiryDays = 7

# ---------------------------------------------------------
# Helper: Write log messages with timestamps
# ---------------------------------------------------------
function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# ---------------------------------------------------------
# Refresh user cache if needed
# ---------------------------------------------------------
function Update-CACUserCache {
    Write-Log "Checking user cache at: $Script:UserCachePath"

    $needsRefresh = $false

    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "User cache missing. Will refresh."
        $needsRefresh = $true
    }
    elseif ((Get-Item $Script:UserCachePath).Length -eq 0) {
        Write-Log "User cache exists but is empty. Will refresh."
        $needsRefresh = $true
    }
    else {
        $lastWrite = (Get-Item $Script:UserCachePath).LastWriteTime
        if ($lastWrite -lt (Get-Date).AddDays(-$Script:CacheExpiryDays)) {
            Write-Log "User cache is older than $Script:CacheExpiryDays days. Will refresh."
            $needsRefresh = $true
        } else {
            Write-Log "User cache is fresh. No refresh needed."
        }
    }

    if ($needsRefresh) {
        Refresh-CACUsers
    }
}

# ---------------------------------------------------------
# Fetch users from PAS and write users.csv
# ---------------------------------------------------------
function Refresh-CACUsers {
    Write-Log "Fetching PAS users..."

    try {
        $users = Get-PASUser -ExtendedDetails $true
        Write-Log "Fetched $($users.Count) users."

        $folder = Split-Path $Script:UserCachePath
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder | Out-Null
        }

        $users |
            Select-Object UserName,
                          DisplayName,
                          Source,
                          UserType,
                          @{Name="Department"; Expression={$_.PersonalDetails.department}},
                          @{Name="Title"; Expression={$_.PersonalDetails.title}},
                          @{Name="Organization"; Expression={$_.PersonalDetails.organization}},
                          @{Name="Profession"; Expression={$_.PersonalDetails.profession}} |
            Export-Csv -Path $Script:UserCachePath -NoTypeInformation

        Write-Log "User cache updated at: $Script:UserCachePath"
    }
    catch {
        Write-Host "ERROR: Failed to fetch PAS users." -ForegroundColor Red
        throw
    }
}

# ---------------------------------------------------------
# Get user details from cache
# ---------------------------------------------------------
function Get-CACUserFromCache {
    param([string]$UserName)

    Update-CACUserCache

    Write-Log "Looking up user '$UserName' from users.csv..."

    $csv = Import-Csv $Script:UserCachePath
    $match = $csv | Where-Object { $_.UserName -eq $UserName }

    if ($match) {
        Write-Log "User found in cache: $($match.DisplayName)"
        return $match
    } else {
        Write-Log "User NOT found in users.csv"
        return $null
    }
}

# ---------------------------------------------------------
# Resolve PAS group members
# ---------------------------------------------------------
function Get-CACGroupMembers {
    param([string]$GroupName)

    Write-Log "Fetching members of group: $GroupName"

    try {
        # psPAS Cmdlet
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true

        if (-not $group) {
            Write-Log "Group not found in PAS."
            return @()
        }

        $members = $group.Members.DisplayName
        Write-Log "Group has $($members.Count) members."

        return $members
    }
    catch {
        Write-Host "ERROR: Failed to fetch group members for $GroupName" -ForegroundColor Red
        return @()
    }
}

Export-ModuleMember -Function * -Alias *
