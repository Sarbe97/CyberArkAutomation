function Connect-CATK {
    <#
    .SYNOPSIS
        Creates a CyberArk session using psPAS and returns a CATK session object.
    #>
    [CmdletBinding()]
    param(
        [string] $PvwaUrl
    )

    if (-not $PvwaUrl) {
        $PvwaUrl = Read-Host "Enter PVWA URL (e.g. https://pvwa.company.local)"
    }

    # Ask for credentials
    $cred = Get-Credential -Message "Enter CyberArk PVWA login credentials"

    try {
        $session = New-PASSession -BaseURI $PvwaUrl -Credential $cred -ErrorAction Stop

        Write-Host "Connected successfully to $PvwaUrl" -ForegroundColor Green

        return [PSCustomObject]@{
            PvwaUrl = $PvwaUrl
            Session = $session
        }
    }
    catch {
        Write-Error "Failed to establish CyberArk session: $_"
        return $null
    }
}
