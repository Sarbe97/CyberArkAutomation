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
function Set-CACSafe {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Safe
    )

    Write-Log "Formatting safe object: $($Safe.safeName)" "DEBUG"

    return [PSCustomObject]@{
        # Safe Identification
        SafeName                  = $Safe.safeName
        SafeUrlId                 = $Safe.safeUrlId
        SafeNumber                = $Safe.safeNumber
        
        # Safe Details
        Description               = $Safe.description
        Location                  = $Safe.location
        ManagingCPM               = $Safe.managingCPM
        OlacEnabled               = $Safe.olacEnabled
        
        # Creator Information
        CreatorId                 = $Safe.creator.id
        CreatorName               = $Safe.creator.name
        
        # Retention Policy
        NumberOfVersionsRetention = $Safe.numberOfVersionsRetention
        NumberOfDaysRetention     = $Safe.numberOfDaysRetention
        AutoPurgeEnabled          = $Safe.autoPurgeEnabled
        
        # Timestamps
        CreationTime              = Convert-CACTimestamp $Safe.creationTime
        LastModificationTime      = Convert-CACTimestamp $Safe.lastModificationTime
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
    Set-CACSafe, `
    New-CACSafeMemberRowWithPermissions, `
    New-CACSafeUserRow
