function Show-CATKUserMenu {
    <#
    .SYNOPSIS
        Interactive menu for User operations.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session
    )

    while ($true) {
        Clear-Host
        Write-Host "==== USER MANAGEMENT ====" -ForegroundColor Cyan
        Write-Host "1) Search User (Cache + Fallback)"
        Write-Host "2) Refresh User Cache"
        Write-Host "3) Back"
        Write-Host ""

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                $username = Read-Host "Username"
                $cached = Get-CATKCachedUser -Username $username

                if ($cached) {
                    Write-Host "Found in cache:" -ForegroundColor Green
                    $cached | Format-List
                }
                else {
                    Write-Host "Not found in cache. Querying PVWA..." -ForegroundColor Yellow
                    try {
                        $live = Get-PASUser -Session $Session.Session -search $username -ErrorAction Stop
                        if ($live) { $live | Format-List }
                        else { Write-Warning "User not found." }
                    }
                    catch { Write-Warning "Lookup failed: $_" }
                }
            }

            '2' {
                Initialize-CATKUserCache -Session $Session -ForceRefresh
            }

            '3' { return }

            default { Write-Warning "Invalid choice." }
        }

        Read-Host "Press Enter to continue..."
    }
}
