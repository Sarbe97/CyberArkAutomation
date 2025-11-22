function Show-CATKAccountMenu {
    <#
    .SYNOPSIS
        Interactive menu for Account operations.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session
    )

    while ($true) {
        Clear-Host
        Write-Host "==== ACCOUNT MANAGEMENT ====" -ForegroundColor Cyan
        Write-Host "1) Search Accounts"
        Write-Host "2) Account Activity Report"
        Write-Host "3) Back"
        Write-Host ""

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                $search = Read-Host "Search query"
                $limit  = Read-Host "Limit (default 50)"
                if (-not $limit) { $limit = 50 }
                $res = Invoke-CATKAccountSearch -Session $Session -Search $search -Limit $limit
                $res | Select-Object id, name, userName, platformId, safeName | Format-Table -AutoSize
            }

            '2' {
                $id = Read-Host "Account ID"
                $acts = Invoke-CATKAccountActivityReport -Session $Session -AccountId $id
                $acts | Format-Table -AutoSize
            }

            '3' { return }

            default { Write-Warning "Invalid choice." }
        }

        Read-Host "Press Enter to continue..."
    }
}
