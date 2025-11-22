function Show-CATKSafeMenu {
    <#
    .SYNOPSIS
        Interactive menu for Safe operations.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session
    )

    while ($true) {
        Clear-Host
        Write-Host "==== SAFE MANAGEMENT ====" -ForegroundColor Cyan
        Write-Host "1) View Safe Summary"
        Write-Host "2) View Safe Members (Expanded + Enriched)"
        Write-Host "3) Add Safe"
        Write-Host "4) Back"
        Write-Host ""

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                $safe = Read-Host "Enter Safe name"
                $details = Invoke-CATKSafeSummary -Session $Session -SafeName $safe
                if ($details) { $details | Format-List }
            }

            '2' {
                $safe = Read-Host "Enter Safe name"
                $members = Invoke-CATKSafeMemberAnalysis -Session $Session -SafeName $safe
                $members | Format-Table -AutoSize
            }

            '3' {
                $safe = Read-Host "Safe name"
                $desc = Read-Host "Description"
                try {
                    Add-PASSafe -Session $Session.Session -SafeName $safe -Description $desc -ErrorAction Stop
                    Write-Host "Safe created." -ForegroundColor Green
                }
                catch { Write-Warning "Failed: $_" }
            }

            '4' { return }

            default {
                Write-Warning "Invalid choice."
            }
        }

        Read-Host "Press Enter to continue..."
    }
}
