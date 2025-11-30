# ==========================
# Users.psm1
# ==========================
Import-Module "$PSScriptRoot/Utils.psm1" -Force

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"
$Script:CacheExpiryDays = 7

 

# ==========================================================
# Update-CACUserCache — Refresh user cache if stale or missing
# ==========================================================
function Update-CACUserCache {
    Write-Log "Checking user cache path: $Script:UserCachePath" "DEBUG"

    $needsRefresh = $false

    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "User cache file does NOT exist — refresh required" "WARN"
        $needsRefresh = $true
    }
    elseif ((Get-Item $Script:UserCachePath).Length -eq 0) {
        Write-Log "User cache exists but EMPTY — refresh required" "WARN"
        $needsRefresh = $true
    }
    else {
        $lastWrite = (Get-Item $Script:UserCachePath).LastWriteTime
        Write-Log "User cache last updated: $lastWrite" "DEBUG"

        if ($lastWrite -lt (Get-Date).AddDays(-$Script:CacheExpiryDays)) {
            Write-Log "User cache older than $Script:CacheExpiryDays days — refresh required" "WARN"
            $needsRefresh = $true
        }
        else {
            Write-Log "User cache is fresh — no refresh needed" "INFO"
        }
    }

    if ($needsRefresh) {
        Write-Log "Triggering Refresh-CACUsers()" "INFO"
        Refresh-CACUsers
    }
}

# ==========================================================
# Refresh-CACUsers — Fetch all PAS users and write users.csv
# ==========================================================
function Refresh-CACUsers {
    Write-Log "Starting PAS user fetch using Get-PASUser..." "INFO"

    try {
        Write-Log "Calling Get-PASUser -ExtendedDetails \$true" "DEBUG"
        $users = Get-PASUser -ExtendedDetails $true

        if (-not $users) {
            Write-Log "Get-PASUser returned ZERO users" "WARN"
        }
        else {
            Write-Log "Fetched $($users.Count) users from PAS" "SUCCESS"
        }

        $folder = Split-Path $Script:UserCachePath
        Write-Log "Ensuring cache folder exists: $folder" "DEBUG"

        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder | Out-Null
            Write-Log "Created missing folder: $folder" "INFO"
        }

        Write-Log "Writing users to CSV: $Script:UserCachePath" "INFO"

        $users |
            Select-Object UserName,
                          DisplayName,
                          Source,
                          UserType,
                          @{Name="Department";   Expression={$_.PersonalDetails.department}},
                          @{Name="Title";        Expression={$_.PersonalDetails.title}},
                          @{Name="Organization"; Expression={$_.PersonalDetails.organization}},
                          @{Name="Profession";   Expression={$_.PersonalDetails.profession}} |
            Export-Csv -Path $Script:UserCachePath -NoTypeInformation

        Write-Log "User cache updated successfully" "SUCCESS"
    }
    catch {
        Write-Log "ERROR fetching PAS users: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# ==========================================================
# Get-CACUserFromCache — Look up user in users.csv
# ==========================================================
function Get-CACUserFromCache {
    param([string]$UserName)

    Write-Log "Lookup requested for username: $UserName" "INFO"

    Update-CACUserCache

    Write-Log "Loading user cache CSV: $Script:UserCachePath" "DEBUG"
    try {
        $csv = Import-Csv $Script:UserCachePath
    }
    catch {
        Write-Log "Failed to read user CSV: $($_.Exception.Message)" "ERROR"
        return $null
    }

    Write-Log "Searching for exact username match..." "DEBUG"

    $match = $csv | Where-Object { $_.UserName -eq $UserName }

    if ($match) {
        Write-Log "Match FOUND: DisplayName = $($match.DisplayName)" "SUCCESS"
        return $match
    }
    else {
        Write-Log "No match found for '$UserName' in cached user list" "WARN"
        return $null
    }
}

# ==========================================================
# Get-CACGroupMembers — Resolve CyberArk group member list
# ==========================================================
function Get-CACGroupMembers {
    param([string]$GroupName)

    Write-Log "Fetching PAS group details for: $GroupName" "INFO"

    try {
        Write-Log "Calling Get-PASGroup -GroupName $GroupName -IncludeMembers \$true" "DEBUG"
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true

        if (-not $group) {
            Write-Log "PAS group '$GroupName' NOT FOUND" "WARN"
            return @()
        }

        if (-not $group.Members) {
            Write-Log "Group '$GroupName' has ZERO members" "WARN"
            return @()
        }

        $members = $group.Members.DisplayName

        Write-Log "Group '$GroupName' contains $($members.Count) members" "SUCCESS"

        return $members
    }
    catch {
        Write-Log "ERROR resolving group members for '$GroupName': $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# ==========================================================
Export-ModuleMember -Function * -Alias *
