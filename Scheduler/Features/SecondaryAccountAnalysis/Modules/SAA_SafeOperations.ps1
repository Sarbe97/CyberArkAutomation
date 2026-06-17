# =============================================================================
# SAA_SafeOperations.ps1
# All CyberArk write operations for SecondaryAccountAnalysis.
# Every write function respects SimulationMode - when true it logs the
# intended action and returns without touching CyberArk.
#
# Exposes:
#   Resolve-SAAToken             - Token substitution in strings/safe names
#   New-SAASafe                  - Create a personal safe
#   Add-SAASafeMember            - Add a member with a config-defined permission set
#   Invoke-SAAAccountOnboard     - Onboard a secondary account into a safe
#   Invoke-SAASafeProvisioning   - Orchestrate full safe + member setup for one user
# =============================================================================

# ---------------------------------------------------------------------------
# Resolve-SAAToken
# Replaces {Token} placeholders in a string with values from a hashtable.
# Supports: {PrimaryAccount}, {SecondaryAccount}, {EmployeeNumber},
#           {SafeName}, {Domain}, {Status}, {ErrorMessage}, {GeneratedDate}
# ---------------------------------------------------------------------------
function Resolve-SAAToken {
    param (
        [Parameter(Mandatory=$true)] [string]    $Template,
        [Parameter(Mandatory=$true)] [hashtable] $Tokens
    )

    $result = $Template
    foreach ($key in $Tokens.Keys) {
        $result = $result -replace [regex]::Escape("{$key}"), [string]$Tokens[$key]
    }
    return $result
}

# ---------------------------------------------------------------------------
# New-SAASafe
# Creates a personal safe in CyberArk using settings from the config.
# SimulationMode: logs the intended action, returns success without API call.
# Returns: hashtable { Success, Simulated, AlreadyExisted, SafeName, Error }
# ---------------------------------------------------------------------------
function New-SAASafe {
    param (
        [Parameter(Mandatory=$true)] [string]         $SafeName,
        [Parameter(Mandatory=$true)] [PSCustomObject] $SafeConfig,
        [Parameter(Mandatory=$true)] [string]         $BaseUrl,
        [Parameter(Mandatory=$true)] [string]         $ScriptName,
        [Parameter(Mandatory=$true)] [string]         $LogPath,
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would create safe: '$SafeName' (CPM: $($SafeConfig.ManagingCPM), Retention: $($SafeConfig.NumberOfDaysRetention) days)" `
            -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $true; AlreadyExisted = $false; SafeName = $SafeName }
    }

    Write-Log -Message "Creating safe: '$SafeName'..." -ScriptName $ScriptName -LogPath $LogPath

    try {
        $body = @{
            safeName                  = $SafeName
            description               = "Personal safe - managed by SecondaryAccountAnalysis"
            managingCPM               = $SafeConfig.ManagingCPM
        }

        if ([int]$SafeConfig.NumberOfDaysRetention -gt 0) {
            $body.numberOfDaysRetention = [int]$SafeConfig.NumberOfDaysRetention
        }

        $uri  = "$BaseUrl/PasswordVault/api/Safes"
        $resp = Invoke-CyberArkApi -Uri $uri -Method Post -Body $body

        Write-Log -Message "Safe '$SafeName' created successfully." -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $false; AlreadyExisted = $false; SafeName = $SafeName; Response = $resp }
    }
    catch {
        $errMsg = $_.Exception.Message
        # HTTP 409 = safe already exists - treat as non-fatal, continue to member provisioning
        if ($errMsg -match "409|already exists|already exist|conflict") {
            Write-Log -Message "Safe '$SafeName' already exists. Skipping creation." -ScriptName $ScriptName -LogPath $LogPath
            return @{ Success = $true; Simulated = $false; AlreadyExisted = $true; SafeName = $SafeName }
        }
        Write-Log -Message "Failed to create safe '$SafeName': $errMsg" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $false; Simulated = $false; AlreadyExisted = $false; SafeName = $SafeName; Error = $errMsg }
    }
}

