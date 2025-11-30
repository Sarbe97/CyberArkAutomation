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
    # if (Test-Path $Script:UserCachePath) {
    #     $timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
    #     $backupPath = $Script:UserCachePath.Replace(".csv", "_$timestamp.csv")

    #     Rename-Item -Path $Script:UserCachePath -NewName $backupPath -Force
    #     Write-Log "Existing cache renamed to: $backupPath" "INFO"
    # }

    # ---------- Fetch users (shallow details) ----------
    try {
        Write-Log "Fetching PAS users (Get-PASUser -ExtendedDetails \$true)" "INFO"
        $users = Get-PASUser

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
    $total = $users.Count
    $counter = 1
    foreach ($u in $users) {
        Write-Log "Fetching full details for User ($counter/$total) User ID: $($u.id)" "DEBUG"

        try {
            $detail = Get-PASUser -id $u.id
        }
        catch {
            Write-Log "Failed to fetch full details for $($u.UserName). Using shallow data." "WARN"
            $detail = $u
        }

        # Build Full Name
        # Build Full Name safely
        $first = ($detail.personalDetails.firstName) -as [string]
        $middle = ($detail.personalDetails.middleName) -as [string]
        $last = ($detail.personalDetails.lastName) -as [string]

        $parts = @()
        if ($first) { $parts += $first }
        if ($middle) { $parts += " $middle" }
        if ($last) { $parts += " $last" }

        $fullName = ($parts -join " ").Trim()

        # if($detail.Source -eq "EPVUser") {
        # }  

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

        $counter++
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
    Write-Log "Importing CyberArk user cache..." "DEBUG"

    # -----------------------------------------------------
    # Check if file exists
    # -----------------------------------------------------
    if (-not (Test-Path $Script:UserCachePath)) {
        Write-Log "User cache not found — forcing refresh" "WARN"
        Write-Host "`nDEBUG: Cache file missing at: $Script:UserCachePath`n" -ForegroundColor Yellow
        
        Refresh-CACUserStore
    }

    # -----------------------------------------------------
    # Debug: Cache file info
    # -----------------------------------------------------
    try {
        $fileInfo = Get-Item $Script:UserCachePath
        Write-Host "DEBUG: Cache file found:" -ForegroundColor Cyan
        Write-Host " Path: $($fileInfo.FullName)"
        Write-Host " Size: $([math]::Round($fileInfo.Length / 1KB, 2)) KB"
        Write-Host " LastWrite: $($fileInfo.LastWriteTime)"
        Write-Host ""
    }
    catch {
        Write-Host "DEBUG: Could not read file info: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # -----------------------------------------------------
    # Try importing CSV
    # -----------------------------------------------------
    try {
        $csv = Import-Csv $Script:UserCachePath

        if (-not $csv) {
            Write-Log "CSV imported but EMPTY — will refresh cache" "ERROR"
            Write-Host "`nDEBUG: Import-Csv returned NULL or EMPTY`n" -ForegroundColor Red
            
            Refresh-CACUserStore
            $csv = Import-Csv $Script:UserCachePath
        }

        # -------------------------------------------------
        # Debug: Show number of rows
        # -------------------------------------------------
        Write-Log "User cache import successful. Rows: $($csv.Count)" "DEBUG"

        Write-Host "`n--- DEBUG: First 5 rows of user cache ---" -ForegroundColor Cyan
        $csv | Select-Object -First 5 | Format-Table | Out-Host
        Write-Host "------------------------------------------`n" -ForegroundColor Cyan

        return $csv
    }
    catch {
        Write-Log "User cache corrupted — forcing refresh" "ERROR"
        Write-Host "`nDEBUG: Import-Csv failed:`n $($_.Exception.Message)`n" -ForegroundColor Red
        
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
    if (-not $users) {
        Write-Log "User cache is EMPTY — no records found" "ERROR"
        Write-Host "`n--- DEBUG: Import-CACUserStore returned nothing ---`n" -ForegroundColor Red
        return $null
    }

    Write-Log "User cache loaded. Total users: $($users.Count)" "DEBUG"

    # Optional: print first few rows for debugging
    Write-Host "`n--- DEBUG: First 5 cached users ---" -ForegroundColor Cyan
    $users | Select-Object -First 5 | Format-Table | Out-Host
    Write-Host "-----------------------------------`n" -ForegroundColor Cyan

    
    $isId = $InputValue -match "^\d+$"

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
