function Invoke-CATKSafeSummary {
    <#
    .SYNOPSIS
        Retrieves extended safe details.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [Parameter(Mandatory=$true)][string] $SafeName
    )

    try {
        $safe = Get-PASSafe -Session $Session.Session -SafeName $SafeName -ExtendedDetails -ErrorAction Stop
        return $safe
    }
    catch {
        Write-Warning "Failed to get Safe '$SafeName': $_"
        return $null
    }
}
