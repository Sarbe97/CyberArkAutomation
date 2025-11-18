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
        throw "Failed to get activities for AccountID $AccountID: $_"
    }
}

Export-ModuleMember -Function Search-CyberArkAccounts, Get-CyberArkAccountActivities
