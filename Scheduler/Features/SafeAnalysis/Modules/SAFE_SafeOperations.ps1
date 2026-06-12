# =============================================================================
# SAFE_SafeOperations.ps1
# Manages safe permissions updates for remediation in SafeAnalysis.
# =============================================================================

# ---------------------------------------------------------------------------
# Invoke-SAFEUpdateSafeMember
# Adds or updates a safe member with the provided permissions.
# ---------------------------------------------------------------------------
function Invoke-SAFEUpdateSafeMember {
    param (
        [Parameter(Mandatory=$true)] [string] $BaseUrl,
        [Parameter(Mandatory=$true)] [string] $SafeName,
        [Parameter(Mandatory=$true)] [string] $MemberName,
        [Parameter(Mandatory=$true)] [string] $MemberType,
        [Parameter(Mandatory=$true)] [string] $MemberSource,
        [Parameter(Mandatory=$true)] [array]  $Permissions,
        [Parameter(Mandatory=$true)] [bool]   $IsUpdate,
        [Parameter(Mandatory=$true)] [bool]   $SimulationMode,
        [Parameter(Mandatory=$true)] [string] $ScriptName,
        [Parameter(Mandatory=$true)] [string] $LogPath
    )

    $result = [PSCustomObject]@{
        Success = $true
        Error   = ""
    }

    # Build the permissions object mapping the required boolean flags
    $permObj = @{}
    
    # Initialize all known permission properties to false to be safe, 
    # but the API allows just sending the ones we want to be true.
    # To be explicit, we set the requested ones to true.
    foreach ($p in $Permissions) {
        $permObj[$p] = $true
    }

    $body = @{
        memberName  = $MemberName
        memberType  = $MemberType
        searchIn    = if ($MemberSource -eq "Domain") { "Domain" } else { "Vault" }
        permissions = $permObj
    }

    $encodedSafeName = [System.Uri]::EscapeDataString($SafeName)
    $encodedMemberName = [System.Uri]::EscapeDataString($MemberName)

    if ($IsUpdate) {
        $uri = "$BaseUrl/PasswordVault/api/Safes/$encodedSafeName/Members/$encodedMemberName"
        $method = "PUT"
        $action = "Updating"
    } else {
        $uri = "$BaseUrl/PasswordVault/api/Safes/$encodedSafeName/Members"
        $method = "POST"
        $action = "Adding"
    }

    if ($SimulationMode) {
        Write-Log -Message "[SIMULATION] Would be $action member '$MemberName' to safe '$SafeName' with permissions: $($Permissions -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
        return $result
    }

    Write-Log -Message "$action member '$MemberName' to safe '$SafeName'..." -ScriptName $ScriptName -LogPath $LogPath
    
    try {
        $jsonBody = $body | ConvertTo-Json -Depth 5
        $resp = Invoke-CyberArkApi -Uri $uri -Method $method -Body $jsonBody
        Write-Log -Message "Successfully completed $action member '$MemberName' for safe '$SafeName'." -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        $result.Success = $false
        $result.Error   = $_.Exception.Message
        Write-Log -Message "Failed $action member '$MemberName' for safe '$SafeName': $($result.Error)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $result
}
