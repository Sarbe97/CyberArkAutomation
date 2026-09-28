# =============================================================================
# PSA_DataCollection.ps1
# Fetches CyberArk safes, members, accounts, and AD users for PersonalSafeAnalysis.
# =============================================================================

function Export-CsvNoBom {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)] [object] $InputObject,
        [Parameter(Mandatory=$true)] [string] $Path
    )
    begin   { $rows = [System.Collections.Generic.List[object]]::new() }
    process { $rows.Add($InputObject) }
    end {
        [string[]]$csvLines = if ($rows.Count -gt 0) { $rows | ConvertTo-Csv -NoTypeInformation } else { [string[]]::new(0) }
        if ($null -ne $csvLines) {
            [System.IO.File]::WriteAllLines($Path, $csvLines, [System.Text.UTF8Encoding]::new($false))
        } else {
            [System.IO.File]::WriteAllLines($Path, [string[]]::new(0), [System.Text.UTF8Encoding]::new($false))
        }
    }
}

# ---------------------------------------------------------------------------
# Get-PSAPersonalSafes
# Fetches ALL CyberArk safes, filters by the personal safe regex and exclusions,
# and returns matching personal safes.
# ---------------------------------------------------------------------------
function Get-PSAPersonalSafes {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $NamingPatternRegex,
        [Parameter(Mandatory=$true)] [PSCustomObject] $Exclusions,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading personal safes from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching ALL CyberArk safes to filter for personal safes..." -ScriptName $ScriptName -LogPath $LogPath

    $allSafes = [System.Collections.Generic.List[object]]::new()
    $offset    = 0
    $limit     = 500
    $hasMore   = $true

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Exclusions.InbuiltSafes) { foreach ($s in $Exclusions.InbuiltSafes) { [void]$excludeSet.Add($s) } }
    if ($Exclusions.ExceptionSafes) { foreach ($s in $Exclusions.ExceptionSafes) { [void]$excludeSet.Add($s) } }

    while ($hasMore) {
        Write-Progress -Id 40 -Activity "CyberArk Safes" -Status "Fetching safes at offset $offset..." -PercentComplete -1
        $uri   = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
        $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } elseif ($resp.Safes) { $resp.Safes } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($safe in $batch) {
                $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
                if (-not $safeName) { continue }
                
                # Check exclusions
                if ($excludeSet.Contains($safeName)) { continue }

                # Check pattern
                if ($safeName -match $NamingPatternRegex) {
                    $creationDate = ""
                    if ($null -ne $safe.creationTime) {
                        try {
                            $unixEpoch = [datetime]"1970-01-01T00:00:00Z"
                            $creationDate = $unixEpoch.AddSeconds([double]$safe.creationTime).ToLocalTime().ToString("yyyy-MM-dd")
                        } catch { $creationDate = $safe.creationTime }
                    }

                    $allSafes.Add([PSCustomObject]@{
                        SafeName     = $safeName
                        Description  = $safe.description
                        Creator      = if ($safe.creator -and $safe.creator.name) { $safe.creator.name } else { "" }
                        CreationTime = $creationDate
                        ManagingCPM  = if ($safe.managingCPM) { $safe.managingCPM } else { "" }
                    })
                }
            }
            Write-Log -Message "Safes fetched so far: $($offset + $batch.Count)..." -ScriptName $ScriptName -LogPath $LogPath
            if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
        }
        else { $hasMore = $false }
    }

    Write-Progress -Id 40 -Activity "CyberArk Safes" -Completed
    Write-Log -Message "Total personal safes matched: $($allSafes.Count)" -ScriptName $ScriptName -LogPath $LogPath

    $allSafes | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Personal safes cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath

    return $allSafes.ToArray()
}