# ---------------------------------------------------------------------------
# Add-SAASafeMember
# Adds a single member to a safe with a permission set defined in config.
# The Permissions array maps directly to CyberArk's boolean permission fields.
# SimulationMode: logs the intended action only.
# Returns: hashtable { Success, Simulated, AlreadyExisted, Error }
# ---------------------------------------------------------------------------
function Add-SAASafeMember {
    param (
        [Parameter(Mandatory=$true)] [string]   $SafeName,
        [Parameter(Mandatory=$true)] [string]   $MemberName,
        [Parameter(Mandatory=$true)] [string]   $MemberType,
        [Parameter(Mandatory=$true)] [array]    $Permissions,
        [Parameter(Mandatory=$true)] [string]   $BaseUrl,
        [Parameter(Mandatory=$true)] [string]   $ScriptName,
        [Parameter(Mandatory=$true)] [string]   $LogPath,
        [string] $SearchIn = "",
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        $simMsg = "[SIMULATION] Would add member '$MemberName' ($MemberType) to safe '$SafeName' - permissions: $($Permissions -join ', ')"
        if (-not [string]::IsNullOrWhiteSpace($SearchIn) -and $SearchIn -ne "Vault") {
            $simMsg += " (searchIn: $SearchIn)"
        }
        Write-Log -Message $simMsg -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $true; AlreadyExisted = $false }
    }

    Write-Log -Message "Adding member '$MemberName' ($MemberType) to safe '$SafeName'..." -ScriptName $ScriptName -LogPath $LogPath

    try {
        # CyberArk REST API expects individual boolean permission properties
        $permsBody = @{
            useAccounts                            = ($Permissions -contains "UseAccounts")
            retrieveAccounts                       = ($Permissions -contains "RetrieveAccounts")
            listAccounts                           = ($Permissions -contains "ListAccounts")
            addAccounts                            = ($Permissions -contains "AddAccounts")
            updateAccountContent                   = ($Permissions -contains "UpdateAccountContent")
            updateAccountProperties                = ($Permissions -contains "UpdateAccountProperties")
            initiateCPMAccountManagementOperations = ($Permissions -contains "InitiateCPMAccountManagementOperations")
            specifyNextAccountContent              = ($Permissions -contains "SpecifyNextAccountContent")
            renameAccounts                         = ($Permissions -contains "RenameAccounts")
            deleteAccounts                         = ($Permissions -contains "DeleteAccounts")
            unlockAccounts                         = ($Permissions -contains "UnlockAccounts")
            manageSafe                             = ($Permissions -contains "ManageSafe")
            manageSafeMembers                      = ($Permissions -contains "ManageSafeMembers")
            backupSafe                             = ($Permissions -contains "BackupSafe")
            viewAuditLog                           = ($Permissions -contains "ViewAuditLog")
            viewSafeMembers                        = ($Permissions -contains "ViewSafeMembers")
            accessWithoutConfirmation              = ($Permissions -contains "AccessWithoutConfirmation")
            createFolders                          = ($Permissions -contains "CreateFolders")
            deleteFolders                          = ($Permissions -contains "DeleteFolders")
            moveAccountsAndFolders                 = ($Permissions -contains "MoveAccountsAndFolders")
        }

        $body = @{
            memberName  = $MemberName
            memberType  = $MemberType
            permissions = $permsBody
        }

        if (-not [string]::IsNullOrWhiteSpace($SearchIn) -and $SearchIn -ne "Vault") {
            $body["searchIn"] = $SearchIn
        }

        $encodedSafe = [uri]::EscapeDataString($SafeName)
        $uri  = "$BaseUrl/PasswordVault/api/Safes/$encodedSafe/Members"
        $resp = Invoke-CyberArkApi -Uri $uri -Method Post -Body $body

        Write-Log -Message "Member '$MemberName' added to '$SafeName' successfully." -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $false; AlreadyExisted = $false }
    }
    catch {
        $errMsg = $_.Exception.Message
        # HTTP 409 = already a member - non-fatal
        if ($errMsg -match "409|already a member|already exist|conflict") {
            Write-Log -Message "Member '$MemberName' already exists in '$SafeName'. Skipping." -ScriptName $ScriptName -LogPath $LogPath
            return @{ Success = $true; Simulated = $false; AlreadyExisted = $true }
        }
        # HTTP 403 = usually "You cannot update your own account" when API user tries to add themselves. 
        # Safe creators automatically get full permissions, so this is non-fatal.
        if ($errMsg -match "403|Forbidden|cannot update your own account") {
            Write-Log -Message "Member '$MemberName' returned Forbidden (403). If this is the API user, it already has full permissions. Skipping." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            return @{ Success = $true; Simulated = $false; AlreadyExisted = $true }
        }
        Write-Log -Message "Failed to add member '$MemberName' to '$SafeName': $errMsg" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $false; Simulated = $false; AlreadyExisted = $false; Error = $errMsg }
    }
}

