# ==========================
# Users.psm1 (Enhanced + Correct)
# ==========================

Import-Module "$PSScriptRoot/Utils.psm1" -Force

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"


# ================================================================
# 1. Refresh User Cache WITH deep details from Get-PASUser -id
# ================================================================
function Refresh-CACUserStore {
    Write-Log "Force refreshing CyberArk user cache" "INFO"

    # ---------- Rename existing cache ----------
    if (Test-Path $Script:UserCachePath) {
        $timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
        $backupPath = $Script:UserCachePath.Replace(".csv", "_$timestamp.csv")

        Rename-Item -Path $Script:UserCachePath -NewName $backupPath -Force
        Write-Log "Existing cache renamed to: $backupPath" "INFO"
    }

    # ---------- Fetch users (shallow details) ----------
    try {
        Write-Log "Fetching PAS users (Get-PASUser -ExtendedDetails \$true)" "INFO"
        $users = Get-PASUser -ExtendedDetails $true

        if (-not $users) {
            Write-Log "ERROR: No users returned from PAS" "ERROR"
            return
        }

        Write-Log "Fetched $($users.Count) users (shallow results)" "SUCCESS"
    }
    catch {
        Write-Log "ERROR while fetching PAS users: $($_.Exception.Message)" "ERROR"
        return
    }

    # ---------- Ensure Data folder ----------
    $folder = Split-Path $Script:UserCachePath
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
        Write-Log "Created folder: $folder" "INFO"
    }

    # ---------- Build final enriched user list ----------
    $finalUsers = @()

    foreach ($u in $users) {
        Write-Log "Fetching full details for User ID: $($u.id)" "DEBUG"

        try {
            $detail = Get-PASUser -id $u.id -ExtendedDetails $true
        }
        catch {
            Write-Log "Failed to fetch full details for $($u.UserName). Using shallow data." "WARN"
            $detail = $u
        }

        # Build Full Name
        $first = $detail.personalDetails.firstName
        $middle = $detail.personalDetails.middleName
        $last = $detail.personalDetails.lastName

        $fullName = ($first, $middle, $last -ne $null -and $_ -ne "") -join " "
        $fullName = $fullName.Trim()

        $finalUsers += [PSCustomObject]@{
            id           = $detail.id
            UserName     = $detail.UserName
            Description  = $detail.Description
            Source       = $detail.Source
            UserType     = $detail.UserType
            FullName     = $fullName
            Department   = $detail.personalDetails.department
            Title        = $detail.personalDetails.title
            Organization = $detail.personalDetails.organization
        }
    }

    # ---------- Export to CSV ----------
    $finalUsers |
    Export-Csv -Path $Script:UserCachePath -NoTypeInformation

    Write-Log "New enriched user cache created at $Script:UserCachePath" "SUCCESS"
}


# =====================================================================
# 2. Import User Cache (Used Internally)
# =====================================================================
function Import-CACUserStore {
    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "User cache not found — forcing refresh" "WARN"
        Refresh-CACUserStore
    }

    try {
        return Import-Csv $Script:UserCachePath
    }
    catch {
        Write-Log "User cache corrupted — forcing refresh" "ERROR"
        Refresh-CACUserStore
        return Import-Csv $Script:UserCachePath
    }
}


# =====================================================================
# 3. Search User by Name OR ID Automatically
# =====================================================================
function Find-CACUser {
    param(
        [Parameter(Mandatory)][string]$InputValue
    )

    Write-Log "Find-CACUser() input: $InputValue" "INFO"

    $users = Import-CACUserStore

    $isId = $InputValue -match "^[a-fA-F0-9\-]{24,36}$"

    if ($isId) {
        Write-Log "Treating as USER ID" "INFO"
        $match = $users | Where-Object { $_.id -eq $InputValue }
    }
    else {
        Write-Log "Treating as USERNAME" "INFO"
        $match = $users | Where-Object { $_.UserName -eq $InputValue -or $_.FullName -like "*$InputValue*" }
    }

    if (-not $match) {
        Write-Host "No user found for input: $InputValue" -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nUser Details:" -ForegroundColor Cyan
    $match | Format-List *

    return $match
}


# =====================================================================
# 4. Return Enriched Group Users
# =====================================================================
function Get-CACGroupUsers {
    param([Parameter(Mandatory)][string]$GroupName)

    Write-Log "Fetching group: $GroupName" "INFO"

    try {
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true
    }
    catch {
        Write-Log "Error fetching group: $($_.Exception.Message)" "ERROR"
        return
    }

    if (-not $group -or -not $group.Members) {
        Write-Host "Group has no members!" -ForegroundColor Yellow
        return
    }

    $users = Import-CACUserStore

    $output = foreach ($m in $group.Members) {
        $row = $users | Where-Object { $_.UserName -eq $m.UserName }

        if ($row) {
            [PSCustomObject]@{
                UserName     = $row.UserName
                FullName     = $row.FullName
                Department   = $row.Department
                Title        = $row.Title
                Organization = $row.Organization
            }
        }
        else {
            [PSCustomObject]@{
                UserName     = $m.UserName
                FullName     = ""
                Department   = ""
                Title        = ""
                Organization = ""
            }
        }
    }

    $output | Format-Table -AutoSize
    return $output
}


Export-ModuleMember -Function *
