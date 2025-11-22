Clear-Host
Set-StrictMode -Version Latest

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "        CyberArkToolkit - CLI Launcher         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------
# STEP 1 — psPAS dependency check (NO RED ERROR)
# ---------------------------------------------------------
 
if (-not (Get-Module -ListAvailable -Name psPAS)) {
    
    Write-Host "CyberArkToolkit cannot run - required module missing." -ForegroundColor Cyan
    Write-Host "Missing dependency: psPAS"
    Write-Host ""
    Write-Host "Install it using:" -ForegroundColor Yellow
    Write-Host "  Install-Module psPAS -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to exit"
    return
}

# Safe import
Import-Module psPAS -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# STEP 2 — Load CyberArkToolkit module
# ---------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModuleFile = Join-Path $ScriptRoot "CyberArkToolkit.psm1"

if (-not (Test-Path $ModuleFile)) {
    Write-Host "❌ Cannot find CyberArkToolkit.psm1 in: $ScriptRoot" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    return
}

Import-Module $ModuleFile -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "CyberArkToolkit module loaded successfully." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------
# STEP 3 — Initialize global session variable
# ---------------------------------------------------------

$Global:CATKSession = $null

# ---------------------------------------------------------
# STEP 4 — Try connecting
# ---------------------------------------------------------

$Global:CATKSession = Connect-CATK

if (-not $Global:CATKSession -or -not $Global:CATKSession.Session) {
    Write-Host ""
    Write-Host "⚠️ CyberArk session NOT established." -ForegroundColor Yellow
    Write-Host "Some features will not work until login succeeds."
    Write-Host ""
}
else {
    Initialize-CATKUserCache -Session $Global:CATKSession -ForceIfMissing
}

# ---------------------------------------------------------
# MENU UI
# ---------------------------------------------------------

function Show-MainMenu {
    Clear-Host
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "       CYBERARK AUTOMATION CLI        " -ForegroundColor Cyan
    Write-Host "=====================================`n" -ForegroundColor Cyan

    Write-Host "1) Safe Management"
    Write-Host "2) Account Management"
    Write-Host "3) User Management"
    Write-Host "4) PSM Recordings"
    Write-Host "5) Refresh User Cache"
    Write-Host "6) Logout & Exit"
    Write-Host ""
}

# ---------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------

try {
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "Enter choice (1-6)"

        switch ($choice) {

            '1' {
                if ($Global:CATKSession.Session) {
                    Show-CATKSafeMenu -Session $Global:CATKSession
                }
                else { Write-Host "Not connected." -ForegroundColor Yellow }
            }

            '2' {
                if ($Global:CATKSession.Session) {
                    Show-CATKAccountMenu -Session $Global:CATKSession
                }
                else { Write-Host "Not connected." -ForegroundColor Yellow }
            }

            '3' {
                if ($Global:CATKSession.Session) {
                    Show-CATKUserMenu -Session $Global:CATKSession
                }
                else { Write-Host "Not connected." -ForegroundColor Yellow }
            }

            '4' {
                if ($Global:CATKSession.Session) {
                    Show-CATKPSMMenu -Session $Global:CATKSession
                }
                else { Write-Host "Not connected." -ForegroundColor Yellow }
            }

            '5' {
                if ($Global:CATKSession.Session) {
                    Initialize-CATKUserCache -Session $Global:CATKSession -ForceRefresh
                }
                else { Write-Host "Not connected." -ForegroundColor Yellow }
            }

            '6' { break }

            default {
                Write-Host "Invalid choice." -ForegroundColor Yellow
            }
        }

        if ($choice -ne '6') {
            Write-Host ""
            Read-Host "Press Enter to continue..."
        }
    }
}
finally {
    Write-Host ""
    Write-Host "Closing CyberArk session..." -ForegroundColor Yellow

    if ($Global:CATKSession -and $Global:CATKSession.Session) {
        Disconnect-CATK -Session $Global:CATKSession
    }

    Write-Host "Goodbye!" -ForegroundColor Green
}