# ---------------------------------------------------------------------------
# Get-PSASafeMembers
# Fetches all members for a specific safe.
# ---------------------------------------------------------------------------
function Get-PSASafeMembers {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $SafeName,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    $members = [System.Collections.Generic.List[object]]::new()
    
    $encodedSafeName = [System.Uri]::EscapeDataString($SafeName)
    $uri = "$BaseUrl/PasswordVault/api/Safes/$encodedSafeName/Members"
    
    try {
        $resp = Invoke-CyberArkApi -Uri $uri -TimeoutSec 60
        $memberList = if ($resp.value) { $resp.value } else { @() }

        foreach ($m in $memberList) {
            $members.Add([PSCustomObject]@{
                MemberName  = $m.memberName
                MemberType  = $m.memberType
                Permissions = if ($null -ne $m.permissions) { $m.permissions | ConvertTo-Json -Compress -Depth 5 } else { "{}" }
            })
        }
    }
    catch {
        Write-Log -Message "Failed to fetch members for safe '$SafeName': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $members.ToArray()
}

# ---------------------------------------------------------------------------
# Get-PSAAllAccounts
# Fetches all accounts from CyberArk in bulk.
# ---------------------------------------------------------------------------
function Get-PSAAllAccounts {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading all accounts from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching ALL CyberArk accounts in bulk..." -ScriptName $ScriptName -LogPath $LogPath

    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $offset    = 0
    $limit     = 1000
    $hasMore   = $true

    while ($hasMore) {
        Write-Progress -Id 50 -Activity "CyberArk Accounts" -Status "Fetching accounts at offset $offset (collected: $($allAccounts.Count))..." -PercentComplete -1
        $uri   = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset"
        $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($acct in $batch) {
                # We only need safeName for counting, but we can capture platform/name if needed
                $allAccounts.Add([PSCustomObject]@{
                    SafeName    = $acct.safeName
                    PlatformId  = $acct.platformId
                    AccountName = $acct.name
                })
            }
            Write-Log -Message "Accounts fetched so far: $($offset + $batch.Count)..." -ScriptName $ScriptName -LogPath $LogPath
            if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
        }
        else { $hasMore = $false }
    }

    Write-Progress -Id 50 -Activity "CyberArk Accounts" -Completed
    Write-Log -Message "Total accounts fetched: $($allAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    $allAccounts | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Accounts cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath

    return $allAccounts.ToArray()
}

