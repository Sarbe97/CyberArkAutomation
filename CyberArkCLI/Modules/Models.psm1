# ==========================
# Models.psm1 - Shared Data Models
# ==========================
# Central location for all reusable PSCustomObject builders

# ============================================================
# User Object Model
# ============================================================
function New-CACUserObject {
    param(
        [string]$Id = "",
        [string]$UserName = "",
        [string]$FullName = "",
        [string]$Email = "",
        [string]$Department = "",
        [string]$Title = "",
        [string]$Organization = "",
        [string]$Source = "",
        [string]$UserType = "",
        [string]$Phone = "",
        [string]$Mobile = "",
        [string]$Status = "",
        [string]$Created = "",
        [string]$LastLogin = ""
    )

    return [PSCustomObject]@{
        # Core Fields (used in Safe lookups)
        Id           = $Id
        UserName     = $UserName
        FullName     = $FullName
        
        # Contact Information
        Email        = $Email
        Phone        = $Phone
        Mobile       = $Mobile
        
        # Organization Information
        Department   = $Department
        Title        = $Title
        Organization = $Organization
        
        # Account Information
        Source       = $Source
        UserType     = $UserType
        Status       = $Status
        
        # Audit Information
        Created      = Convert-CACTimestamp $Created
        LastLogin    = Convert-CACTimestamp $LastLogin
    }
}


