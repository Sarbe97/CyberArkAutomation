# ==========================
# Users.psm1 (Clean + Unified Object Model)
# ==========================

Import-Module "$PSScriptRoot/Utils.psm1" -Force

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"

# ------------------------------------------------------------
# Shared reusable User Object (TypeScript-style model)
# ------------------------------------------------------------
function New-CACUserObject {
    param(
        [string]$Id = "",
        [string]$UserName = "",
        [string]$FullName = "",
        [string]$Department = "",
        [string]$Title = "",
        [string]$Organization = ""
    )

    return [PSCustomObject]@{
        Id           = $Id
        UserName     = $UserName
        FullName     = $FullName
        Department   = $Department
        Title        = $Title
        Organization = $Organization
    }
}

# ------------------------------------------------------------
# Refresh full user cache from CyberArk
# ------------------------------------------------------------
function Initialize-CACUserStore {
    Write-Log "Refreshing CyberArk user cache" "INFO"

    try {
        $users = Get-PASUser
        if (-not $users) {
            Write-Log "No PAS users returned" "ERROR"
            return
        }
    }
    catch {
        Write-Log "Failed fetching PAS users: $($_.Exception.Message)" "ERROR"
        return
    }

    $finalUsers = @()
    $counter = 1
    $total = $users.Count

    foreach ($u in $users) {
        Write-Log "Fetching full details ($counter/$total): $($u.id)" "DEBUG"

        try { $detail = Get-PASUser -id $u.id } 
        catch { $detail = $u }

        $first = $detail.personalDetails.firstName
        $middle = $detail.personalDetails.middleName
        $last = $detail.personalDetails.lastName
        $fullName = "$first $middle $last".Trim()

        $finalUsers += New-CACUserObject `
            -Id $detail.id `
            -UserName $detail.UserName `
            -FullName $fullName `
            -Department $detail.personalDetails.department `
            -Title $detail.personalDetails.title `
            -Organization $detail.personalDetails.organization

        $counter++
    }

    $folder = Split-Path $Script:UserCachePath
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }

    $finalUsers | Export-Csv -Path $Script:UserCachePath -NoTypeInformation
    Write-Log "User cache updated at $Script:UserCachePath" "SUCCESS"
}

# ------------------------------------------------------------
# Import Cached Users
# ------------------------------------------------------------
function Get-CACUserStore {

    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "Cache missing — rebuilding" "WARN"
        Initialize-CACUserStore
    }

    try { $csv = Import-Csv $Script:UserCachePath }
    catch {
        Write-Log "Cache corrupted — rebuilding" "ERROR"
        Initialize-CACUserStore
        $csv = Import-Csv $Script:UserCachePath
    }

    if (-not $csv -or $csv.Count -eq 0) {
        Write-Log "Cache empty — no user data" "WARN"
        return @()
    }

    return $csv
}

# ------------------------------------------------------------
# Get user by username OR ID
# ------------------------------------------------------------
function Get-UserDetailsFromStore {
    param([Parameter(Mandatory)][string]$InputValue)

    Write-Log "Looking up user: $InputValue" "DEBUG"

    $users = Get-CACUserStore
    if (-not $users) {
        Write-Log "Empty cache — cannot enrich" "ERROR"
        return New-CACUserObject -UserName $InputValue
    }

    $searchById = $InputValue -match "^\d+$"

    if ($searchById) {
        $match = $users | Where-Object { $_.Id -eq $InputValue }
    }
    else {
        $match = $users | Where-Object {
            $_.UserName -eq $InputValue -or $_.FullName -like "*$InputValue*"
        }
    }

    if (-not $match) {
        Write-Log "No user found: $InputValue" "WARN"
        return New-CACUserObject -UserName $InputValue
    }

    return New-CACUserObject `
        -Id $match.Id `
        -UserName $match.UserName `
        -FullName $match.FullName `
        -Department $match.Department `
        -Title $match.Title `
        -Organization $match.Organization
}

# ------------------------------------------------------------
# Get all users inside a group (enriched)
# ------------------------------------------------------------
function Get-CACGroupUsers {
    param([Parameter(Mandatory)][string]$GroupName)

    Write-Log "Fetching group: $GroupName" "INFO"

    try {
        $group = Get-PASGroup -GroupName $GroupName -IncludeMembers $true
    }
    catch {
        Write-Log "Group fetch failed: $($_.Exception.Message)" "ERROR"
        return
    }

    if (-not $group.Members) {
        Write-Log "Group has no members" "WARN"
        return
    }

    $output = foreach ($m in $group.Members) {
        Get-UserDetailsFromStore -InputValue $m.UserName
    }

    $output | Format-Table -AutoSize
    return $output
}

Export-ModuleMember -Function *
