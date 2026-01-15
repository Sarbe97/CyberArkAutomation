# ============================================================================
# MODULE: Users.psm1
# DESCRIPTION: User and Group operations using raw CyberArk REST API
# ============================================================================

# ============================================================
# 1. Get All Groups (Vault + LDAP)
# ============================================================
function Get-CACAllGroups {
    <#
    .SYNOPSIS
        Retrieves all groups from CyberArk (Vault internal and LDAP/Directory groups).
    .DESCRIPTION
        Calls the /API/UserGroups/ endpoint to fetch all groups.
        Optionally filters by group type (Vault or Directory).
        Exports results to CSV in NewCLI/Output folder.
    .PARAMETER GroupType
        Filter by group type: "All", "Vault", or "Directory" (LDAP)
    .PARAMETER IncludeMembers
        If set, includes member list for each group (slower performance)
    .PARAMETER ExportToCSV
        Export results to CSV file (default: true)
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("All", "Vault", "Directory")]
        [string]$GroupType = "All",

        [switch]$IncludeMembers,

        [bool]$ExportToCSV = $true
    )

    Write-Log "Started Get-CACAllGroups()" "DEBUG"
    Write-Log "GroupType filter: $GroupType, IncludeMembers: $IncludeMembers" "INFO"

    try {
        # Build endpoint with query parameters
        $queryParams = @()
        
        if ($GroupType -ne "All") {
            $queryParams += "filter=groupType eq $GroupType"
        }
        
        if ($IncludeMembers) {
            $queryParams += "includeMembers=true"
        }

        $endpoint = "/API/UserGroups/"
        if ($queryParams.Count -gt 0) {
            $endpoint += "?" + ($queryParams -join "&")
        }

        Write-Log "Calling endpoint: $endpoint" "DEBUG"
        Write-Host "Fetching groups from CyberArk..." -ForegroundColor Cyan

        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        # Parse groups from response
        $groups = @()
        if ($response.value) {
            $groups = @($response.value)
        }
        elseif ($response -is [array]) {
            $groups = @($response)
        }
        else {
            # Single group or direct response
            $groups = @($response)
        }

        if ($groups.Count -eq 0) {
            Write-Log "No groups found" "WARN"
            Write-Host "No groups found in CyberArk." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($groups.Count) groups" "INFO"

        # Format output
        $formattedGroups = @()
        $counter = 0

        foreach ($group in $groups) {
            $counter++
            Write-Progress -Activity "Processing Groups" -Status "$counter of $($groups.Count)" -PercentComplete (($counter / $groups.Count) * 100)

            $groupRecord = [PSCustomObject]@{
                GroupID     = $group.id
                GroupName   = $group.groupName
                GroupType   = $group.groupType
                Description = $group.description
                Location    = $group.location
                Directory   = $group.directory
                DN          = $group.dn
                MemberCount = if ($group.members) { $group.members.Count } else { "N/A" }
            }

            # If members were included, add member names
            if ($IncludeMembers -and $group.members) {
                $memberNames = ($group.members | ForEach-Object { $_.userName }) -join "; "
                $groupRecord | Add-Member -MemberType NoteProperty -Name "Members" -Value $memberNames
            }

            $formattedGroups += $groupRecord
        }

        Write-Progress -Activity "Processing Groups" -Completed

        # Display results
        Write-Host ""
        Write-Host "===== Groups Summary =====" -ForegroundColor Cyan
        Write-Host "Total Groups: $($formattedGroups.Count)"
        
        $vaultCount = ($formattedGroups | Where-Object { $_.GroupType -eq "Vault" }).Count
        $directoryCount = ($formattedGroups | Where-Object { $_.GroupType -eq "Directory" }).Count
        
        Write-Host "  Vault (Internal): $vaultCount"
        Write-Host "  Directory (LDAP): $directoryCount"
        Write-Host ""

        # Display table
        $formattedGroups | Format-Table -AutoSize @(
            "GroupName",
            "GroupType",
            "Description",
            "Location",
            "MemberCount"
        )

        # Export to CSV
        if ($ExportToCSV) {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/groups_$timestamp.csv"

            Write-Log "Exporting $($formattedGroups.Count) groups to CSV: $outputFile" "INFO"
            $formattedGroups | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

            Write-Log "CSV export successful: $outputFile" "SUCCESS"
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        Write-Log "Completed Get-CACAllGroups()" "DEBUG"
        return $formattedGroups
    }
    catch {
        Write-Log "Error in Get-CACAllGroups(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# ============================================================
# 2. Get Group Members by Group Name
# ============================================================
function Get-CACGroupMembers {
    <#
    .SYNOPSIS
        Retrieves members of a specific group.
    .PARAMETER GroupName
        Name of the group to look up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$GroupName
    )

    Write-Log "Started Get-CACGroupMembers()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            $GroupName = Read-Host "Enter Group Name"
            if ([string]::IsNullOrWhiteSpace($GroupName)) {
                Write-Host "Group name cannot be empty." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Fetching members for group: $GroupName" "INFO"
        Write-Host "Fetching members for group: $GroupName..." -ForegroundColor Cyan

        # Search for the group with members included
        $endpoint = "/API/UserGroups/?search=$([System.Web.HttpUtility]::UrlEncode($GroupName))&includeMembers=true"
        
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        # Find matching group
        $groups = @()
        if ($response.value) {
            $groups = @($response.value)
        }
        elseif ($response -is [array]) {
            $groups = @($response)
        }
        else {
            $groups = @($response)
        }

        $matchingGroup = $groups | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1

        if (-not $matchingGroup) {
            Write-Log "Group not found: $GroupName" "WARN"
            Write-Host "Group '$GroupName' not found." -ForegroundColor Yellow
            return
        }

        if (-not $matchingGroup.members -or $matchingGroup.members.Count -eq 0) {
            Write-Log "Group '$GroupName' has no members" "WARN"
            Write-Host "Group '$GroupName' has no members." -ForegroundColor Yellow
            return
        }

        # Format members
        $members = $matchingGroup.members | ForEach-Object {
            [PSCustomObject]@{
                UserID   = $_.id
                UserName = $_.userName
            }
        }

        Write-Host ""
        Write-Host "===== Members of '$GroupName' =====" -ForegroundColor Cyan
        Write-Host "Total Members: $($members.Count)"
        Write-Host ""

        $members | Format-Table -AutoSize

        Write-Log "Retrieved $($members.Count) members from $GroupName" "DEBUG"
        return $members
    }
    catch {
        Write-Log "Error in Get-CACGroupMembers(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# EXPORT ALL FUNCTIONS
# ============================================================
Export-ModuleMember -Function Get-CACAllGroups, Get-CACGroupMembers
