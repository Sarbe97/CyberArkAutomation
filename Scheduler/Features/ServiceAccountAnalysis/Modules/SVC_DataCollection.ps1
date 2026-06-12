# =============================================================================
# SVC_DataCollection.ps1
# Fetches and caches AD data needed by ServiceAccountAnalysis.
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
# ---------------------------------------------------------------------------
function Get-SVCADAccounts {
    param (
        [Parameter(Mandatory=$true)] [array]  $Domains,
        [Parameter(Mandatory=$true)] [string] $PersonalAccountPattern,
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
                continue
            }
        } else {
            Write-Log -Message "[$domainIndex/$totalDomains] No credentials configured for domain '$($domain.Name)'. Querying AD using current execution context." -ScriptName $ScriptName -LogPath $LogPath
        }

        $domainResult = [System.Collections.Generic.List[object]]::new()

        try {
            $adParams = @{
                Filter      = "*"
                Server      = $domain.Server
                Properties  = @("SamAccountName", "Enabled", "Mail", "Description")
                ErrorAction = "Stop"
            }
            if ($null -ne $credentialObj) {
                $adParams["Credential"] = $credentialObj
            }

            Write-Log -Message "[$domainIndex/$totalDomains] Sending AD query to server '$($domain.Server)'..." -ScriptName $ScriptName -LogPath $LogPath
            Write-Progress -Id 21 -ParentId 20 -Activity "AD Query" -Status "Querying '$($domain.Server)'... (this may take a moment)" -PercentComplete -1
            
            # Use where-object to only get User objects, though Get-ADUser only returns user objects.
            $adUsers = @(Get-ADUser @adParams | Select-Object SamAccountName, Enabled, Mail, Description)
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
                    Username    = $user.SamAccountName
                    Domain      = $domain.Name
                    DomainFQDN  = $domain.FQDN
                    Enabled     = $user.Enabled
                    Mail        = if ($user.Mail) { $user.Mail } else { "" }
                    Description = if ($user.Description) { $user.Description } else { "" }
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
