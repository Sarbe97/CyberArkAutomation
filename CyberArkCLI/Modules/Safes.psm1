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
function Resolve-CACIdentity {
    param([string]$Identity)

    Write-Log "Resolving identity: $Identity" "DEBUG"

    if ($Identity -match "^GRP_" -or $Identity -match "Group") {
        Write-Log "Identity appears to be a group: $Identity" "INFO"

        try {
            $members = Get-CACGroupUsers -GroupName $Identity
            return $members
        }
        catch {
            Write-Log "Failed to resolve group $Identity - $($_.Exception.Message)" "WARN"
            return @()
        }
    }

    Write-Log "Identity treated as user: $Identity" "DEBUG"
    return @($Identity)
}

# ---------------------------------------------------------
# Utility: Enrich user from cache
# ---------------------------------------------------------
function Get-CACEnrichedMemberDetails {
    param([string]$UserName)

    Write-Log "Looking up user in cache: $UserName" "DEBUG"

    $details = Get-CACUserFromCache -UserName $UserName

    if ($details) {
        Write-Log "Cached user found: $UserName" "INFO"
        return [PSCustomObject]@{
            UserName     = $details.UserName
            DisplayName  = $details.DisplayName
            Department   = $details.Department
            Title        = $details.Title
            Organization = $details.Organization
            Profession   = $details.Profession
        }
    }

    Write-Log "User not found in cache: $UserName" "WARN"
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
# Export Safe Members
# ---------------------------------------------------------
function Export-CACSafeMembers {
    Write-Log "Started Export-CACSafeMembers()" "DEBUG"
    Write-Log "Prompting user for input mode" "INFO"

    Write-Host "Choose input mode:"
    Write-Host "1. Manual"
    Write-Host "2. CSV"
    $mode = Read-Host "Enter choice"

    $safeList = @()

    switch ($mode) {
        "1" {
            $inputSafeNames = Read-Host "Enter Safes (comma-separated)"
            $safeList = $inputSafeNames.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }

        "2" {
            $csvPath = Read-Host "Enter CSV path (column SafeName)"
            if (-not (Test-Path $csvPath)) {
                Write-Log "CSV missing: $csvPath" "ERROR"
                return
            }
            $safeList = (Import-Csv $csvPath).SafeName
        }

        default {
            Write-Log "Invalid input mode: $mode" "WARN"
            return
        }
    }

    Write-Log "Safes to process: $($safeList -join ', ')" "INFO"

    $output = @()

    foreach ($safe in $safeList) {
        Write-Log "Fetching members for safe: $safe" "INFO"

        try {
            $members = Get-PASSafeMember -SafeName $safe -ErrorAction Stop
        }
        catch {
            Write-Log "ERROR fetching members for $safe - $($_.Exception.Message)" "ERROR"
            continue
        }

        foreach ($m in $members) {
            Write-Log "Processing member: $($m.MemberName) (Type: $($m.MemberType))" "DEBUG"

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
                    Permissions  = ($m.Permissions -as [string])
                }
            }
        }
    }

    $outDir = "$PSScriptRoot/../Output"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    $outFile = "$outDir/safe_members_export.csv"
    $output | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8

    Write-Log "Safe member export complete → $outFile" "SUCCESS"
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
