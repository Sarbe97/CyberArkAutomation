# ==========================
# Users.psm1 (Improved)
# ==========================

Import-Module "$PSScriptRoot/Utils.psm1" -Force

$Script:UserCachePath = "$PSScriptRoot/../Data/users.csv"


# ================================================================
# 1. Refresh User Cache ALWAYS — Rename Old + Create New
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

    # ---------- Fetch users ----------
    try {
        Write-Log "Fetching PAS users (Get-PASUser -ExtendedDetails \$true)" "INFO"
        $users = Get-PASUser -ExtendedDetails $true

        if (-not $users) {
            Write-Log "ERROR: No users returned from PAS" "ERROR"
            return
        }

        Write-Log "Fetched $($users.Count) users" "SUCCESS"
    }
    catch {
        Write-Log "ERROR while fetching PAS users: $($_.Exception.Message)" "ERROR"
        return
    }

    # ---------- Ensure folder ----------
    $folder = Split-Path $Script:UserCachePath
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
        Write-Log "Created folder: $folder" "INFO"
    }

    # ---------- Export new CSV ----------
    $users |
    Select-Object UserName, id, DisplayName, Source, UserType,
    @{Name = "Department"; Expression = { $_.personalDetails.department } },
    @{Name = "Title"; Expression = { $_.personalDetails.title } },
    @{Name = "Organization"; Expression = { $_.personalDetails.organization } },
    @{Name = "Profession"; Expression = { $_.personalDetails.profession } } |
    Export-Csv -Path $Script:UserCachePath -NoTypeInformation

    Write-Log "New user cache created at $Script:UserCachePath" "SUCCESS"
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

    # ---------------------------
    # Detect ID or Name
    # ---------------------------
    $isId = $false

    # CyberArk UserId is usually GUID-like
    if ($InputValue -match "^[a-fA-F0-9\-]{24,36}$") {
        $isId = $true
    }

    if ($isId) {
        Write-Log "Treating as USER ID" "INFO"
        $match = $users | Where-Object { $_.id -eq $InputValue }
    }
    else {
        Write-Log "Treating as USERNAME" "INFO"
        $match = $users | Where-Object { $_.UserName -eq $InputValue -or $_.DisplayName -like "*$InputValue*" }
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
                DisplayName  = $row.DisplayName
                Department   = $row.Department
                Title        = $row.Title
                Organization = $row.Organization
                Profession   = $row.Profession
            }
        }
        else {
            [PSCustomObject]@{
                UserName     = $m.UserName
                DisplayName  = ""
                Department   = ""
                Title        = ""
                Organization = ""
                Profession   = ""
            }
        }
    }

    $output | Format-Table -AutoSize
    return $output
}

 
Export-ModuleMember -Function *
