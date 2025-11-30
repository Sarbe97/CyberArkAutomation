# ==========================
# Safes.psm1
# ==========================

Import-Module "$PSScriptRoot/Config.psm1" -Force
Import-Module "$PSScriptRoot/Users.psm1" -Force

# Helper logger
function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# ---------------------------------------------------------
# 1. Export ALL Safe Details → CSV
# ---------------------------------------------------------
function Export-CACAllSafes {
    Write-Log "Fetching all safes from PAS..."

    try {
        $safes = Get-PASSafe
        $outputFile = "$PSScriptRoot/../Output/all_safes.csv"

        if (-not (Test-Path "$PSScriptRoot/../Output")) {
            New-Item -ItemType Directory -Path "$PSScriptRoot/../Output" | Out-Null
        }

        $safes |
            Select-Object SafeName, Description, ManagingCPM, NumberOfVersionsRetention, Location |
            Export-Csv $outputFile -NoTypeInformation

        Write-Log "Export complete: $outputFile"
    }
    catch {
        Write-Host "ERROR: Failed to export safe details." -ForegroundColor Red
        throw
    }
}

# ---------------------------------------------------------
# Utility: Expand users or groups
# ---------------------------------------------------------
function Resolve-CACIdentity {
    param([string]$Identity)

    # If group → resolve members
    if ($Identity -match "^GRP_" -or $Identity -match "Group") {
        Write-Log "Resolving group: $Identity"
        return Get-CACGroupMembers -GroupName $Identity
    }

    # Else user
    Write-Log "Resolving user: $Identity"
    return @($Identity)
}

# ---------------------------------------------------------
# Utility: Enrich members with user details from cache
# ---------------------------------------------------------
function Get-CACEnrichedMemberDetails {
    param([string]$UserName)

    $details = Get-CACUserFromCache -UserName $UserName

    if ($details) {
        return [PSCustomObject]@{
            UserName     = $details.UserName
            DisplayName  = $details.DisplayName
            Department   = $details.Department
            Title        = $details.Title
            Organization = $details.Organization
            Profession   = $details.Profession
        }
    }

    # Fallback
    return [PSCustomObject]@{
        UserName     = $UserName
        DisplayName  = ""
        Department   = ""
        Title        = ""
        Organization = ""
        Profession   = ""
    }
}

# ---------------------------------------------------------
# 2. Export Safe Members
#     - Manual safe input OR CSV
#     - Expand groups
#     - Enrich with user details
# ---------------------------------------------------------
function Export-CACSafeMembers {
    Write-Log "Exporting Safe Members..."

    Write-Host "Choose input mode:"
    Write-Host "1. Manual (comma-separated list)"
    Write-Host "2. From CSV file"
    $mode = Read-Host "Enter choice"

    $safeList = @()

    switch ($mode) {
        "1" {
            $input = Read-Host "Enter Safe Names (comma-separated)"
            $safeList = $input.Split(",") | ForEach-Object { $_.Trim() }
        }

        "2" {
            $csvPath = Read-Host "Enter CSV file path containing SafeName column"
            if (-not (Test-Path $csvPath)) {
                Write-Host "CSV file not found." -ForegroundColor Red
                return
            }
            $safeList = (Import-Csv $csvPath).SafeName
        }

        default {
            Write-Host "Invalid choice." -ForegroundColor Yellow
            return
        }
    }

    Write-Log "Safes to process: $($safeList -join ', ')"

    $output = @()

    foreach ($safe in $safeList) {
        Write-Log "Processing safe: $safe"

        try {
            $members = Get-PASSafeMember -SafeName $safe
        }
        catch {
            Write-Log "ERROR: Failed fetching members for safe $safe"
            continue
        }

        foreach ($m in $members) {
            Write-Log "Found identity: $($m.MemberName)"

            # Expand if group
            $resolvedUsers = Resolve-CACIdentity -Identity $m.MemberName

            foreach ($user in $resolvedUsers) {
                $userInfo = Get-CACEnrichedMemberDetails -UserName $user

                $output += [PSCustomObject]@{
                    SafeName     = $safe
                    MemberName   = $m.MemberName
                    ResolvedUser = $userInfo.UserName
                    DisplayName  = $userInfo.DisplayName
                    Department   = $userInfo.Department
                    Title        = $userInfo.Title
                    Organization = $userInfo.Organization
                    Profession   = $userInfo.Profession
                    Permissions  = ($m.Permissions | ConvertTo-Json -Compress)
                }
            }
        }
    }

    $outFile = "$PSScriptRoot/../Output/safe_members_export.csv"

    if (-not (Test-Path "$PSScriptRoot/../Output")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot/../Output" | Out-Null
    }

    $output | Export-Csv -Path $outFile -NoTypeInformation

    Write-Log "Safe member export completed -> $outFile"
}

