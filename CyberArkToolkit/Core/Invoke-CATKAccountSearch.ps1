function Invoke-CATKAccountSearch {
    <#
    .SYNOPSIS
        Searches CyberArk accounts using psPAS Get-PASAccount.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [string] $Search,
        [int] $Limit = 50
    )

    try {
        return Get-PASAccount -Session $Session.Session -Search $Search -Limit $Limit -ErrorAction Stop
    }
    catch {
        Write-Warning "Account search failed: $_"
        return @()
    }
}
