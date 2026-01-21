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
        [string]$Status = ""
    )

    return [PSCustomObject]@{
        Id           = $Id
        UserName     = $UserName
        FullName     = $FullName
        Email        = $Email
        Phone        = $Phone
        Mobile       = $Mobile
        Department   = $Department
        Title        = $Title
        Organization = $Organization
        Source       = $Source
        UserType     = $UserType
        Status       = $Status
    }
}

# ============================================================
# Safe Object Model
# ============================================================
function Format-CACSafe {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Safe
    )

    return [PSCustomObject]@{
        SafeName                  = $Safe.safeName
        SafeUrlId                 = $Safe.safeUrlId
        SafeNumber                = $Safe.safeNumber
        Description               = $Safe.description
        Location                  = $Safe.location
        ManagingCPM               = $Safe.managingCPM
        OlacEnabled               = $Safe.olacEnabled
        CreatorId                 = $Safe.creator.id
        CreatorName               = $Safe.creator.name
        NumberOfVersionsRetention = $Safe.numberOfVersionsRetention
        NumberOfDaysRetention     = $Safe.numberOfDaysRetention
        AutoPurgeEnabled          = $Safe.autoPurgeEnabled
        CreationTime              = Convert-CACTimestamp $Safe.creationTime
        LastModificationTime      = Convert-CACTimestamp $Safe.lastModificationTime
    }
}

# ============================================================
# Safe Member Row (with Permissions)
# ============================================================
function New-CACSafeMemberRow {
    param(
        [string]$SafeName,
        [object]$Member
    )

    $perms = $Member.permissions

    return [PSCustomObject]@{
        SafeName                               = $SafeName
        MemberName                             = $Member.memberName
        MemberType                             = $Member.memberType
        MembershipExpirationDate               = $Member.membershipExpirationDate
        UseAccounts                            = if ($perms.useAccounts) { "Yes" } else { "No" }
        RetrieveAccounts                       = if ($perms.retrieveAccounts) { "Yes" } else { "No" }
        ListAccounts                           = if ($perms.listAccounts) { "Yes" } else { "No" }
        AddAccounts                            = if ($perms.addAccounts) { "Yes" } else { "No" }
        UpdateAccountContent                   = if ($perms.updateAccountContent) { "Yes" } else { "No" }
        UpdateAccountProperties                = if ($perms.updateAccountProperties) { "Yes" } else { "No" }
        InitiateCPMAccountManagementOperations = if ($perms.initiateCPMAccountManagementOperations) { "Yes" } else { "No" }
        SpecifyNextAccountContent              = if ($perms.specifyNextAccountContent) { "Yes" } else { "No" }
        RenameAccounts                         = if ($perms.renameAccounts) { "Yes" } else { "No" }
        DeleteAccounts                         = if ($perms.deleteAccounts) { "Yes" } else { "No" }
        UnlockAccounts                         = if ($perms.unlockAccounts) { "Yes" } else { "No" }
        ManageSafe                             = if ($perms.manageSafe) { "Yes" } else { "No" }
        ManageSafeMembers                      = if ($perms.manageSafeMembers) { "Yes" } else { "No" }
        BackupSafe                             = if ($perms.backupSafe) { "Yes" } else { "No" }
        ViewAuditLog                           = if ($perms.viewAuditLog) { "Yes" } else { "No" }
        ViewSafeMembers                        = if ($perms.viewSafeMembers) { "Yes" } else { "No" }
        AccessWithoutConfirmation              = if ($perms.accessWithoutConfirmation) { "Yes" } else { "No" }
        CreateFolders                          = if ($perms.createFolders) { "Yes" } else { "No" }
        DeleteFolders                          = if ($perms.deleteFolders) { "Yes" } else { "No" }
        MoveAccountsAndFolders                 = if ($perms.moveAccountsAndFolders) { "Yes" } else { "No" }
        RequestsAuthorizationLevel1            = if ($perms.requestsAuthorizationLevel1) { "Yes" } else { "No" }
        RequestsAuthorizationLevel2            = if ($perms.requestsAuthorizationLevel2) { "Yes" } else { "No" }
    }
}

# ============================================================
# Safe User Row (for expanded user details)
# ============================================================
function New-CACSafeUserRow {
    param(
        [string]$SafeName,
        [string]$SafeMember,
        [object]$UserObj
    )

    return [PSCustomObject]@{
        SafeName   = $SafeName
        SafeMember = $SafeMember
        UserName   = $UserObj.UserName
        FullName   = $UserObj.FullName
        Title      = $UserObj.Title
        Department = $UserObj.Department
        Email      = $UserObj.Email
    }
}

# ============================================================
# Group Object Model
# ============================================================
function New-CACGroupObject {
    param(
        [string]$Id = "",
        [string]$GroupName = "",
        [string]$Description = "",
        [string]$GroupType = "",
        [string]$Directory = "",
        [int]$MemberCount = 0
    )

    return [PSCustomObject]@{
        Id          = $Id
        GroupName   = $GroupName
        Description = $Description
        GroupType   = $GroupType
        Directory   = $Directory
        MemberCount = $MemberCount
    }
}

# ============================================================
# Account Object Model
# ============================================================
function New-CACAccountObject {
    param(
        [string]$Id = "",
        [string]$Name = "",
        [string]$Address = "",
        [string]$UserName = "",
        [string]$SafeName = "",
        [string]$PlatformId = "",
        [string]$SecretType = "",
        [object]$PlatformAccountProperties = $null
    )

    return [PSCustomObject]@{
        Id                        = $Id
        Name                      = $Name
        Address                   = $Address
        UserName                  = $UserName
        SafeName                  = $SafeName
        PlatformId                = $PlatformId
        SecretType                = $SecretType
        PlatformAccountProperties = $PlatformAccountProperties
    }
}

# ============================================================
# Result Row (for batch operations)
# ============================================================
function New-CACResultRow {
    param(
        [string]$ItemName = "",
        [string]$ItemType = "",
        [string]$Action = "",
        [string]$Status = "",
        [string]$Message = ""
    )

    return [PSCustomObject]@{
        ItemName  = $ItemName
        ItemType  = $ItemType
        Action    = $Action
        Status    = $Status
        Message   = $Message
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

# ============================================================
# EXPORT ALL MODEL FUNCTIONS
# ============================================================
Export-ModuleMember -Function `
    New-CACUserObject, `
    Format-CACSafe, `
    New-CACSafeMemberRow, `
    New-CACSafeUserRow, `
    New-CACGroupObject, `
    New-CACAccountObject, `
    New-CACResultRow
