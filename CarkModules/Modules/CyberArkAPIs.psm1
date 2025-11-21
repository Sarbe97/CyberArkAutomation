function Get-CyberArkPSMRecordings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [int]$FromTimeEpoch = 0,

        [int]$Limit = 25,

        [int]$Offset = 0
    )

    $uri = "$PvwaUrl/PasswordVault/API/recordings?fromTime=$FromTimeEpoch&limit=$Limit&offset=$Offset"
    $headers = @{ Authorization = $Token }

    Write-Verbose "Querying recordings from $uri ..."
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        return $response.Recordings
    }
    catch {
        throw "Failed to get recordings: $_"
    }
}


function Search-CyberArkAccounts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$SearchQuery,

        [int]$Limit = 25,

        [int]$Offset = 0
    )

    $uri = "$PvwaUrl/PasswordVault/API/Accounts?search=$SearchQuery&offset=$Offset&limit=$Limit"
    $headers = @{ Authorization = $Token }

    Write-Verbose "Searching for accounts with query '$SearchQuery' from $uri"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ContentType "application/json"
        return $response.value
    }
    catch {
        throw "Failed to search accounts: $_"
    }
}

function Get-CyberArkAccountActivities {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$AccountID
    )

    $uri = "$PvwaUrl/PasswordVault/WebServices/PIMServices.svc/Accounts/$AccountID/Activities/"
    $headers = @{ Authorization = $Token }

    Write-Verbose "Retrieving activities for AccountID $AccountID from $uri"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ContentType "application/json"
        return $response
    }
    catch {
        throw "Failed to get activities for AccountID $AccountID - $_"
    }
}

function Add-CyberArkSafe {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [Parameter(Mandatory = $true)]
        [string]$SafeName,
        [string]$Description = "Created via API",
        [string]$ManagingCPM = "passwordManager"
    )

    $uri = "$PvwaUrl/PasswordVault/API/Safes/"
    $headers = @{ Authorization = $Token }
    $body = @{
        safeName = $SafeName
        description = $Description
        managingCPM = $ManagingCPM
        numberOfDaysRetention = 7
        numberOfVersionsRetention = $null
        oLACEnabled = $false
        autoPurgeEnabled = $true
        location = ""
    } | ConvertTo-Json

    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -ContentType "application/json" -Body $body -Method Post
        return $result
    }
    catch {
        return $_.Exception.Response | ConvertFrom-Json
    }
}

function Get-CyberArkSafeDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [Parameter(Mandatory = $true)]
        [string]$SafeName
    )

    $uri = "$PvwaUrl/PasswordVault/API/Safes/$SafeName/"
    $headers = @{ Authorization = $Token }

    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -ContentType "application/json" -Method Get
        return $result
    }
    catch {
        return $_.Exception.Response | ConvertFrom-Json
    }
}

function Get-CyberArkSafeMembers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [Parameter(Mandatory = $true)]
        [string]$SafeName
    )

    $uri = "$PvwaUrl/PasswordVault/API/Safes/$SafeName/Members/"
    $headers = @{ Authorization = $Token }

    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -ContentType "application/json" -Method Get
        return $result.value
    }
    catch {
        return $_.Exception.Response | ConvertFrom-Json
    }
}


 
function Get-CyberArkUserGroupMembers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $uri = "$PvwaUrl/PasswordVault/API/UserGroups/$GroupId/"
    $headers = @{ Authorization = $Token }

    try {
        $group = Invoke-RestMethod -Uri $uri -Headers $headers -ContentType "application/json" -Method Get
        return $group.members
    }
    catch {
        return @()
    }
}

 
Export-ModuleMember -Function Search-CyberArkAccounts, Get-CyberArkAccountActivities, Add-CyberArkSafe,
 Get-CyberArkSafeDetails, Get-CyberArkSafeMembers, Get-CyberArkSafeMembersFiltered, Get-CyberArkUserGroupMembers



