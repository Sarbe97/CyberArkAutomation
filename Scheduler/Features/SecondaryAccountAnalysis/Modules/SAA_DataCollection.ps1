# =============================================================================
# SAA_DataCollection.ps1
# Fetches and caches all raw data needed by SecondaryAccountAnalysis.
#
# Caching behaviour (matches DR_DataCollection.ps1 pattern):
#   - If today's cache CSV exists for that entity → load it, skip live query.
#   - Otherwise query the source (AD or CyberArk API) and save to cache.
#   - Per-domain caching for AD: each domain gets its own dated file.
#
# Exposes:
#   Get-SAAPrimaryADUsers       - Primary domain AD users (U-prefix) with mail attribute
#   Get-SAASecondaryADAccounts  - All domains, secondary prefix accounts, with mail attribute
#   Get-SAACyberArkUsers        - CyberArk LDAP EPVUsers (for access verification)
#   Get-SAAPersonalSafes        - CyberArk safes matching the naming pattern regex
#   Get-SAAOnboardedAccounts    - CyberArk accounts inside personal safes
#   Get-SAAGroupMemberSet       - HashSet of usernames in a CyberArk group
# =============================================================================


# ---------------------------------------------------------------------------
# Export-CsvNoBom  (private helper)
# PowerShell 5.1's Export-Csv -Encoding UTF8 writes a BOM (EF BB BF) at the
# start of every file. Excel reads those bytes as garbage characters in A1.
# This helper uses [System.IO.File]::WriteAllLines with an explicit no-BOM
# UTF-8 encoder to produce clean files that Excel opens without any prefix.
# ---------------------------------------------------------------------------
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
# Get-SAAPrimaryADUsers
# Queries the primary domain (IsPrimary=true) for users matching the
# primary account pattern. Captures the mail attribute for user notifications.
# Cache file: RawCache_PrimaryADUsers_<TodayStr>.csv
# ---------------------------------------------------------------------------
function Get-SAAPrimaryADUsers {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [string] $PrimaryPattern,
        [Parameter(Mandatory=$true)] [string] $EmpNbrCapture,
        [Parameter(Mandatory=$true)] [string] $CacheDir,
        [Parameter(Mandatory=$true)] [string] $TodayStr,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]   $ManualLogin
    )

    $CachePath = Join-Path $CacheDir "RawCache_PrimaryADUsers_$TodayStr.csv"

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading primary AD users from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    $primaryDomain = $Domains | Where-Object { $_.IsPrimary -eq $true } | Select-Object -First 1
    if (-not $primaryDomain) {
        Write-Log -Message "No primary domain (IsPrimary=true) found in config. Skipping primary user collection." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        return @()
    }

    Write-Log -Message "Querying primary domain '$($primaryDomain.Name)' ($($primaryDomain.FQDN)) for primary accounts..." -ScriptName $ScriptName -LogPath $LogPath

    $result = [System.Collections.Generic.List[object]]::new()

    # Construct optimized AD filter
    $adFilter = "*"
    if ($PrimaryPattern -match '^\^([A-Za-z0-9\-]+)') {
        $prefix = $Matches[1]
        $adFilter = "SamAccountName -like '$prefix*'"
    }

    # Fetch domain-specific credentials
    # Direct credentials are used ONLY when both Username AND Password are non-blank.
    # If either is empty, fall through to CCP.
    $credentialObj = $null
    $hasDirectCredentials = (-not [string]::IsNullOrWhiteSpace($primaryDomain.Username)) -and
                            (-not [string]::IsNullOrWhiteSpace($primaryDomain.Password))

    if ($hasDirectCredentials) {
        $secPass = ConvertTo-SecureString $primaryDomain.Password -AsPlainText -Force
        $credentialObj = New-Object System.Management.Automation.PSCredential($primaryDomain.Username, $secPass)
        Write-Log -Message "Using direct credentials for primary domain '$($primaryDomain.Name)' (Username: $($primaryDomain.Username))" -ScriptName $ScriptName -LogPath $LogPath
    } elseif ($primaryDomain.CCP) {
        Write-Log -Message "Retrieving credentials from CCP for primary domain '$($primaryDomain.Name)'..." -ScriptName $ScriptName -LogPath $LogPath
        try {
            $domainCCP = [PSCustomObject]@{
                Url    = $GlobalCCPUrl
                AppId  = $primaryDomain.CCP.AppId
                Safe   = $primaryDomain.CCP.Safe
                Object = $primaryDomain.CCP.Object
            }
            $creds = Get-SchedulerCredential -CCPConfig $domainCCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
            Write-Log -Message "Successfully retrieved credentials from CCP for primary domain '$($primaryDomain.Name)' (Username: $($creds.Username))." -ScriptName $ScriptName -LogPath $LogPath
            $secPass = ConvertTo-SecureString $creds.Password -AsPlainText -Force
            $credentialObj = New-Object System.Management.Automation.PSCredential($creds.Username, $secPass)
        }
        catch {
            Write-Log -Message "Failed to fetch CCP credentials for primary domain '$($primaryDomain.Name)': $($_.Exception.Message)" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
            return @()
        }
    } else {
        Write-Log -Message "No credentials configured for primary domain '$($primaryDomain.Name)'. Querying AD using current execution context." -ScriptName $ScriptName -LogPath $LogPath
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

    try {
        Write-Log -Message "Sending AD query to server '$($primaryDomain.Server)' using filter '$adFilter'..." -ScriptName $ScriptName -LogPath $LogPath
        Write-Progress -Id 10 -Activity "Primary Domain AD Query" -Status "Querying '$($primaryDomain.Server)'... (this may take a moment)" -PercentComplete -1
        $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, Enabled, Mail, GivenName, Surname)
        $rawCount = if ($adUsers) { $adUsers.Count } else { 0 }
        Write-Log -Message "AD query completed. Received $rawCount raw user records from server '$($primaryDomain.Server)'. Processing primary account pattern..." -ScriptName $ScriptName -LogPath $LogPath
        Write-Progress -Id 10 -Activity "Primary Domain AD Query" -Status "Processing $rawCount user records..." -PercentComplete -1

        foreach ($user in $adUsers) {
            if ($user.SamAccountName -notmatch $PrimaryPattern) { continue }

            $empNbr = if ($user.SamAccountName -match $EmpNbrCapture) { $Matches[1] } else { "" }

            $result.Add([PSCustomObject]@{
                Username    = $user.SamAccountName
                EmployeeNbr = $empNbr
                Domain      = $primaryDomain.Name
                DomainFQDN  = $primaryDomain.FQDN
                Enabled     = $user.Enabled
                Mail        = if ($user.Mail)     { $user.Mail }     else { "" }
                GivenName   = if ($user.GivenName) { $user.GivenName } else { "" }
                Surname     = if ($user.Surname)   { $user.Surname }   else { "" }
            })
        }

        Write-Progress -Id 10 -Activity "Primary Domain AD Query" -Completed
        Write-Log -Message "Found $($result.Count) primary accounts in '$($primaryDomain.Name)'" -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Progress -Id 10 -Activity "Primary Domain AD Query" -Completed
        Write-Log -Message "Error querying primary domain '$($primaryDomain.Name)': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    $result | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Primary AD users cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAASecondaryADAccounts
# Queries ALL configured domains for secondary accounts matching any of the
# configured prefixes. Captures the mail attribute.
# Cache file per domain: RawCache_ADAccounts_<DomainName>_<TodayStr>.csv
# ---------------------------------------------------------------------------
function Get-SAASecondaryADAccounts {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [array]  $Prefixes,
        [Parameter(Mandatory=$false)][string] $Pattern,
        [Parameter(Mandatory=$true)] [string] $EmpNbrCapture,
        [Parameter(Mandatory=$true)] [PSCustomObject] $Exclusions,
        [Parameter(Mandatory=$true)] [string] $CacheDir,
        [Parameter(Mandatory=$true)] [string] $TodayStr,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]   $ManualLogin
    )


    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $totalDomains = $Domains.Count
    $domainIndex = 0

    foreach ($domain in $Domains) {
        $domainIndex++
        $CachePath = Join-Path $CacheDir "RawCache_ADAccounts_$($domain.Name)_$TodayStr.csv"

        # Check if domain is excluded
        if ($Exclusions.Domains -and ($domain.Name -in $Exclusions.Domains)) {
            Write-Log -Message "[$domainIndex/$totalDomains] Domain '$($domain.Name)' is in the exclusion list. Skipping." -ScriptName $ScriptName -LogPath $LogPath
            continue
        }

        if (Test-Path $CachePath) {
            Write-Log -Message "[$domainIndex/$totalDomains] Loading AD accounts for '$($domain.Name)' from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
            $cached = @(Import-Csv $CachePath)
            foreach ($row in $cached) { $allAccounts.Add($row) }
            continue
        }

        Write-Progress -Id 20 -Activity "Secondary AD Accounts" -Status "[$domainIndex/$totalDomains] Querying domain: $($domain.Name)" -PercentComplete ([int](($domainIndex / $totalDomains) * 100))
        Write-Log -Message "[$domainIndex/$totalDomains] Querying domain '$($domain.Name)' ($($domain.FQDN)) for secondary accounts (prefixes: $($Prefixes -join ', '))..." -ScriptName $ScriptName -LogPath $LogPath

        # Direct credentials are used ONLY when both Username AND Password are non-blank.
        # If either is empty, fall through to CCP.
        $credentialObj = $null
        $hasDirectCredentials = (-not [string]::IsNullOrWhiteSpace($domain.Username)) -and
                                (-not [string]::IsNullOrWhiteSpace($domain.Password))

        if ($hasDirectCredentials) {
            $secPass = ConvertTo-SecureString $domain.Password -AsPlainText -Force
            $credentialObj = New-Object System.Management.Automation.PSCredential($domain.Username, $secPass)
            Write-Log -Message "[$domainIndex/$totalDomains] Using direct credentials for domain '$($domain.Name)' (Username: $($domain.Username))" -ScriptName $ScriptName -LogPath $LogPath
        } elseif ($domain.CCP) {
            Write-Log -Message "[$domainIndex/$totalDomains] Retrieving credentials from CCP for domain '$($domain.Name)'..." -ScriptName $ScriptName -LogPath $LogPath
            try {
                $domainCCP = [PSCustomObject]@{
                    Url    = $GlobalCCPUrl
                    AppId  = $domain.CCP.AppId
                    Safe   = $domain.CCP.Safe
                    Object = $domain.CCP.Object
                }
                $creds = Get-SchedulerCredential -CCPConfig $domainCCP -ManualLogin:$ManualLogin -ScriptName $ScriptName -LogPath $LogPath
                Write-Log -Message "[$domainIndex/$totalDomains] Successfully retrieved credentials from CCP for domain '$($domain.Name)' (Username: $($creds.Username))." -ScriptName $ScriptName -LogPath $LogPath
                $secPass = ConvertTo-SecureString $creds.Password -AsPlainText -Force
                $credentialObj = New-Object System.Management.Automation.PSCredential($creds.Username, $secPass)
            }
            catch {
                Write-Log -Message "[$domainIndex/$totalDomains] Failed to fetch CCP credentials for domain '$($domain.Name)': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
                # Skip domain if we can't retrieve credentials
                continue
            }
        } else {
            Write-Log -Message "[$domainIndex/$totalDomains] No credentials configured for domain '$($domain.Name)'. Querying AD using current execution context." -ScriptName $ScriptName -LogPath $LogPath
        }

        $domainResult = [System.Collections.Generic.List[object]]::new()

        try {
            $filterParts = @()
            foreach ($prefix in $Prefixes) {
                $filterParts += "SamAccountName -like '$prefix*'"
            }
            $adFilter = $filterParts -join " -or "
            if (-not $adFilter) { $adFilter = "*" }

            $adParams = @{
                Filter      = $adFilter
                Server      = $domain.Server
                Properties  = @("SamAccountName", "Enabled", "Mail")
                ErrorAction = "Stop"
            }
            if ($null -ne $credentialObj) {
                $adParams["Credential"] = $credentialObj
            }

            Write-Log -Message "[$domainIndex/$totalDomains] Sending AD query to server '$($domain.Server)' using filter '$adFilter'..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -ParentId 20 -Activity "AD Query" -Status "Querying '$($domain.Server)'... (this may take a moment)" -PercentComplete -1
            $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, Enabled, Mail)
            $rawCount = if ($adUsers) { $adUsers.Count } else { 0 }
            Write-Log -Message "[$domainIndex/$totalDomains] AD query completed. Received $rawCount raw user records from server '$($domain.Server)'. Processing secondary account prefixes..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -Activity "AD Query" -Status "Processing $rawCount records from '$($domain.Server)'..." -PercentComplete -1

            foreach ($user in $adUsers) {
                # Check exclusion by username pattern
                $shouldExclude = $false
                if ($Exclusions.UsernamePatterns) {
                    foreach ($pattern in $Exclusions.UsernamePatterns) {
                        if ($user.SamAccountName -match $pattern) { $shouldExclude = $true; break }
                    }
                }
                if ($shouldExclude) { continue }

                # Check if username starts with any configured prefix
                $matchedPrefix = $null
                foreach ($prefix in $Prefixes) {
                    if ($user.SamAccountName.StartsWith($prefix, [System.StringComparison]::InvariantCultureIgnoreCase)) {
                        $matchedPrefix = $prefix
                        break
                    }
                }
                if ($null -eq $matchedPrefix) { continue }

                # Check strict regex pattern if provided
                if ($Pattern -and ($user.SamAccountName -notmatch $Pattern)) { continue }

                $empNbr = if ($user.SamAccountName -match $EmpNbrCapture) { $Matches[1] } else { "" }

                # Skip accounts that don't end in exactly 6 digits — they are not valid employee accounts
                if ([string]::IsNullOrEmpty($empNbr)) { continue }

                $row = [PSCustomObject]@{
                    Username    = $user.SamAccountName
                    Prefix      = $matchedPrefix
                    EmployeeNbr = $empNbr
                    Domain      = $domain.Name
                    DomainFQDN  = $domain.FQDN
                    Enabled     = $user.Enabled
                    Mail        = if ($user.Mail) { $user.Mail } else { "" }
                }
                $domainResult.Add($row)
                $allAccounts.Add($row)
            }

            Write-Progress -Id 21 -Activity "AD Query" -Completed
            Write-Log -Message "Found $($domainResult.Count) secondary accounts in '$($domain.Name)'" -ScriptName $ScriptName -LogPath $LogPath
            $domainResult | Export-CsvNoBom -Path $CachePath
            Write-Log -Message "AD accounts for '$($domain.Name)' cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
        catch {
            Write-Progress -Id 21 -Activity "AD Query" -Completed
            Write-Log -Message "Error querying domain '$($domain.Name)': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    Write-Progress -Id 20 -Activity "Secondary AD Accounts" -Completed
    Write-Log -Message "Total secondary AD accounts collected across all domains: $($allAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath
    return $allAccounts.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAACyberArkUsers
# Fetches all CyberArk LDAP EPVUsers. Used to verify that a primary account
# has an active CyberArk user record.
# Cache file: RawCache_CyberArkUsers_<TodayStr>.csv
# ---------------------------------------------------------------------------
function Get-SAACyberArkUsers {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading CyberArk users from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching CyberArk LDAP EPVUsers (paginated)..." -ScriptName $ScriptName -LogPath $LogPath

    $allUsers = [System.Collections.Generic.List[object]]::new()
    $offset   = 0
    $limit    = 100

    do {
        Write-Progress -Id 30 -Activity "CyberArk Users" -Status "Fetching page at offset $offset (LDAP users found: $($allUsers.Count))..." -PercentComplete -1
        $uri      = "$BaseUrl/PasswordVault/api/Users?limit=$limit&offset=$offset&userType=EPVUser"
        $response = Invoke-CyberArkApi -Uri $uri
        $users    = if ($response.Users) { $response.Users } else { @() }

        foreach ($user in $users) {
            if ($user.source -ne "LDAP") { continue }
            $allUsers.Add([PSCustomObject]@{
                Username = $user.username
                Id       = $user.id
                Source   = $user.source
                UserType = $user.userType
                Enabled  = $user.enableUser
            })
        }

        $offset += $limit
        Write-Log -Message "CyberArk LDAP users fetched so far: $($allUsers.Count)..." -ScriptName $ScriptName -LogPath $LogPath
    } while ($users.Count -eq $limit -and $users.Count -gt 0)

    Write-Progress -Id 30 -Activity "CyberArk Users" -Completed
    Write-Log -Message "Total CyberArk LDAP EPVUsers: $($allUsers.Count)" -ScriptName $ScriptName -LogPath $LogPath
    $allUsers | Export-CsvNoBom -Path $CachePath
    return $allUsers.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAAPersonalSafes
# Fetches ALL CyberArk safes, saves the raw set to $RawCachePath (if provided),
# then filters by the naming pattern regex and saves matches to $CachePath.
# Cache files:
#   RawCache_AllSafes_<TodayStr>.csv      — every safe returned by the API
#   RawCache_PersonalSafes_<TodayStr>.csv — only safes matching the pattern
# ---------------------------------------------------------------------------
function Get-SAAPersonalSafes {
    param (
        [Parameter(Mandatory=$true)]  [string] $BaseUrl,
        [Parameter(Mandatory=$true)]  [string] $NamingPatternRegex,
        [Parameter(Mandatory=$true)]  [string] $CachePath,
        [Parameter(Mandatory=$true)]  [string] $ScriptName,
        [Parameter(Mandatory=$true)]  [string] $LogPath,
        [Parameter(Mandatory=$false)] [string] $RawCachePath = ""
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading personal safes from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching ALL CyberArk safes (will filter for pattern '$NamingPatternRegex' after)..." -ScriptName $ScriptName -LogPath $LogPath

    $allRaw    = [System.Collections.Generic.List[object]]::new()

    if ($RawCachePath -and (Test-Path $RawCachePath)) {
        Write-Log -Message "Loading ALL CyberArk safes from raw cache: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        $rawCsv = @(Import-Csv $RawCachePath)
        foreach ($row in $rawCsv) { $allRaw.Add($row) }
    } else {
        $seenNames = @{}
        $offset    = 0
        $limit     = 500
        $hasMore   = $true

        while ($hasMore) {
            Write-Progress -Id 40 -Activity "CyberArk Safes" -Status "Fetching safes at offset $offset (collected: $($allRaw.Count))..." -PercentComplete -1
            $uri   = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
            $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
            $batch = if ($resp.value) { $resp.value } elseif ($resp.Safes) { $resp.Safes } else { @() }

            if ($batch.Count -gt 0) {
                foreach ($safe in $batch) {
                    $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
                    if (-not $safeName -or $seenNames.ContainsKey($safeName)) { continue }
                    $seenNames[$safeName] = $true
                    $allRaw.Add([PSCustomObject]@{
                        SafeName     = $safeName
                        Description  = $safe.description
                        CreationTime = $safe.creationTime
                        Creator      = if ($safe.creator.name) { $safe.creator.name } else { [string]$safe.creator }
                    })
                }
                Write-Log -Message "Safes fetched so far: $($offset + $batch.Count)..." -ScriptName $ScriptName -LogPath $LogPath
                if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
            }
            else { $hasMore = $false }
        }

        Write-Progress -Id 40 -Activity "CyberArk Safes" -Completed
        Write-Log -Message "Total safes fetched from API: $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # --- Step 2: Save raw (unfiltered) safe list ---
        if ($RawCachePath) {
            $allRaw | Export-CsvNoBom -Path $RawCachePath
            Write-Log -Message "All safes (raw) cached: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # --- Step 3: Filter for personal safes matching the naming pattern ---
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $allRaw) {
        if ($row.SafeName -match $NamingPatternRegex) {
            $result.Add($row)
        }
    }
    Write-Log -Message "Personal safes matching pattern '$NamingPatternRegex': $($result.Count) of $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

    # --- Step 4: Save filtered personal-safe list ---
    $result | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Personal safes cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath

    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAAOnboardedAccounts
# Fetches CyberArk accounts in personal safes (matching naming pattern).
# Cache file: RawCache_OnboardedAccounts_<TodayStr>.csv
# ---------------------------------------------------------------------------
function Get-SAAOnboardedAccounts {
    param (
        [Parameter(Mandatory=$true)]  [string] $BaseUrl,
        [Parameter(Mandatory=$true)]  [string] $NamingPatternRegex,
        [Parameter(Mandatory=$true)]  [string] $CachePath,
        [Parameter(Mandatory=$true)]  [string] $ScriptName,
        [Parameter(Mandatory=$true)]  [string] $LogPath,
        [Parameter(Mandatory=$false)] [string] $RawCachePath = ""
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading onboarded accounts from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching ALL CyberArk accounts (will filter for personal safes after)..." -ScriptName $ScriptName -LogPath $LogPath

    $allRaw  = [System.Collections.Generic.List[object]]::new()

    if ($RawCachePath -and (Test-Path $RawCachePath)) {
        Write-Log -Message "Loading ALL CyberArk accounts from raw cache: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        $rawCsv = @(Import-Csv $RawCachePath)
        foreach ($row in $rawCsv) { $allRaw.Add($row) }
    } else {
        $offset  = 0
        $limit   = 1000
        $hasMore = $true

        # --- Step 1: Collect ALL accounts ---
        while ($hasMore) {
            Write-Progress -Id 50 -Activity "CyberArk Accounts" -Status "Fetching accounts at offset $offset (collected: $($allRaw.Count))..." -PercentComplete -1
            $uri   = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset"
            $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
            $batch = if ($resp.value) { $resp.value } else { @() }

            if ($batch.Count -gt 0) {
                foreach ($acc in $batch) {
                    $allRaw.Add([PSCustomObject]@{
                        AccountId  = $acc.id
                        Username   = $acc.userName
                        Address    = $acc.address
                        SafeName   = $acc.safeName
                        PlatformId = $acc.platformId
                    })
                }
                $offset += $limit
                if ($batch.Count -lt $limit) { $hasMore = $false }
                Write-Log -Message "Accounts fetched so far: $($allRaw.Count)..." -ScriptName $ScriptName -LogPath $LogPath
            }
            else { $hasMore = $false }
        }

        Write-Progress -Id 50 -Activity "CyberArk Accounts" -Completed
        Write-Log -Message "Total accounts fetched from API: $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

        # --- Step 2: Save raw (unfiltered) account list ---
        if ($RawCachePath) {
            $allRaw | Export-CsvNoBom -Path $RawCachePath
            Write-Log -Message "All accounts (raw) cached: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # --- Step 3: Filter for accounts in personal safes ---
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $allRaw) {
        if ($row.SafeName -match $NamingPatternRegex) {
            $result.Add($row)
        }
    }
    Write-Log -Message "Onboarded accounts in personal safes: $($result.Count) of $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

    # --- Step 4: Save filtered account list ---
    $result | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Onboarded accounts cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAAGroupMemberSet
# Returns a case-insensitive HashSet of usernames who are members of the
# specified Active Directory group. Queries the Primary Domain.
# Cache file (optional): RawCache_GroupMembers_<TodayStr>.csv
#   If the cache file exists for today, the HashSet is rebuilt from it.
#   Otherwise AD is queried and the result is saved to the cache.
# ---------------------------------------------------------------------------
function Get-SAAGroupMemberSet {
    param (
        [Parameter(Mandatory=$true)]  [array]  $Domains,
        [Parameter(Mandatory=$true)]  [string] $GroupName,
        [Parameter(Mandatory=$true)]  [string] $ScriptName,
        [Parameter(Mandatory=$true)]  [string] $LogPath,
        [Parameter(Mandatory=$true)]  [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)]  [bool]   $ManualLogin,
        [Parameter(Mandatory=$false)] [string] $CachePath = ""
    )

    $memberSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # --- Load from cache if available ---
    if ($CachePath -and (Test-Path $CachePath)) {
        Write-Log -Message "Loading group members for '$GroupName' from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        $cached = @(Import-Csv $CachePath)
        foreach ($row in $cached) {
            if ($row.Username) { [void]$memberSet.Add($row.Username) }
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

    # Fetch domain-specific credentials
    # Direct credentials are used ONLY when both Username AND Password are non-blank.
    # If either is empty, fall through to CCP.
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

    try {
        Write-Progress -Id 60 -Activity "AD Group Members" -Status "Querying AD server '$($primaryDomain.Server)' for group '$GroupName'..." -PercentComplete -1
        $members = Get-ADGroupMember @adParams
        
        $memberRows = [System.Collections.Generic.List[object]]::new()
        foreach ($m in $members) {
            # Skip nested groups/computers, we only want actual users
            if ($m.objectClass -ne "user") { continue }
            
            $username = $m.SamAccountName
            if ($username) {
                [void]$memberSet.Add($username)
                $memberRows.Add([PSCustomObject]@{ Username = $username })
            }
        }

        Write-Progress -Id 60 -Activity "AD Group Members" -Completed
        Write-Log -Message "AD Group '$GroupName' has $($memberSet.Count) user members." -ScriptName $ScriptName -LogPath $LogPath

        # --- Save to cache ---
        if ($CachePath) {
            $memberRows | Export-CsvNoBom -Path $CachePath
            Write-Log -Message "Group members cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
    }
    catch {
        Write-Progress -Id 60 -Activity "AD Group Members" -Completed
        Write-Log -Message "Failed to retrieve AD group '$GroupName': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $memberSet
}
