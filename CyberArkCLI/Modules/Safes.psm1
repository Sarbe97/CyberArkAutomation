# ==========================
# Safes.psm1
# ==========================

Import-Module "$PSScriptRoot/Config.psm1" -Force
Import-Module "$PSScriptRoot/Users.psm1" -Force
Import-Module "$PSScriptRoot/Utils.psm1" -Force

# =========================================================
# Utility: Format a safe object for consistent CSV output
# =========================================================
function Format-CACSafe {
    param([Parameter(Mandatory)][object]$Safe)

    Write-Log "Formatting safe object: $($Safe.safeName)" "DEBUG"

    return [PSCustomObject]@{
        SafeName                  = $Safe.safeName
        SafeUrlId                 = $Safe.safeUrlId
        SafeNumber                = $Safe.safeNumber
        Description               = $Safe.description
        Location                  = $Safe.location

        CreatorId                 = $Safe.creator.id
        CreatorName               = $Safe.creator.name

        NumberOfVersionsRetention = $Safe.numberOfVersionsRetention
        NumberOfDaysRetention     = $Safe.numberOfDaysRetention
        AutoPurgeEnabled          = $Safe.autoPurgeEnabled

        CreationTime              = Convert-CACTimestamp $Safe.creationTime
        LastModificationTime      = Convert-CACTimestamp $Safe.lastModificationTime

        ManagingCPM               = $Safe.managingCPM
        OlacEnabled               = $Safe.olacEnabled
    }
}

# =========================================================
# 1. Export ALL Safes (native PAS pagination)
# =========================================================
function Export-CACAllSafes {
    Write-Log "Started Export-CACAllSafes()" "DEBUG"
    Write-Log "Fetching all safes using Get-PASSafe" "INFO"

    try {
        Write-Log "Calling Get-PASSafe" "DEBUG"
        $resp = Get-PASSafe

        if (-not $resp.value) {
            Write-Log "No safes returned" "WARN"
            return
        }

        Write-Log "Total safes returned: $($resp.value.Count)" "INFO"

        $formatted = $resp.value | ForEach-Object { Format-CACSafe $_ }

        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $outputFile = "$outputDir/all_safes.csv"
        Write-Log "Exporting safe details to: $outputFile" "INFO"
        $formatted | Export-Csv -Path $outputFile -NoTypeInformation

        Write-Log "Export complete: $outputFile" "SUCCESS"
    }
    catch {
        Write-Log "Error during Export-CACAllSafes(): $($_.Exception.Message)" "ERROR"
        throw
    }

    Write-Log "Completed Export-CACAllSafes()" "DEBUG"
}

# =========================================================
# 2. Search Safe by Name → CSV Output
# =========================================================
function Search-CACSafeByName {
    param(
        [Parameter(Mandatory)]
        [string]$SafeName
    )

    Write-Log "Search-CACSafeByName() started for Safe: $SafeName" "INFO"

    try {
        Write-Log "Calling Get-PASSafe -SafeName $SafeName" "DEBUG"
        $resp = Get-PASSafe -SafeName $SafeName
        Write-Host "$resp"
        if (-not $resp) {
            Write-Log "Safe '$SafeName' not found" "WARN"
            Write-Host "Safe not found!" -ForegroundColor Yellow
            return
        }

        Write-Log "Safe object received. Formatting..." "DEBUG"
        $formatted = Format-CACSafe -Safe $resp

        # Ensure output directory
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created" "DEBUG"
        }

        $file = "$outputDir/search_safe_${SafeName}.csv"
        Write-Log "Saving search results to: $file" "INFO"

        $formatted | Export-Csv -Path $file -NoTypeInformation

        Write-Log "Safe search export completed successfully  $file" "SUCCESS"
    }
    catch {
        Write-Log "Error searching safe '$SafeName': $($_.Exception.Message)" "ERROR"
        throw
    }
}

# ---------------------------------------------------------
# Utility: Resolve Identity (user or group)
# ---------------------------------------------------------
# function Resolve-CACIdentity {
#     param([string]$Identity)

#     Write-Log "Resolving identity: $Identity" "DEBUG"

#     if ($Identity -match "^GRP_" -or $Identity -match "Group") {
#         Write-Log "Identity appears to be a group: $Identity" "INFO"

#         try {
#             $members = Get-CACGroupUsers -GroupName $Identity
#             return $members
#         }
#         catch {
#             Write-Log "Failed to resolve group $Identity - $($_.Exception.Message)" "WARN"
#             return @()
#         }
#     }

