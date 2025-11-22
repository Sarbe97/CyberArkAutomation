function Show-CATKPSMMenu {
    <#
    .SYNOPSIS
        Interactive menu for PSM recordings.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session
    )

    while ($true) {
        Clear-Host
        Write-Host "==== PSM RECORDINGS ====" -ForegroundColor Cyan
        Write-Host "1) Pull PSM Recordings"
        Write-Host "2) Back"
        Write-Host ""

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                $days = Read-Host "Days (default 7)"
                if (-not $days) { $days = 7 }

                $records = Invoke-CATKPSMRecordings -Session $Session -LastDays $days
                $records | Format-Table -AutoSize

                $save = Read-Host "Save to CSV? (Y/N)"
                if ($save -match '^[Yy]') {
                    $name = "PSM_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
                    $records | Export-Csv $name -NoTypeInformation -Encoding UTF8
                    Write-Host "Saved -> $name" -ForegroundColor Green
                }
            }

            '2' { return }

            default { Write-Warning "Invalid choice." }
        }

        Read-Host "Press Enter to continue..."
    }
}
