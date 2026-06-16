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
# Includes extended attributes: PasswordExpired, PasswordLastSet,
# PasswordNeverExpires, LastLogonDate, wwwHomePage.
# ---------------------------------------------------------------------------
function Get-SVCADAccounts {
    param (
        [Parameter(Mandatory=$true)] [array]         $Domains,
        [Parameter(Mandatory=$true)] [string]        $PersonalAccountPattern,
        [Parameter(Mandatory=$true)] [PSCustomObject] $Exclusions,
        [Parameter(Mandatory=$true)] [string]        $CacheDir,
        [Parameter(Mandatory=$true)] [string]        $TodayStr,
        [Parameter(Mandatory=$true)] [string]        $ScriptName,
        [Parameter(Mandatory=$true)] [string]        $LogPath,
        [Parameter(Mandatory=$true)] [string]        $GlobalCCPUrl,
        [Parameter(Mandatory=$true)] [bool]          $ManualLogin
    )

    $allAccounts  = [System.Collections.Generic.List[object]]::new()
    $totalDomains = $Domains.Count
    $domainIndex  = 0

    foreach ($domain in $Domains) {
        $domainIndex++
        $CachePath = Join-Path $CacheDir "RawCache_ADAccounts_$($domain.Name)_$TodayStr.csv"

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

        Write-Progress -Id 20 -Activity "Service Accounts" -Status "[$domainIndex/$totalDomains] Querying domain: $($domain.Name)" -PercentComplete ([int](($domainIndex / $totalDomains) * 100))
        Write-Log -Message "[$domainIndex/$totalDomains] Querying domain '$($domain.Name)' ($($domain.FQDN)) for all user accounts..." -ScriptName $ScriptName -LogPath $LogPath

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

            $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, Enabled, Mail, Description, PasswordExpired, PasswordLastSet, PasswordNeverExpires, LastLogonDate, wwwHomePage)
            $rawCount = if ($adUsers) { $adUsers.Count } else { 0 }

            Write-Log -Message "[$domainIndex/$totalDomains] AD query completed. Received $rawCount raw user records from server '$($domain.Server)'. Filtering out personal accounts..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -Activity "AD Query" -Status "Processing $rawCount records from '$($domain.Server)'..." -PercentComplete -1

            foreach ($user in $adUsers) {
                if (-not $user.SamAccountName) { continue }

                # Check exclusion by username pattern
                $shouldExclude = $false
                if ($Exclusions.UsernamePatterns) {
                    foreach ($pattern in $Exclusions.UsernamePatterns) {
                        if ($user.SamAccountName -match $pattern) { $shouldExclude = $true; break }
                    }
                }
                if ($shouldExclude) { continue }

                # Check if it matches the Personal Account regex
                if ($PersonalAccountPattern -and ($user.SamAccountName -match $PersonalAccountPattern)) {
                    continue # It's a personal account, so exclude it
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
# using nextLink-based pagination. Caches results to a CSV for same-day re-use.
# Returns: array of [PSCustomObject]{ Username, Address, SafeName, PlatformId }
# ---------------------------------------------------------------------------
function Get-SVCCyberArkAccounts {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $Token,
        [Parameter(Mandatory=$true)] [string] $CacheDir,
        [Parameter(Mandatory=$true)] [string] $TodayStr,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    $CachePath = Join-Path $CacheDir "RawCache_CyberArkAccounts_$TodayStr.csv"

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading CyberArk accounts from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        $cached = @(Import-Csv $CachePath)
        Write-Log -Message "Loaded $($cached.Count) CyberArk accounts from cache." -ScriptName $ScriptName -LogPath $LogPath
        return $cached
    }

    Write-Log -Message "Fetching all CyberArk accounts via REST API (PVWA $BaseUrl)..." -ScriptName $ScriptName -LogPath $LogPath

    $allCyberArkAccounts = [System.Collections.Generic.List[object]]::new()
    $headers    = @{ Authorization = $Token }
    $pageSize   = 1000
    $offset     = 0
    $pageNum    = 1
    $hasMore    = $true

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
                $allCyberArkAccounts.Add([PSCustomObject]@{
                    Username   = if ($acct.userName)   { $acct.userName }   else { "" }
                    Address    = if ($acct.address)    { $acct.address }    else { "" }
                    SafeName   = if ($acct.safeName)   { $acct.safeName }   else { "" }
                    PlatformId = if ($acct.platformId) { $acct.platformId } else { "" }
                })
            }

            Write-Log -Message "Page $pageNum retrieved $($batch.Count) accounts. Running total: $($allCyberArkAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

            # PVWA 14.x: nextLink signals more pages; absence means we are done
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

    Write-Log -Message "Total CyberArk accounts fetched: $($allCyberArkAccounts.Count)" -ScriptName $ScriptName -LogPath $LogPath

    if ($allCyberArkAccounts.Count -gt 0) {
        $allCyberArkAccounts | Export-CsvNoBom -Path $CachePath
        Write-Log -Message "CyberArk accounts cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $allCyberArkAccounts.ToArray()
}

# ---------------------------------------------------------------------------
# Resolve-SVCCyberArkOnboarding
# Cross-references AD service accounts against CyberArk accounts.
# Matching logic (both conditions must hold):
#   1. CyberArk username == AD username (case-insensitive)
#   2. CyberArk address  fuzzy-matches the AD domain:
#        - Exact FQDN:       address -eq DomainFQDN        (e.g. "na.company.com")
#        - Exact short name: address -eq DomainShortName   (e.g. "NA", "NADEV")
#        - FQDN contains address as suffix/prefix segment
#        - Address contains the FQDN
# Returns the same objects enriched with: InCyberArk, CyberArkSafe, CyberArkPlatform
# ---------------------------------------------------------------------------
function Resolve-SVCCyberArkOnboarding {
    param (
        [Parameter(Mandatory=$true)] [array] $ADAccounts,
        [Parameter(Mandatory=$true)] [array] $CyberArkAccounts,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    Write-Log -Message "Cross-referencing $($ADAccounts.Count) AD accounts against $($CyberArkAccounts.Count) CyberArk accounts..." -ScriptName $ScriptName -LogPath $LogPath

    # Build a lookup grouped by lowercase username for O(1) lookup
    $caLookup = @{}
    foreach ($ca in $CyberArkAccounts) {
        $key = $ca.Username.ToLower()
        if (-not $caLookup.ContainsKey($key)) {
            $caLookup[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $caLookup[$key].Add($ca)
    }

    $enriched = [System.Collections.Generic.List[object]]::new()
    $onboardedCount = 0

    foreach ($ad in $ADAccounts) {
        $usernameKey  = $ad.Username.ToLower()
        $domainFQDN   = $ad.DomainFQDN.ToLower()
        $domainShort  = $ad.Domain.ToLower()

        $matched        = $false
        $matchedSafe    = ""
        $matchedPlat    = ""

        if ($caLookup.ContainsKey($usernameKey)) {
            foreach ($ca in $caLookup[$usernameKey]) {
                $caAddr = $ca.Address.ToLower().Trim()

                # Fuzzy address matching against the AD domain
                $addrMatches = (
                    $caAddr -eq $domainFQDN   -or   # exact FQDN
                    $caAddr -eq $domainShort  -or   # exact short name
                    $domainFQDN.StartsWith($caAddr)  -or   # addr is prefix of FQDN (e.g. "na" vs "na.company.com")
                    $caAddr.EndsWith($domainFQDN)    -or   # addr ends with FQDN
                    $caAddr.Contains($domainFQDN)    -or   # addr contains FQDN
                    $domainFQDN.Contains($caAddr)    -or   # FQDN contains addr (e.g. addr="nadev.company.com")
                    $caAddr -eq ""                         # no address set — match on username alone
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

    Write-Log -Message "Onboarding cross-reference complete. $onboardedCount of $($ADAccounts.Count) accounts found in CyberArk." -ScriptName $ScriptName -LogPath $LogPath
    return $enriched.ToArray()
}