#     Write-Log "Identity treated as user: $Identity" "DEBUG"
#     return @($Identity)
# }

# ---------------------------------------------------------
# Utility: Enrich user from cache
# ---------------------------------------------------------


# ---------------------------------------------------------
# Export Safe Members
# ---------------------------------------------------------
function Export-CACSafeMembers {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    Write-Log "Starting Export-CACSafeMembers" "INFO"

    $safeList = Get-PASSafe
    $rows = @()

    foreach ($safe in $safeList) {

        Write-Log "Processing safe: $($safe.SafeName)" "INFO"

        try {
            $members = Get-PASSafeMember -SafeName $safe.SafeName
        }
        catch {
            Write-Log "Error getting members for $($safe.SafeName): $($_.Exception.Message)" "ERROR"
            continue
        }

        if (-not $members) {
            Write-Log "No members found for $($safe.SafeName)" "WARN"
            continue
        }

        foreach ($m in $members) {

            # --------------------------
            # USER
            # --------------------------
            if ($m.MemberType -eq "User") {
                $enriched = Get-CACEnrichedMemberDetails -UserName $m.MemberName

                $rows += [PSCustomObject]@{
                    SafeName     = $safe.SafeName
                    UserName     = $enriched.UserName
                    DisplayName  = $enriched.DisplayName
                    Department   = $enriched.Department
                    Title        = $enriched.Title
                    Organization = $enriched.Organization
                    Profession   = $enriched.Profession
                }

                continue
            }

            # --------------------------
            # GROUP
            # --------------------------
            if ($m.MemberType -eq "Group") {

                Write-Log "Expanding group: $($m.MemberName)" "DEBUG"

                try {
                    $groupUsers = Get-CACGroupUsers -GroupName $m.MemberName
                }
                catch {
                    Write-Log "Failed to expand group $($m.MemberName): $($_.Exception.Message)" "WARN"
                    continue
                }

                if ($groupUsers) {
                    foreach ($g in $groupUsers) {
                        $rows += [PSCustomObject]@{
                            SafeName     = $safe.SafeName
                            UserName     = $g.UserName
                            DisplayName  = $g.DisplayName
                            Department   = $g.Department
                            Title        = $g.Title
                            Organization = $g.Organization
                            Profession   = $g.Profession
                        }
                    }
                }

                continue
            }

        } # end members
    } # end safes

    # --------------------------
    # WRITE CSV
    # --------------------------
    $rows | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Export complete → $OutputPath" "SUCCESS"
}




#####################
## get all users, member- users
#####################

function Export-CACSafeUsers {
    param(
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter()][string]$OutputPath = "$PSScriptRoot/../Output/${SafeName}_Users.csv"
    )

    Write-Log "Exporting SAFE USERS of safe: $SafeName" "INFO"

    # Load user cache
    $userCache = Import-CACUserStore
    if (-not $userCache) {
        Write-Log "User cache empty cannot enrich" "ERROR"
        return
    }

    try {
        $members = Get-PASSafeMember -SafeName $SafeName -ErrorAction Stop
    }
    catch {
        Write-Log "Failed fetching members: $($_.Exception.Message)" "ERROR"
        return
    }

    if (-not $members) {
        Write-Log "No members found for safe: $SafeName" "WARN"
        return
    }

    $finalUsers = @()

    foreach ($m in $members) {

        # ------------------------------
        # CASE 1: Member is USER
        # ------------------------------
        if ($m.MemberType -eq "User") {
            $row = $userCache | Where-Object { $_.UserName -eq $m.MemberName }

            if ($row) {
                $finalUsers += [PSCustomObject]@{
                    SafeName     = $SafeName
                    MemberName   = $m.MemberName
                    MemberType   = "User"
                    UserName     = $row.UserName
                    FullName     = $row.FullName
                    Department   = $row.Department
                    Title        = $row.Title
                    Organization = $row.Organization
                }
            }
            else {
                # fallback
                $finalUsers += [PSCustomObject]@{
                    SafeName     = $SafeName
                    MemberName   = $m.MemberName
                    MemberType   = "User"
                    UserName     = $m.MemberName
                    FullName     = ""
                    Department   = ""
                    Title        = ""
                    Organization = ""
                }
            }

        }

        # ------------------------------
        # CASE 2: Member is GROUP
        # ------------------------------
        elseif ($m.MemberType -eq "Group") {
            Write-Log "Expanding group: $($m.MemberName)" "INFO"

            $grpUsers = Get-CACGroupUsers -GroupName $m.MemberName

            foreach ($gu in $grpUsers) {
                $finalUsers += [PSCustomObject]@{
                    SafeName     = $SafeName
                    MemberName   = $m.MemberName
                    MemberType   = "Group"
                    UserName     = $gu.UserName
                    FullName     = $gu.FullName
                    Department   = $gu.Department
                    Title        = $gu.Title
                    Organization = $gu.Organization
                }
            }
        }
    }

    # Export CSV
    $finalUsers | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Log "Safe USER export complete: $OutputPath" "SUCCESS"
}

