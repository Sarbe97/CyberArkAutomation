# =============================================================================
# SVC_DataCollection.ps1
# Fetches and caches AD data and CyberArk account data for ServiceAccountAnalysis.
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
# Get-SVCADAccounts
# Queries ALL configured domains for all AD user accounts, filters OUT those
# matching the PersonalAccount regex, and returns the rest (Service Accounts).
#
# Per-domain OU exclusions are handled via the domain's ExcludeOUs array.
# Each entry is a full Distinguished Name (e.g. "OU=Tier0,DC=na,DC=company,DC=com").
# All users are fetched with Filter="*" and then users whose DistinguishedName
# falls under an excluded OU are silently dropped.
#
# Includes extended attributes: PasswordExpired, PasswordLastSet,
# PasswordNeverExpires, LastLogonDate, wwwHomePage.
# ---------------------------------------------------------------------------
function Get-SVCADAccounts {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [string] $PersonalAccountPattern,
        [Parameter(Mandatory=$true)] [string] $CacheDir,
        [Parameter(Mandatory=$true)] [string] $TodayStr,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]   $ManualLogin
    )

    $allAccounts  = [System.Collections.Generic.List[object]]::new()
    $totalDomains = $Domains.Count
    $domainIndex  = 0

    foreach ($domain in $Domains) {
        $domainIndex++
        $CachePath = Join-Path $CacheDir "RawCache_ADAccounts_$($domain.Name)_$TodayStr.csv"

        if (Test-Path $CachePath) {
            Write-Log -Message "[$domainIndex/$totalDomains] Loading AD accounts for '$($domain.Name)' from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
            $cached = @(Import-Csv $CachePath)
            foreach ($row in $cached) { $allAccounts.Add($row) }
            continue
        }

        Write-Progress -Id 20 -Activity "Service Accounts" -Status "[$domainIndex/$totalDomains] Querying domain: $($domain.Name)" -PercentComplete ([int](($domainIndex / $totalDomains) * 100))
        Write-Log -Message "[$domainIndex/$totalDomains] Querying domain '$($domain.Name)' ($($domain.FQDN)) for all user accounts..." -ScriptName $ScriptName -LogPath $LogPath

        # Resolve excluded OUs for this domain (array of lowercase DN strings)
        $excludedOUs = @()
        if ($domain.ExcludeOUs -and $domain.ExcludeOUs.Count -gt 0) {
            $excludedOUs = @($domain.ExcludeOUs | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
            Write-Log -Message "[$domainIndex/$totalDomains] Will exclude $($excludedOUs.Count) OU(s) from '$($domain.Name)'." -ScriptName $ScriptName -LogPath $LogPath
        }

        $credentialObj = $null
        $hasDirectCredentials = (-not [string]::IsNullOrWhiteSpace($domain.Username)) -and
                                (-not [string]::IsNullOrWhiteSpace($domain.Password))

        if ($hasDirectCredentials) {
            $secPass       = ConvertTo-SecureString $domain.Password -AsPlainText -Force
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
                $secPass       = ConvertTo-SecureString $creds.Password -AsPlainText -Force
                $credentialObj = New-Object System.Management.Automation.PSCredential($creds.Username, $secPass)
            }
            catch {
                Write-Log -Message "[$domainIndex/$totalDomains] Failed to fetch CCP credentials for domain '$($domain.Name)': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
                continue
            }
        } else {
            Write-Log -Message "[$domainIndex/$totalDomains] No credentials configured for domain '$($domain.Name)'. Querying AD using current execution context." -ScriptName $ScriptName -LogPath $LogPath
        }

        $domainResult = [System.Collections.Generic.List[object]]::new()

        try {
            $adProps = @(
                "SamAccountName",
                "DistinguishedName",
                "Enabled",
                "Mail",
                "Description",
                "PasswordExpired",
                "PasswordLastSet",
                "PasswordNeverExpires",
                "LastLogonDate",
                "wwwHomePage"
            )

            $adParams = @{
                Filter      = "*"
                Server      = $domain.Server
                Properties  = $adProps
                ErrorAction = "Stop"
            }
            if ($null -ne $credentialObj) {
                $adParams["Credential"] = $credentialObj
            }

            Write-Log -Message "[$domainIndex/$totalDomains] Sending AD query to server '$($domain.Server)'..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -ParentId 20 -Activity "AD Query" -Status "Querying '$($domain.Server)'... (this may take a moment)" -PercentComplete -1

            $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, DistinguishedName, Enabled, Mail, Description, PasswordExpired, PasswordLastSet, PasswordNeverExpires, LastLogonDate, wwwHomePage)
            $rawCount = if ($adUsers) { $adUsers.Count } else { 0 }

            Write-Log -Message "[$domainIndex/$totalDomains] AD query completed. Received $rawCount raw user records from server '$($domain.Server)'. Applying filters..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -Activity "AD Query" -Status "Processing $rawCount records from '$($domain.Server)'..." -PercentComplete -1

            $ouSkipCount = 0

            foreach ($user in $adUsers) {
                if (-not $user.SamAccountName) { continue }

                # Check if it matches the Personal Account regex — skip personal accounts
                if ($PersonalAccountPattern -and ($user.SamAccountName -match $PersonalAccountPattern)) {
                    continue
                }

                # OU exclusion check — skip users whose DN falls under any excluded OU
                if ($excludedOUs.Count -gt 0) {
                    $userDN = $user.DistinguishedName.ToLower()
                    $inExcludedOU = $false
                    foreach ($ouDN in $excludedOUs) {
                        # Check if the user's DN ends with the excluded OU DN
                        if ($userDN.EndsWith(",$ouDN") -or $userDN -eq $ouDN) {
                            $inExcludedOU = $true
                            break
                        }
                    }
                    if ($inExcludedOU) { $ouSkipCount++; continue }
                }

                $row = [PSCustomObject]@{
                    Username             = $user.SamAccountName
                    Domain               = $domain.Name
                    DomainFQDN           = $domain.FQDN
                    Enabled              = $user.Enabled
                    PasswordExpired      = if ($null -ne $user.PasswordExpired)      { $user.PasswordExpired }      else { "" }
                    PasswordLastSet      = if ($null -ne $user.PasswordLastSet)      { $user.PasswordLastSet.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                    PasswordNeverExpires = if ($null -ne $user.PasswordNeverExpires) { $user.PasswordNeverExpires } else { "" }
                    LastLogonDate        = if ($null -ne $user.LastLogonDate)        { $user.LastLogonDate.ToString("yyyy-MM-dd HH:mm:ss") }   else { "" }
                    Mail                 = if ($user.Mail)        { $user.Mail }        else { "" }
                    Description          = if ($user.Description) { $user.Description } else { "" }
                    wwwHomePage          = if ($user.wwwHomePage)  { $user.wwwHomePage }  else { "" }
                }
                $domainResult.Add($row)
                $allAccounts.Add($row)
            }

            if ($ouSkipCount -gt 0) {
                Write-Log -Message "[$domainIndex/$totalDomains] Skipped $ouSkipCount user(s) in excluded OUs for '$($domain.Name)'." -ScriptName $ScriptName -LogPath $LogPath
            }

            Write-Progress -Id 21 -Activity "AD Query" -Completed
            Write-Log -Message "Found $($domainResult.Count) service accounts in '$($domain.Name)'" -ScriptName $ScriptName -LogPath $LogPath
            $domainResult | Export-CsvNoBom -Path $CachePath
            Write-Log -Message "AD accounts for '$($domain.Name)' cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
        catch {
            Write-Progress -Id 21 -Activity "AD Query" -Completed
            Write-Log -Message "Error querying domain '$($domain.Name)': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    Write-Progress -Id 20 -Activity "Service Accounts" -Completed
    Write-Log -Message "Total service AD accounts collected across all domains: $($allAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath
    return $allAccounts.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SVCCyberArkAccounts
# Fetches ALL accounts from CyberArk PVWA 14.x via the Accounts REST API,
# using nextLink-based pagination. Caches the raw full pull to CSV.
#
# Then applies two filters in sequence:
#   1. Personal safe filter: removes accounts whose SafeName matches the
#      PersonalSafeRegex (e.g. "^S-A-PR-WI-U\d{6}$" from SecondaryAccountAnalysis).
#   2. Domain address filter: from the remaining accounts, keeps only those
#      whose Address field fuzzy-matches at least one configured domain
#      (by FQDN or short name). These are considered service accounts in CyberArk.
#
# Returns: filtered array of [PSCustomObject]{ Username, Address, SafeName, PlatformId }
# Also sets $script:SVCCyberArkServiceAccountCount for summary reporting.
# ---------------------------------------------------------------------------
function Get-SVCCyberArkAccounts {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $Token,
        [Parameter(Mandatory=$true)] [string] $CacheDir,
        [Parameter(Mandatory=$true)] [string] $TodayStr,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath,
        [Parameter(Mandatory=$true)] [string] $PersonalSafeRegex,
        [Parameter(Mandatory=$true)] [array]  $Domains
    )

    $RawCachePath      = Join-Path $CacheDir "RawCache_CyberArkAccounts_$TodayStr.csv"
    $FilteredCachePath = Join-Path $CacheDir "RawCache_CyberArkServiceAccounts_$TodayStr.csv"

    # Build the set of known domain identifiers (both FQDN and short name, lowercase)
    # for the address-match filter
    $domainIdentifiers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $Domains) {
        if ($d.FQDN)  { [void]$domainIdentifiers.Add($d.FQDN.ToLower()) }
        if ($d.Name)  { [void]$domainIdentifiers.Add($d.Name.ToLower()) }
    }

    # ── Step 1: Raw fetch (or load from cache) ──────────────────────────────
    $allRaw = [System.Collections.Generic.List[object]]::new()

    if (Test-Path $RawCachePath) {
        Write-Log -Message "Loading raw CyberArk accounts from cache: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        $allRaw.AddRange(@(Import-Csv $RawCachePath))
        Write-Log -Message "Loaded $($allRaw.Count) raw CyberArk accounts from cache." -ScriptName $ScriptName -LogPath $LogPath
    } else {
        Write-Log -Message "Fetching all CyberArk accounts via REST API (PVWA $BaseUrl)..." -ScriptName $ScriptName -LogPath $LogPath

        $headers = @{ Authorization = $Token }
        $pageSize = 1000
        $offset   = 0
        $pageNum  = 1
        $hasMore  = $true

        while ($hasMore) {
            $uri = "$BaseUrl/PasswordVault/API/Accounts?limit=$pageSize&offset=$offset"
            Write-Log -Message "Fetching CyberArk accounts page $pageNum (offset=$offset)..." -ScriptName $ScriptName -LogPath $LogPath

            try {
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ContentType "application/json" -ErrorAction Stop -TimeoutSec 60

                $batch = $response.value
                if ($null -eq $batch -or $batch.Count -eq 0) {
                    $hasMore = $false
                    break
                }

                foreach ($acct in $batch) {
                    $allRaw.Add([PSCustomObject]@{
                        Username   = if ($acct.userName)   { $acct.userName }   else { "" }
                        Address    = if ($acct.address)    { $acct.address }    else { "" }
                        SafeName   = if ($acct.safeName)   { $acct.safeName }   else { "" }
                        PlatformId = if ($acct.platformId) { $acct.platformId } else { "" }
                    })
                }

                Write-Log -Message "Page $pageNum retrieved $($batch.Count) accounts. Running total: $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

                if ($response.nextLink) {
                    $offset  += $pageSize
                    $pageNum += 1
                } else {
                    $hasMore = $false
                }
            }
            catch {
                Write-Log -Message "Failed to retrieve CyberArk accounts page $pageNum (offset=$offset): $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
                $hasMore = $false
            }
        }

        Write-Log -Message "Total raw CyberArk accounts fetched: $($allRaw.Count)" -ScriptName $ScriptName -LogPath $LogPath

        if ($allRaw.Count -gt 0) {
            $allRaw | Export-CsvNoBom -Path $RawCachePath
            Write-Log -Message "Raw CyberArk accounts cached: $RawCachePath" -ScriptName $ScriptName -LogPath $LogPath
        }
    }

    # ── Step 2: Filter out personal safes ───────────────────────────────────
    $afterPersonalFilter = [System.Collections.Generic.List[object]]::new()
    $personalSafeSkipCount = 0

    foreach ($acct in $allRaw) {
        if ($PersonalSafeRegex -and $acct.SafeName -match $PersonalSafeRegex) {
            $personalSafeSkipCount++
        } else {
            $afterPersonalFilter.Add($acct)
        }
    }

    Write-Log -Message "Personal safe filter: removed $personalSafeSkipCount accounts. Remaining: $($afterPersonalFilter.Count)" -ScriptName $ScriptName -LogPath $LogPath

    # ── Step 3: Address-domain match — keep only service-domain accounts ─────
    # An account is considered a service account in CyberArk if its Address
    # fuzzy-matches one of the configured domains (FQDN or short name).
    $serviceAccounts = [System.Collections.Generic.List[object]]::new()
    $noAddressMatchCount = 0

    foreach ($acct in $afterPersonalFilter) {
        $addr = $acct.Address.ToLower().Trim()

        $domainMatched = $false
        foreach ($d in $Domains) {
            $fqdn  = $d.FQDN.ToLower()
            $short = $d.Name.ToLower()

            $addrMatches = (
                $addr -eq $fqdn   -or           # exact FQDN
                $addr -eq $short  -or           # exact short name
                $fqdn.StartsWith($addr) -or     # addr is a leading segment of FQDN
                $addr.EndsWith($fqdn)   -or     # addr ends with FQDN
                $addr.Contains($fqdn)   -or     # addr contains FQDN
                $fqdn.Contains($addr)           # FQDN contains addr (addr is partial)
            )

            if ($addrMatches) {
                $domainMatched = $true
                break
            }
        }

        if ($domainMatched) {
            $serviceAccounts.Add($acct)
        } else {
            $noAddressMatchCount++
        }
    }

    Write-Log -Message "Domain address filter: kept $($serviceAccounts.Count) service accounts, excluded $noAddressMatchCount accounts with non-matching or empty addresses." -ScriptName $ScriptName -LogPath $LogPath

    if ($serviceAccounts.Count -gt 0) {
        $serviceAccounts | Export-CsvNoBom -Path $FilteredCachePath
        Write-Log -Message "Filtered CyberArk service accounts cached: $FilteredCachePath" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $serviceAccounts.ToArray()
}

# ---------------------------------------------------------------------------
# Resolve-SVCCyberArkOnboarding
# Cross-references AD service accounts against CyberArk service accounts.
# Matching logic (both conditions must hold):
#   1. CyberArk username == AD username (case-insensitive)
#   2. CyberArk address fuzzy-matches the AD domain (same logic as above)
# Returns the same AD objects enriched with: InCyberArk, CyberArkSafe, CyberArkPlatform
# ---------------------------------------------------------------------------
function Resolve-SVCCyberArkOnboarding {
    param (
        [Parameter(Mandatory=$true)] [array]  $ADAccounts,
        [Parameter(Mandatory=$true)] [array]  $CyberArkAccounts,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    Write-Log -Message "Cross-referencing $($ADAccounts.Count) AD accounts against $($CyberArkAccounts.Count) CyberArk service accounts..." -ScriptName $ScriptName -LogPath $LogPath

    # Build a lookup grouped by lowercase username for O(1) lookup
    $caLookup = @{}
    foreach ($ca in $CyberArkAccounts) {
        $key = $ca.Username.ToLower()
        if (-not $caLookup.ContainsKey($key)) {
            $caLookup[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $caLookup[$key].Add($ca)
    }

    $enriched       = [System.Collections.Generic.List[object]]::new()
    $onboardedCount = 0

    foreach ($ad in $ADAccounts) {
        $usernameKey = $ad.Username.ToLower()
        $domainFQDN  = $ad.DomainFQDN.ToLower()
        $domainShort = $ad.Domain.ToLower()

        $matched     = $false
        $matchedSafe = ""
        $matchedPlat = ""

        if ($caLookup.ContainsKey($usernameKey)) {
            foreach ($ca in $caLookup[$usernameKey]) {
                $caAddr = $ca.Address.ToLower().Trim()

                $addrMatches = (
                    $caAddr -eq $domainFQDN          -or
                    $caAddr -eq $domainShort         -or
                    $domainFQDN.StartsWith($caAddr)  -or
                    $caAddr.EndsWith($domainFQDN)    -or
                    $caAddr.Contains($domainFQDN)    -or
                    $domainFQDN.Contains($caAddr)    -or
                    $caAddr -eq ""
                )

                if ($addrMatches) {
                    $matched     = $true
                    $matchedSafe = $ca.SafeName
                    $matchedPlat = $ca.PlatformId
                    break
                }
            }
        }

        if ($matched) { $onboardedCount++ }

        $enriched.Add([PSCustomObject]@{
            Username             = $ad.Username
            Domain               = $ad.Domain
            DomainFQDN           = $ad.DomainFQDN
            Enabled              = $ad.Enabled
            PasswordExpired      = $ad.PasswordExpired
            PasswordLastSet      = $ad.PasswordLastSet
            PasswordNeverExpires = $ad.PasswordNeverExpires
            LastLogonDate        = $ad.LastLogonDate
            Mail                 = $ad.Mail
            Description          = $ad.Description
            wwwHomePage          = $ad.wwwHomePage
            InCyberArk           = $matched
            CyberArkSafe         = $matchedSafe
            CyberArkPlatform     = $matchedPlat
        })
    }

    Write-Log -Message "Onboarding cross-reference complete. $onboardedCount of $($ADAccounts.Count) AD accounts found in CyberArk." -ScriptName $ScriptName -LogPath $LogPath
    return $enriched.ToArray()
}