# ---------------------------------------------------------------------------
# Get-PSAADUsers
# Queries the primary domain for primary accounts matching the pattern.
# Captures Enabled, Mail, GivenName, Surname.
# ---------------------------------------------------------------------------
function Get-PSAADUsers {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [string] $Pattern,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]   $ManualLogin
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading AD users from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    $primaryDomain = $Domains | Where-Object { $_.IsPrimary -eq $true } | Select-Object -First 1
    if (-not $primaryDomain) {
        Write-Log -Message "No primary domain found in config. Skipping AD query." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return @()
    }

    Write-Log -Message "Querying primary AD domain '$($primaryDomain.Name)' for users..." -ScriptName $ScriptName -LogPath $LogPath

    $adFilter = "*"
    if ($Pattern -match '^\^([A-Za-z0-9\-]+)') {
        $prefix = $Matches[1]
        $adFilter = "SamAccountName -like '$prefix*'"
    }
    Write-Log -Message "AD query built with filter: $adFilter" -ScriptName $ScriptName -LogPath $LogPath

    $credentialObj = $null
    $hasDirectCredentials = (-not [string]::IsNullOrWhiteSpace($primaryDomain.Username)) -and
                            (-not [string]::IsNullOrWhiteSpace($primaryDomain.Password))

    if ($hasDirectCredentials) {
        $secPass = ConvertTo-SecureString $primaryDomain.Password -AsPlainText -Force
        $credentialObj = New-Object System.Management.Automation.PSCredential($primaryDomain.Username, $secPass)
    } elseif ($primaryDomain.CCP) {
        try {
            $domainCCP = [PSCustomObject]@{
                Url    = $GlobalCCPUrl
                AppId  = $primaryDomain.CCP.AppId
                Safe   = $primaryDomain.CCP.Safe
                Object = $primaryDomain.CCP.Object
            }
            $creds = Get-SchedulerCredential -CCPConfig $domainCCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
            $secPass = ConvertTo-SecureString $creds.Password -AsPlainText -Force
            $credentialObj = New-Object System.Management.Automation.PSCredential($creds.Username, $secPass)
        }
        catch {
            Write-Log -Message "Failed to fetch CCP credentials for AD: $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    $adParams = @{
        Filter      = $adFilter
        Server      = $primaryDomain.Server
        Properties  = @("SamAccountName", "Enabled", "Mail", "GivenName", "Surname")
        ErrorAction = "Stop"
    }
    if ($null -ne $credentialObj) {
        $adParams["Credential"] = $credentialObj
    }

    $result = [System.Collections.Generic.List[object]]::new()
    try {
        Write-Progress -Id 10 -Activity "AD Query" -Status "Querying '$($primaryDomain.Server)'..." -PercentComplete -1
        
        Write-Log -Message "Executing Get-ADUser query against $($primaryDomain.Server)..." -ScriptName $ScriptName -LogPath $LogPath
        $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, Enabled, Mail, GivenName, Surname)
        Write-Log -Message "Get-ADUser returned $($adUsers.Count) users before applying regex pattern." -ScriptName $ScriptName -LogPath $LogPath
        
        foreach ($user in $adUsers) {
            if ($user.SamAccountName -notmatch $Pattern) { continue }
            
            $result.Add([PSCustomObject]@{
                Username  = $user.SamAccountName
                Enabled   = $user.Enabled
                Mail      = if ($user.Mail) { $user.Mail } else { "" }
                GivenName = if ($user.GivenName) { $user.GivenName } else { "" }
                Surname   = if ($user.Surname) { $user.Surname } else { "" }
            })
        }

        Write-Progress -Id 10 -Activity "AD Query" -Completed
        Write-Log -Message "Found $($result.Count) AD users matching regex pattern exactly." -ScriptName $ScriptName -LogPath $LogPath
        
        if ($result.Count -gt 0) {
            $result | Export-CsvNoBom -Path $CachePath
            Write-Log -Message "Exported valid AD users to cache file: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        } else {
            Write-Log -Message "0 users matched the regex pattern. Skipping CSV export." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    catch {
        Write-Progress -Id 10 -Activity "AD Query" -Completed
        Write-Log -Message "Error querying AD domain '$($primaryDomain.Name)': $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Get-PSAADGroupMemberSet
# Queries the primary domain for members of the designated Active Directory group.
# Caches results to RawCache_GroupMembers_<TodayStr>.csv and returns a HashSet.
# ---------------------------------------------------------------------------
function Get-PSAADGroupMemberSet {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [string] $GroupName,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]   $ManualLogin
    )

    $memberSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading group members for '$GroupName' from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        $cached = Import-Csv $CachePath
        foreach ($row in $cached) {
            if ($row.Username) {
                [void]$memberSet.Add($row.Username.ToUpper())
            }
        }
        Write-Log -Message "Group '$GroupName' loaded from cache: $($memberSet.Count) members." -ScriptName $ScriptName -LogPath $LogPath
        return $memberSet
    }

    $primaryDomain = $Domains | Where-Object { $_.IsPrimary -eq $true } | Select-Object -First 1
    if (-not $primaryDomain) {
        Write-Log -Message "No primary domain found. Cannot check AD group '$GroupName'." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return $memberSet
    }

    Write-Log -Message "Fetching members of AD group '$GroupName' from primary domain '$($primaryDomain.Name)'..." -ScriptName $ScriptName -LogPath $LogPath

    $credentialObj = $null
    $hasDirectCredentials = (-not [string]::IsNullOrWhiteSpace($primaryDomain.Username)) -and
                            (-not [string]::IsNullOrWhiteSpace($primaryDomain.Password))

    if ($hasDirectCredentials) {
        $secPass = ConvertTo-SecureString $primaryDomain.Password -AsPlainText -Force
        $credentialObj = New-Object System.Management.Automation.PSCredential($primaryDomain.Username, $secPass)
    } elseif ($primaryDomain.CCP) {
        try {
            $domainCCP = [PSCustomObject]@{
                Url    = $GlobalCCPUrl
                AppId  = $primaryDomain.CCP.AppId
                Safe   = $primaryDomain.CCP.Safe
                Object = $primaryDomain.CCP.Object
            }
            $creds = Get-SchedulerCredential -CCPConfig $domainCCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
            $secPass = ConvertTo-SecureString $creds.Password -AsPlainText -Force
            $credentialObj = New-Object System.Management.Automation.PSCredential($creds.Username, $secPass)
        }
        catch {
            Write-Log -Message "Failed to fetch CCP credentials for AD group lookup: $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    $adParams = @{
        Identity    = $GroupName
        Server      = $primaryDomain.Server
        Recursive   = $true
        ErrorAction = "Stop"
    }
    if ($null -ne $credentialObj) {
        $adParams["Credential"] = $credentialObj
    }

    $exportRows = [System.Collections.Generic.List[object]]::new()
    try {
        Write-Progress -Id 60 -Activity "AD Group Members" -Status "Querying AD server '$($primaryDomain.Server)' for group '$GroupName'..." -PercentComplete -1
        $members = Get-ADGroupMember @adParams
        foreach ($m in $members) {
            if ($m.objectClass -eq "user" -or -not [string]::IsNullOrWhiteSpace($m.SamAccountName)) {
                $uUpper = $m.SamAccountName.ToUpper()
                [void]$memberSet.Add($uUpper)
                $exportRows.Add([PSCustomObject]@{
                    Username          = $m.SamAccountName
                    Name              = $m.Name
                    DistinguishedName = $m.DistinguishedName
                })
            }
        }
        Write-Progress -Id 60 -Activity "AD Group Members" -Completed
        Write-Log -Message "AD Group '$GroupName' has $($memberSet.Count) user members." -ScriptName $ScriptName -LogPath $LogPath

        if ($exportRows.Count -gt 0) {
            $exportRows | Export-CsvNoBom -Path $CachePath
            Write-Log -Message "Group members cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    catch {
        Write-Progress -Id 60 -Activity "AD Group Members" -Completed
        Write-Log -Message "Failed to retrieve AD group '$GroupName': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $memberSet
}

# ---------------------------------------------------------------------------
# Add-PSASafeMember
# Adds a member (User/Group) to a CyberArk Safe with specified permissions.
# Uses searchIn to specify the LDAP domain directory mapping for first-time users.
# Returns: hashtable { Success, AlreadyExisted, Error }
# ---------------------------------------------------------------------------
function Add-PSASafeMember {
    param (
        [Parameter(Mandatory=$true)] [string]   $BaseUrl,
        [Parameter(Mandatory=$true)] [string]   $SafeName,
        [Parameter(Mandatory=$true)] [string]   $MemberName,
        [Parameter(Mandatory=$true)] [string]   $MemberType,
        [Parameter(Mandatory=$true)] [array]    $Permissions,
        [string] $SearchIn = "",
        [Parameter(Mandatory=$true)] [string]   $ScriptName,
        [Parameter(Mandatory=$true)] [string]   $LogPath
    )

    Write-Log -Message "Adding member '$MemberName' ($MemberType) to safe '$SafeName' (searchIn: '$SearchIn')..." -ScriptName $ScriptName -LogPath $LogPath

    try {
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

        $encodedSafe = [System.Uri]::EscapeDataString($SafeName)
        $uri = "$BaseUrl/PasswordVault/api/Safes/$encodedSafe/Members"
        $null = Invoke-CyberArkApi -Uri $uri -Method Post -Body $body

        Write-Log -Message "Member '$MemberName' added to safe '$SafeName' successfully." -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $true; AlreadyExisted = $false; Error = "" }
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "409|already a member|already exist|conflict") {
            Write-Log -Message "Member '$MemberName' already exists in safe '$SafeName'. Treating as success." -ScriptName $ScriptName -LogPath $LogPath
            return @{ Success = $true; AlreadyExisted = $true; Error = "" }
        }
        Write-Log -Message "Failed to add member '$MemberName' to safe '$SafeName': $errMsg" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return @{ Success = $false; AlreadyExisted = $false; Error = $errMsg }
    }
}

