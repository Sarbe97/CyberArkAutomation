function Invoke-CATKAccountActivityReport {
    <#
    .SYNOPSIS
        Retrieves CyberArk account activities.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [Parameter(Mandatory=$true)][string] $AccountId
    )

    try {
        return Get-PASAccountActivity -Session $Session.Session -AccountId $AccountId -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to get activity for account '$AccountId': $_"
        return @()
    }
}
