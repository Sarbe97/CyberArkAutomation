# =============================================================================
# SAFE_DataCollection.ps1
# Fetches CyberArk safes and safe members for SafeAnalysis.
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
# Get-SAFEAllSafes
# Fetches ALL CyberArk safes and filters out exclusions.
# ---------------------------------------------------------------------------
function Get-SAFEAllSafes {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [PSCustomObject] $Exclusions,
        [Parameter(Mandatory=$true)] [string] $CachePath,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    if (Test-Path $CachePath) {
        Write-Log -Message "Loading safes from cache: $CachePath" -ScriptName $ScriptName -LogPath $LogPath
        return @(Import-Csv $CachePath)
    }

    Write-Log -Message "Fetching ALL CyberArk safes..." -ScriptName $ScriptName -LogPath $LogPath

    $allSafes = [System.Collections.Generic.List[object]]::new()
    $offset    = 0
    $limit     = 500
    $hasMore   = $true

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Exclusions.InbuiltSafes) { foreach ($s in $Exclusions.InbuiltSafes) { [void]$excludeSet.Add($s) } }
    if ($Exclusions.ExceptionSafes) { foreach ($s in $Exclusions.ExceptionSafes) { [void]$excludeSet.Add($s) } }

    while ($hasMore) {
        Write-Progress -Id 40 -Activity "CyberArk Safes" -Status "Fetching safes at offset $offset (collected: $($allSafes.Count))..." -PercentComplete -1
        $uri   = "$BaseUrl/PasswordVault/api/Safes?limit=$limit&offset=$offset"
        $resp  = Invoke-CyberArkApi -Uri $uri -TimeoutSec 120
        $batch = if ($resp.value) { $resp.value } elseif ($resp.Safes) { $resp.Safes } else { @() }

        if ($batch.Count -gt 0) {
            foreach ($safe in $batch) {
                $safeName = if ($safe.safeName) { $safe.safeName } else { $safe.SafeName }
                if (-not $safeName) { continue }
                
                # Check exclusions
                if ($excludeSet.Contains($safeName)) { continue }

                $allSafes.Add([PSCustomObject]@{
                    SafeName     = $safeName
                    Description  = $safe.description
                })
            }
            Write-Log -Message "Safes fetched so far: $($offset + $batch.Count)..." -ScriptName $ScriptName -LogPath $LogPath
            if ($batch.Count -lt $limit) { $hasMore = $false } else { $offset += $limit }
        }
        else { $hasMore = $false }
    }

    Write-Progress -Id 40 -Activity "CyberArk Safes" -Completed
    Write-Log -Message "Total analyzed safes (after exclusions): $($allSafes.Count)" -ScriptName $ScriptName -LogPath $LogPath

    $allSafes | Export-CsvNoBom -Path $CachePath
    Write-Log -Message "Analyzed safes cached: $CachePath" -ScriptName $ScriptName -LogPath $LogPath

    return $allSafes.ToArray()
}

# ---------------------------------------------------------------------------
# Get-SAFESafeMembers
# Fetches all members and their permissions for a specific safe.
# ---------------------------------------------------------------------------
function Get-SAFESafeMembers {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $SafeName,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    $members = [System.Collections.Generic.List[object]]::new()
    
    # URL encode the safe name
    $encodedSafeName = [System.Uri]::EscapeDataString($SafeName)
    $uri = "$BaseUrl/PasswordVault/api/Safes/$encodedSafeName/Members"
    
    try {
        $resp = Invoke-CyberArkApi -Uri $uri -TimeoutSec 60
        $memberList = if ($resp.value) { $resp.value } else { @() }

        foreach ($m in $memberList) {
            $perms = $m.permissions
            
            # Convert permissions object to an array of granted permission strings
            $grantedPerms = [System.Collections.Generic.List[string]]::new()
            if ($perms) {
                foreach ($prop in $perms.PSObject.Properties) {
                    if ($prop.Value -eq $true) {
                        $grantedPerms.Add($prop.Name)
                    }
                }
            }

            $members.Add([PSCustomObject]@{
                MemberName  = $m.memberName
                MemberType  = $m.memberType
                Permissions = $grantedPerms.ToArray()
            })
        }
    }
    catch {
        Write-Log -Message "Failed to fetch members for safe '$SafeName': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $members.ToArray()
}
