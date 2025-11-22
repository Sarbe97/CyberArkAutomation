function Disconnect-CATK {
    <#
    .SYNOPSIS
        Closes the active CyberArk psPAS session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session
    )

    try {
        $s = $Session.Session

        if ($s) {
            Close-PASSession -Session $s -ErrorAction SilentlyContinue
            Write-Host "CyberArk session closed." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Error while closing session: $_"
    }
}
