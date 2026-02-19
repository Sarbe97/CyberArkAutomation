# ============================================================================
# MODULE: Config.psm1
# DESCRIPTION: Configuration management for CyberArk CLI (Read-Only)
# NOTE: config.json should be edited manually - no programmatic writes
# ============================================================================

$Script:ConfigPath = "$PSScriptRoot/../config.json"

function Get-CACConfig {
    <#
    .SYNOPSIS
        Gets the full configuration from config.json.
    .DESCRIPTION
        Loads and returns all configuration values from config.json.
        Returns default values if config file is missing or corrupted.
    #>
    [CmdletBinding()]
    param()

    $defaults = @{
        PVWAURL            = ""
        UserCacheTTL       = 30
        LogLevel           = "INFO"
        SafePermissionSets = @{}
    }

    if (Test-Path $Script:ConfigPath) {
        try {
            $config = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
            
            # Return the full config object
            return $config
        }
        catch {
            Write-Log "Failed to load config: $($_.Exception.Message)" "WARN"
        }
    }
    else {
        Write-Log "Config file not found at: $Script:ConfigPath" "WARN"
    }

    # Return defaults if file missing or error
    return [PSCustomObject]$defaults
}

function Get-CACPermissionSet {
    <#
    .SYNOPSIS
        Gets a permission set by name from config.json.
    .PARAMETER SetName
        The name of the permission set (e.g., SAFE_READ, SAFE_READ_WRITE, VAULT_ADMIN).
    .OUTPUTS
        Hashtable of permissions with boolean values, or $null if not found.
    .EXAMPLE
        $perms = Get-CACPermissionSet -SetName "SAFE_READ"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SetName
    )

    $config = Get-CACConfig

    if ($null -eq $config.SafePermissionSets) {
        Write-Log "No SafePermissionSets found in config" "WARN"
        return $null
    }

    # Get the permission set by name
    $permissionList = $config.SafePermissionSets.$SetName

    if ($null -eq $permissionList) {
        Write-Log "Permission set '$SetName' not found in config" "WARN"
        return $null
    }

    # Convert the permission list (array of names) to a hashtable with boolean values
    # All permissions default to false, then set specified ones to true
    $allPermissions = @{
        useAccounts                            = $false
        retrieveAccounts                       = $false
        listAccounts                           = $false
        addAccounts                            = $false
        updateAccountContent                   = $false
        updateAccountProperties                = $false
        initiateCPMAccountManagementOperations = $false
        specifyNextAccountContent              = $false
        renameAccounts                         = $false
        deleteAccounts                         = $false
        unlockAccounts                         = $false
        manageSafe                             = $false
        manageSafeMembers                      = $false
        backupSafe                             = $false
        viewAuditLog                           = $false
        viewSafeMembers                        = $false
        accessWithoutConfirmation              = $false
        createFolders                          = $false
        deleteFolders                          = $false
        moveAccountsAndFolders                 = $false
    }

    # Set the specified permissions to true
    foreach ($perm in $permissionList) {
        # Convert PascalCase from config to camelCase for API
        $apiKey = $perm.Substring(0, 1).ToLower() + $perm.Substring(1)
        if ($allPermissions.ContainsKey($apiKey)) {
            $allPermissions[$apiKey] = $true
        }
        else {
            Write-Log "Unknown permission '$perm' in set '$SetName'" "WARN"
        }
    }

    return $allPermissions
}

function Get-CACAvailablePermissionSets {
    <#
    .SYNOPSIS
        Lists all available permission set names from config.json.
    .OUTPUTS
        Array of permission set names.
    #>
    [CmdletBinding()]
    param()

    $config = Get-CACConfig

    if ($null -eq $config.SafePermissionSets) {
        return @()
    }

    return @($config.SafePermissionSets.PSObject.Properties.Name)
}

function Get-CACGroupsToHide {
    <#
    .SYNOPSIS
        Gets the list of groups to hide from config.json.
    .DESCRIPTION
        Returns an array of group names that should be hidden/skipped when generating reports.
        These are common system groups that exist in most safes (e.g., Vault Admins, Auditors).
    .OUTPUTS
        Array of group names to hide.
    #>
    [CmdletBinding()]
    param()

    $config = Get-CACConfig

    if ($null -eq $config.GroupsToHide) {
        return @()
    }

    return @($config.GroupsToHide)
}

function Test-CACConfiguration {
    <#
    .SYNOPSIS
        Validates the configuration and environment.
    .OUTPUTS
        $true if configuration is valid, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    $isValid = $true
    $config = Get-CACConfig

    Write-Host "Validating configuration..." -ForegroundColor Cyan

    # 1. Check PVWA URL
    if ([string]::IsNullOrWhiteSpace($config.PVWAURL)) {
        Write-Host "[!] PVWAURL is missing in config.json." -ForegroundColor Red
        Write-Log "Config validation failed: PVWAURL missing" "ERROR"
        $isValid = $false
    }
    else {
        Write-Host " [OK] PVWA URL configured: $($config.PVWAURL)" -ForegroundColor Green
    }

    # 2. Check/Create Output Directory
    try {
        $outDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            Write-Host " [OK] Created Output directory" -ForegroundColor Green
            Write-Log "Created Output directory" "INFO"
        }
        else {
            Write-Host " [OK] Output directory exists" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "[!] Failed to create Output directory: $($_.Exception.Message)" -ForegroundColor Red
        $isValid = $false
    }

    # 3. Check LDAP Domain (Optional but recommended)
    if ([string]::IsNullOrWhiteSpace($config.LDAPDomain)) {
        Write-Host " [!] LDAPDomain is missing (LDAP login might fail)" -ForegroundColor Yellow
    }

    return $isValid
}

Export-ModuleMember -Function Get-CACConfig, Get-CACPermissionSet, Get-CACAvailablePermissionSets, Get-CACGroupsToHide, Test-CACConfiguration