# ---------------------------------------------------------
# 3. Create Safe(s)
#     Manual + CSV mode
# ---------------------------------------------------------
function New-CACSafe {
    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV file"
    $mode = Read-Host "Enter choice"

    $safeData = @()

    switch ($mode) {
        "1" {
            $safeName = Read-Host "Safe Name"
            $desc     = Read-Host "Description"
            $cpm      = Read-Host "Managing CPM"

            $safeData += [PSCustomObject]@{
                SafeName = $safeName
                Description = $desc
                ManagingCPM = $cpm
            }
        }

        "2" {
            $csvPath = Read-Host "Enter Safe CSV Path"
            if (-not (Test-Path $csvPath)) {
                Write-Host "CSV file not found" -ForegroundColor Red
                return
            }
            $safeData = Import-Csv $csvPath
        }

        default {
            Write-Host "Invalid option." -ForegroundColor Yellow
            return
        }
    }

    foreach ($safe in $safeData) {
        Write-Log "Creating safe: $($safe.SafeName)"

        try {
            Add-PASSafe -SafeName $safe.SafeName `
                        -Description $safe.Description `
                        -ManagingCPM $safe.ManagingCPM

            Write-Log "Safe created successfully."
        }
        catch {
            Write-Log "ERROR creating safe: $($_)"
        }
    }
}

# ---------------------------------------------------------
# 4. Add Safe Member(s)
# ---------------------------------------------------------
function Add-CACSafeMember {

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    Write-Log "Loaded predefined permission sets from config."

    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV file"
    $mode = Read-Host "Enter choice"

    $entries = @()

    switch ($mode) {
        "1" {
            $safe  = Read-Host "Safe Name"
            $member = Read-Host "Member Name (user/group)"

            Write-Host "Select permission set:"
            $i = 1
            foreach ($key in $permissionSets.Keys) {
                Write-Host "$i. $key"
                $i++
            }

            $sel = Read-Host "Enter choice"
            $permKey = $permissionSets.Keys[[int]$sel - 1]

            $entries += [PSCustomObject]@{
                SafeName = $safe
                Member   = $member
                PermissionKey = $permKey
            }
        }

        "2" {
            $csvPath = Read-Host "Enter CSV path for members"
            if (-not (Test-Path $csvPath)) {
                Write-Host "CSV file missing" -ForegroundColor Red
                return
            }
            $entries = Import-Csv $csvPath
        }
    }

    foreach ($e in $entries) {
        Write-Log "Adding member: $($e.Member) to safe $($e.SafeName)"

        $permissions = $permissionSets[$e.PermissionKey]

        try {
            Add-PASSafeMember -SafeName $e.SafeName `
                              -MemberName $e.Member `
                              -SearchInVault $true `
                              -Permissions $permissions

            Write-Log "Member added successfully."
        }
        catch {
            Write-Log "ERROR adding safe member: $($_)"
        }
    }
}

Export-ModuleMember -Function * -Alias *