# ---------------------------------------------------------------------------
# Invoke-SAAAccountOnboard
# Onboards a secondary account into a personal safe.
# SimulationMode: logs the intended action only.
# Returns: hashtable { Success, Simulated, AccountId, Error }
# ---------------------------------------------------------------------------
function Invoke-SAAAccountOnboard {
    param (
        [Parameter(Mandatory=$true)] [string] $Username,
        [Parameter(Mandatory=$true)] [string] $Address,
        [Parameter(Mandatory=$true)] [string] $SafeName,
        [Parameter(Mandatory=$true)] [string] $PlatformId,
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [bool] $SimulationMode = $false
    )

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would onboard account '$Username' @ '$Address' → safe '$SafeName' (platform: $PlatformId)" `
            -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $true }
    }

    Write-Log -Message "Onboarding account '$Username' @ '$Address' into safe '$SafeName' (platform: $PlatformId)..." -ScriptName $ScriptName -LogPath $LogPath

    try {
        $body = @{
            name       = "$Username-$Address"
            address    = $Address
            userName   = $Username
            platformId = $PlatformId
            safeName   = $SafeName
            secretType = "password"
            secret     = ""
        }

        $uri = "$BaseUrl/PasswordVault/api/Accounts"

        # Log full request details to aid in diagnosing onboarding failures
        $bodyJson = $body | ConvertTo-Json -Compress
        Write-Log -Message "POST $uri" -ScriptName $ScriptName -LogPath $LogPath
        Write-Log -Message "Request body: $bodyJson" -ScriptName $ScriptName -LogPath $LogPath

        $resp = Invoke-CyberArkApi -Uri $uri -Method Post -Body $body

        Write-Log -Message "Account '$Username' onboarded successfully into '$SafeName' (AccountId: $($resp.id), Platform: $PlatformId)." -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; Simulated = $false; AccountId = $resp.id }
    }
    catch {
        $errMsg       = $_.Exception.Message
        $errCategory  = $_.CategoryInfo.Category
        $innerMsg     = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "none" }
        Write-Log -Message "Failed to onboard '$Username' into '$SafeName'." -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        Write-Log -Message "  Error    : $errMsg" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        Write-Log -Message "  Category : $errCategory" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        Write-Log -Message "  Inner    : $innerMsg" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $false; Simulated = $false; Error = $errMsg }
    }
}

# ---------------------------------------------------------------------------
# Invoke-SAASafeProvisioning
# Orchestrates complete safe setup for one user:
#   1. Resolves the safe name using tokens
#   2. Creates the safe (skips if already exists)
#   3. Adds all configured members with token-resolved names and config permissions
# Returns: hashtable { SafeName, SafeCreated, MembersAdded, Errors[] }
# ---------------------------------------------------------------------------
function Invoke-SAASafeProvisioning {
    param (
        [Parameter(Mandatory=$true)] [hashtable]      $Tokens,
        [Parameter(Mandatory=$true)] [PSCustomObject]  $PersonalSafeConfig,
        [Parameter(Mandatory=$true)] [hashtable]       $SafePermissionSets,
        [Parameter(Mandatory=$true)] [string]          $BaseUrl,
        [Parameter(Mandatory=$true)] [string]          $ScriptName,
        [Parameter(Mandatory=$true)] [string]          $LogPath,
        [string] $LDAPDomain = "",
        [string] $CurrentUsername = "",
        [bool] $SimulationMode = $false
    )

    $safeName = Resolve-SAAToken -Template $PersonalSafeConfig.NamingPattern -Tokens $Tokens
    $Tokens["SafeName"] = $safeName

    $result = @{
        SafeName     = $safeName
        SafeCreated  = $false
        MembersAdded = 0
        Errors       = [System.Collections.Generic.List[string]]::new()
    }

    # Step 1: Create the safe
    $safeResult = New-SAASafe -SafeName $safeName -SafeConfig $PersonalSafeConfig `
        -BaseUrl $BaseUrl -ScriptName $ScriptName -LogPath $LogPath -SimulationMode $SimulationMode

    if (-not $safeResult.Success) {
        $result.Errors.Add("SafeCreation: $($safeResult.Error)")
        return $result
    }
    $result.SafeCreated = $true

    # Step 2: Add each configured member
    foreach ($member in $PersonalSafeConfig.Members) {
        $resolvedName = Resolve-SAAToken -Template $member.Name -Tokens $Tokens

        if ($CurrentUsername -and ($resolvedName -eq $CurrentUsername)) {
            Write-Log -Message "Skipping member '$resolvedName' because it is the currently logged-in API user (the safe creator is automatically added with full permissions)." -ScriptName $ScriptName -LogPath $LogPath
            continue
        }

        $permSet = $SafePermissionSets[$member.PermissionSet]
        if (-not $permSet) {
            Write-Log -Message "Permission set '$($member.PermissionSet)' not found in config. Skipping member '$resolvedName'." `
                -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            continue
        }

        $searchIn = ""
        if ($member.PSObject.Properties['MemberSource']) {
            if ($member.MemberSource -eq "Domain") {
                $searchIn = $LDAPDomain
            } elseif ($member.MemberSource -ne "Vault") {
                $searchIn = $member.MemberSource
            }
        }

        $memberResult = Add-SAASafeMember -SafeName $safeName -MemberName $resolvedName `
            -MemberType $member.Type -Permissions $permSet -SearchIn $searchIn `
            -BaseUrl $BaseUrl -ScriptName $ScriptName -LogPath $LogPath -SimulationMode $SimulationMode

        if ($memberResult.Success) {
            $result.MembersAdded++
        }
        else {
            $result.Errors.Add("AddMember[$resolvedName]: $($memberResult.Error)")
        }
    }

    return $result
}