# ---------------------------------------------------------
# Create Safes
# ---------------------------------------------------------
function New-CACSafe {
    Write-Log "Started New-CACSafe()" "DEBUG"

    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV"
    $mode = Read-Host "Enter choice"

    $safeData = @()

    switch ($mode) {
        "1" {
            $safeName = Read-Host "Safe Name"
            $desc = Read-Host "Description"
            $cpm = Read-Host "Managing CPM"
            if (-not $cpm) { $cpm = "" }

            $safeData += [PSCustomObject]@{
                SafeName    = $safeName
                Description = $desc
                ManagingCPM = $cpm
            }
        }

        "2" {
            $csvPath = Read-Host "CSV Path"
            if (-not (Test-Path $csvPath)) {
                Write-Log "CSV missing: $csvPath" "ERROR"
                return
            }
            $safeData = Import-Csv $csvPath
        }

        default {
            Write-Log "Invalid mode selected" "WARN"
            return
        }
    }

    foreach ($safe in $safeData) {
        Write-Log "Creating safe: $($safe.SafeName)" "INFO"

        try {
            Add-PASSafe -SafeName $safe.SafeName `
                -Description $safe.Description `
                -ManagingCPM $safe.ManagingCPM -ErrorAction Stop

            Write-Log "Safe created: $($safe.SafeName)" "SUCCESS"
        }
        catch {
            Write-Log "Error creating safe $($safe.SafeName): $($_.Exception.Message)" "ERROR"
        }
    }

    Write-Log "Completed New-CACSafe()" "DEBUG"
}

# ---------------------------------------------------------
# Add Safe Member(s)
# ---------------------------------------------------------
function Add-CACSafeMember {
    Write-Log "Started Add-CACSafeMember()" "DEBUG"

    $config = Get-CACConfig
    $permissionSets = $config.SafePermissionSets

    Write-Log "Loaded permission sets" "DEBUG"

    Write-Host "Choose mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV"
    $mode = Read-Host "Enter choice"

    $entries = @()

    switch ($mode) {
        "1" {
            $safe = Read-Host "Safe Name"
            $member = Read-Host "Member Name"

            Write-Host "Permission Sets:"
            $i = 1
            foreach ($key in $permissionSets.Keys) { Write-Host "$i. $key"; $i++ }

            $sel = Read-Host "Select permission set"
            $permKey = $permissionSets.Keys[[int]$sel - 1]

            $entries += [PSCustomObject]@{
                SafeName      = $safe
                Member        = $member
                PermissionKey = $permKey
            }
        }

        "2" {
            $csvPath = Read-Host "CSV Path"
            if (-not (Test-Path $csvPath)) {
                Write-Log "CSV missing: $csvPath" "ERROR"
                return
            }
            $entries = Import-Csv $csvPath
        }
    }

    foreach ($e in $entries) {
        Write-Log "Adding $($e.Member) to $($e.SafeName)" "INFO"

        $permissions = $permissionSets[$e.PermissionKey]
        if (-not $permissions) {
            Write-Log "Invalid permission key: $($e.PermissionKey)" "WARN"
            continue
        }

        try {
            Add-PASSafeMember -SafeName $e.SafeName `
                -MemberName $e.Member `
                -SearchInVault $true `
                -Permissions $permissions -ErrorAction Stop

            Write-Log "Member added: $($e.Member) → $($e.SafeName)" "SUCCESS"
        }
        catch {
            Write-Log "Error adding member $($e.Member): $($_.Exception.Message)" "ERROR"
        }
    }

    Write-Log "Completed Add-CACSafeMember()" "DEBUG"
}

# Export module members
Export-ModuleMember -Function * -Alias *