# ============================================================
# Safe Object Model (Format psPAS response into standard structure)
# ============================================================
function Format-CACSafe {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Safe
    )

    Write-Log "Formatting safe object: $($Safe.safeName)" "DEBUG"

    # ============================================================
    # Validate input
    # ============================================================
    if (-not $Safe) {
        Write-Log "Safe parameter is null" "ERROR"
        return $null
    }

    # ============================================================
    # Extract fields with null/empty checking
    # ============================================================
    
    # Basic fields (should always exist)
    $safeName = if ($Safe.safeName) { $Safe.safeName } else { "" }
    $safeUrlId = if ($Safe.safeUrlId) { $Safe.safeUrlId } else { "" }
    $safeNumber = if ($Safe.safeNumber) { $Safe.safeNumber } else { "" }
    
    Write-Log "Extracted basic fields: Name=$safeName, UrlId=$safeUrlId, Number=$safeNumber" "DEBUG"

    # ============================================================
    # Details (may not exist)
    # ============================================================
    $description = if ($Safe.description) { $Safe.description } else { "" }
    $location = if ($Safe.location) { $Safe.location } else { "" }
    $managingCPM = if ($Safe.managingCPM) { $Safe.managingCPM } else { "" }
    $olacEnabled = if ($Safe.olacEnabled -ne $null) { $Safe.olacEnabled } else { "" }

    Write-Log "Extracted details: Desc=$description, Loc=$location, CPM=$managingCPM" "DEBUG"

    # ============================================================
    # Creator (nested object - be careful!)
    # ============================================================
    $creatorId = ""
    $creatorName = ""
    
    if ($Safe.creator) {
        $creatorId = if ($Safe.creator.id) { $Safe.creator.id } else { "" }
        $creatorName = if ($Safe.creator.name) { $Safe.creator.name } else { "" }
        Write-Log "Extracted creator: Id=$creatorId, Name=$creatorName" "DEBUG"
    }
    else {
        Write-Log "Creator object is null/missing" "DEBUG"
    }

    # ============================================================
    # Retention Policy
    # ============================================================
    $numberOfVersionsRetention = if ($Safe.numberOfVersionsRetention -ne $null) { $Safe.numberOfVersionsRetention } else { "" }
    $numberOfDaysRetention = if ($Safe.numberOfDaysRetention -ne $null) { $Safe.numberOfDaysRetention } else { "" }
    $autoPurgeEnabled = if ($Safe.autoPurgeEnabled -ne $null) { $Safe.autoPurgeEnabled } else { "" }

    Write-Log "Extracted retention: Versions=$numberOfVersionsRetention, Days=$numberOfDaysRetention, Purge=$autoPurgeEnabled" "DEBUG"

    # ============================================================
    # Timestamps (convert using helper function)
    # ============================================================
    $creationTime = ""
    $lastModificationTime = ""

    try {
        if ($Safe.creationTime) {
            $creationTime = Convert-CACTimestamp $Safe.creationTime
            Write-Log "Converted creationTime: $creationTime" "DEBUG"
        }
    }
    catch {
        Write-Log "Error converting creationTime: $($_.Exception.Message)" "WARN"
        $creationTime = ""
    }

    try {
        if ($Safe.lastModificationTime) {
            $lastModificationTime = Convert-CACTimestamp $Safe.lastModificationTime
            Write-Log "Converted lastModificationTime: $lastModificationTime" "DEBUG"
        }
    }
    catch {
        Write-Log "Error converting lastModificationTime: $($_.Exception.Message)" "WARN"
        $lastModificationTime = ""
    }

    # ============================================================
    # Build output object
    # ============================================================
    try {
        $output = [PSCustomObject]@{
            # Safe Identification
            SafeName                  = $safeName
            SafeUrlId                 = $safeUrlId
            SafeNumber                = $safeNumber
            
            # Safe Details
            Description               = $description
            Location                  = $location
            ManagingCPM               = $managingCPM
            OlacEnabled               = $olacEnabled
            
            # Creator Information
            CreatorId                 = $creatorId
            CreatorName               = $creatorName
            
            # Retention Policy
            NumberOfVersionsRetention = $numberOfVersionsRetention
            NumberOfDaysRetention     = $numberOfDaysRetention
            AutoPurgeEnabled          = $autoPurgeEnabled
            
            # Timestamps
            CreationTime              = $creationTime
            LastModificationTime      = $lastModificationTime
        }

        Write-Log "Successfully created output object for safe: $safeName" "DEBUG"
        return $output
    }
    catch {
        Write-Log "Error creating output object: $($_.Exception.Message)" "ERROR"
        return $null
    }
}
# ============================================================
# Safe Member Object Model (for Export-CACSafeMembers)
# ============================================================
function New-CACSafeMemberRowWithPermissions {
    param(
        [string]$SafeName,
        [object]$MemberObj
    )

    return [PSCustomObject]@{
        SafeName           = $SafeName
        MemberName         = $MemberObj.MemberName
        MemberType         = $MemberObj.MemberType
        UseAccounts        = if ($MemberObj.Permissions.UseAccounts) { "Yes" } else { "No" }
        RetrieveAccounts   = if ($MemberObj.Permissions.RetrieveAccounts) { "Yes" } else { "No" }
        ListAccounts       = if ($MemberObj.Permissions.ListAccounts) { "Yes" } else { "No" }
        AddAccounts        = if ($MemberObj.Permissions.AddAccounts) { "Yes" } else { "No" }
        UpdateAccountContent = if ($MemberObj.Permissions.UpdateAccountContent) { "Yes" } else { "No" }
        UpdateAccountProperties = if ($MemberObj.Permissions.UpdateAccountProperties) { "Yes" } else { "No" }
        DeleteAccounts     = if ($MemberObj.Permissions.DeleteAccounts) { "Yes" } else { "No" }
        UnlockAccounts     = if ($MemberObj.Permissions.UnlockAccounts) { "Yes" } else { "No" }
        ManageSafeMembers  = if ($MemberObj.Permissions.ManageSafeMembers) { "Yes" } else { "No" }
        ManageSafe         = if ($MemberObj.Permissions.ManageSafe) { "Yes" } else { "No" }
        ViewAuditLog       = if ($MemberObj.Permissions.ViewAuditLog) { "Yes" } else { "No" }
        ViewSafeHistory    = if ($MemberObj.Permissions.ViewSafeHistory) { "Yes" } else { "No" }
        RequestsAuthorizationLevel = $MemberObj.Permissions.RequestsAuthorizationLevel
    }
}

# ============================================================
# Safe User Object Model (for Export-CACSafeUsers)
# ============================================================
function New-CACSafeUserRow {
    param(
        [string]$SafeName,
        [string]$SafeMember,
        [object]$UserObj
    )

    return [PSCustomObject]@{
        SafeName     = $SafeName
        SafeMember   = $SafeMember
        UserName     = $UserObj.UserName
        FullName     = $UserObj.FullName
        Title        = $UserObj.Title
        Organization = $UserObj.Organization
    }
}

# ============================================================
# EXPORT ALL MODEL FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    New-CACUserObject, `
    Format-CACSafe, `
    New-CACSafeMemberRowWithPermissions, `
    New-CACSafeUserRow
