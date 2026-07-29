# =============================================================================
# DR_DataCollection.ps1
# Fetches raw data from the CyberArk API (with local daily cache).
# Exposes: Get-RawAccounts, Get-RawPendingDiscovered, Get-RawPlatforms, Get-RawSafes
# =============================================================================

function Get-RawAccounts {
    param(
        [string]$BaseUrl,
        [string]$CachePath,
        [string]$ScriptName,
        [string]$LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading accounts from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching raw accounts from API. This may take a while..." -ScriptName $ScriptName -LogPath $LogPath
    $result  = @()
    $limit   = 1000
    $offset  = 0
    $hasMore = $true

    while ($hasMore) {
        $uri   = "$BaseUrl/PasswordVault/api/Accounts?limit=$limit&offset=$offset"
        $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($acc in $batch) {
                $result += [PSCustomObject]@{
                    name                       = $acc.name
                    address                    = $acc.address
                    userName                   = $acc.userName
                    platformId                 = $acc.platformId
                    safeName                   = $acc.safeName
                    secretType                 = $acc.secretType
                    automaticManagementEnabled = $acc.secretManagement.automaticManagementEnabled
                    manualManagementReason     = $acc.secretManagement.manualManagementReason
                    creationTime               = $acc.creationTime
                }
            }
            $offset += $limit
            if ($batch.Count -lt $limit) { $hasMore = $false }
            Write-Log -Message "Fetched $($result.Count) raw accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
        }
        else { $hasMore = $false }
    }

    $result | Export-Csv -Path $CachePath -NoTypeInformation
    return $result
}

function Get-RawPendingDiscovered {
    param(
        [string]$BaseUrl,
        [string]$CachePath,
        [string]$ScriptName,
        [string]$LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading pending discovered accounts from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching raw pending discovered accounts from API..." -ScriptName $ScriptName -LogPath $LogPath
    $result  = @()
    $limit   = 1000
    $offset  = 0
    $hasMore = $true

    while ($hasMore) {
        $uri   = "$BaseUrl/PasswordVault/API/DiscoveredAccounts/?limit=$limit&offset=$offset"
        $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($acc in $batch) {
                $result += [PSCustomObject]@{
                    Id            = $acc.id
                    Name          = $acc.name
                    UserName      = $acc.userName
                    Address       = $acc.address
                    PlatformType  = $acc.platformType
                    OSFamily      = $acc.osFamily
                    DiscoveryDate = if ($acc.discoveryDate) { $acc.discoveryDate } else { $acc.lastLogonDateTime }
                }
            }
            $offset += $limit
            if ($batch.Count -lt $limit) { $hasMore = $false }
            Write-Log -Message "Fetched $($result.Count) pending discovered accounts so far..." -ScriptName $ScriptName -LogPath $LogPath
        }
        else { $hasMore = $false }
    }

    $result | Export-Csv -Path $CachePath -NoTypeInformation
    return $result
}

function Get-RawPlatforms {
    param(
        [string]$BaseUrl,
        [string]$CachePath,
        [string]$ScriptName,
        [string]$LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading platforms from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching raw platforms from API..." -ScriptName $ScriptName -LogPath $LogPath
    $uri      = "$BaseUrl/PasswordVault/API/Platforms?active=true&limit=500"
    $resp     = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
    $batch    = if ($resp.Platforms) { $resp.Platforms } else { @() }
    $result   = @()

    foreach ($p in $batch) {
        $result += [PSCustomObject]@{
            id                       = if ($p.general.id)     { $p.general.id }     else { $p.platformId }
            name                     = if ($p.general.name)   { $p.general.name }   else { $p.name }
            active                   = if ($null -ne $p.general.active) { $p.general.active } else { $p.active }
            systemType               = $p.general.systemType
            platformBaseID           = $p.platformBaseID
            linkedAccounts           = $p.linkedAccounts | ConvertTo-Json -Compress -Depth 5
            performPeriodicChange    = $p.automaticPasswordManagement.performPeriodicChange
            privilegedAccessWorkflows = $p.privilegedAccessWorkflows | ConvertTo-Json -Compress -Depth 5
        }
    }

    $result | Export-Csv -Path $CachePath -NoTypeInformation
    return $result
}

function Get-RawSafes {
    param(
        [string]$BaseUrl,
        [string]$CachePath,
        [string]$ScriptName,
        [string]$LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading safes from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching raw safes from API..." -ScriptName $ScriptName -LogPath $LogPath
    $result    = @()
    $seenSafes = @{}
    $limit     = 500
    $offset    = 0
    $hasMore   = $true

    while ($hasMore) {
        $uri  = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
        $resp = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } elseif ($resp.Safes) { $resp.Safes } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($s in $batch) {
                $sName = if ($s.safeName) { $s.safeName } else { $s.SafeName }
                if (-not $sName -or $seenSafes.ContainsKey($sName)) { continue }
                $seenSafes[$sName] = $true

                $result += [PSCustomObject]@{
                    safeName     = $sName
                    description  = $s.description
                    creationTime = if ($s.creationTime) { $s.creationTime } else { $s.CreationDate }
                    creator      = if ($s.creator.name) { $s.creator.name } elseif ($s.creator) { $s.creator } else { "Unknown" }
                }
            }
            if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
        }
        else { $hasMore = $false }
    }

    $result | Export-Csv -Path $CachePath -NoTypeInformation
    return $result
}
