Clear-Host

# ------------------------------------------------------------
# Load psPAS module (installed system-wide)
# ------------------------------------------------------------
Import-Module psPAS -ErrorAction Stop

# ------------------------------------------------------------
# Module folder
# ------------------------------------------------------------
$modulePath = Join-Path $PSScriptRoot "Modules"
Write-Host "Module Path: $modulePath"

# ------------------------------------------------------------
# Function to reload all modules (Hot-Reload)
# ------------------------------------------------------------
function Reload-Modules {
    Write-Host "Reloading internal modules..." -ForegroundColor Cyan

    # Get all .psm1 files in Modules folder
    $psm1Files = Get-ChildItem -Path $modulePath -Filter *.psm1

    foreach ($file in $psm1Files) {
        $modName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        # Remove module if already loaded
        Remove-Module $modName -ErrorAction SilentlyContinue
        # Import module
        Import-Module $file.FullName -Force
        Write-Host "Reloaded module: $modName"
    }

    # Dot-source any standalone scripts (.ps1)
    $ps1Files = Get-ChildItem -Path $modulePath -Filter *.ps1
    foreach ($file in $ps1Files) {
        . $file.FullName
        Write-Host "Dot-sourced script: $($file.Name)"
    }

    Write-Host "All modules reloaded successfully." -ForegroundColor Green
}

# Initial load
Reload-Modules

# ------------------------------------------------------------
# Global login state
# ------------------------------------------------------------
$Script:IsLoggedIn = $false

# ============================================================
# LOGIN SCREEN
# ============================================================
function Show-LoginMenu {
    while (-not $Script:IsLoggedIn) {

        Clear-Host
        Write-Host "=========== CyberArk CLI ===========" -ForegroundColor Cyan
        Write-Host "1. Login"
        Write-Host "2. Reload Modules (Dev Only)"
        Write-Host "0. Exit"
        Write-Host "===================================="

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                if (Invoke-CACLogin) {
                    $Script:IsLoggedIn = $true
                    return
                }
                else {
                    Write-Host "Login failed. Try again." -ForegroundColor Red
                    Pause
                }
            }

            '2' {
                Reload-Modules
                Pause
            }

            '0' { exit }

            default {
                Write-Host "Invalid selection" -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# MAIN MENU
# ============================================================
function Show-MainMenu {
    while ($true) {

        if (-not $Script:IsLoggedIn) {
            Show-LoginMenu
        }

        Clear-Host
        Write-Host "=========== CyberArk CLI ===========" -ForegroundColor Cyan
        Write-Host "1. Safe Operations"
        Write-Host "2. User Utilities"
        Write-Host "3. Onboarding"
        Write-Host "4. Monitor PSM Recordings"
        Write-Host "5. Reports"
        Write-Host "9. Logout"
        Write-Host "0. Exit"
        Write-Host "===================================="

        $choice = Read-Host "Select an option"

        switch ($choice) {

            '1' { Show-SafeMenu }
            '2' { Show-UserMenu }
            '3' { Show-OnboardingMenu }
            '4' { Show-MonitorMenu }
            '5' { Show-ReportMenu }

            '9' {
                Invoke-CACLogout
                $Script:IsLoggedIn = $false
                Pause
                Show-LoginMenu
            }

            '0' { Invoke-CACLogout; exit }

            default { 
                Write-Host "Invalid option!" -ForegroundColor Yellow 
                Pause
            }
        }
    }
}

# ============================================================
# SAFE MENU
# ============================================================
function Show-SafeMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== SAFE MENU ==========="
        Write-Host "1. Export All Safes to CSV"
        Write-Host "2. Export Safe Members With Permissions"
        Write-Host "3. View Safe Members (No Permissions)"
        Write-Host "4. Search A Safe By Name"
        Write-Host "5. Create Safe(s)"
        Write-Host "6. Add Safe Member(s)"
        Write-Host "0. Back"
        Write-Host "================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            1 { Export-CACAllSafes; Pause }
            2 { Export-CACSafeMembers; Pause }
            3 { Export-CACSafeUsers; Pause }
            4 { Search-CACSafeByName; Pause }
            5 { New-CACSafe; Pause }
            6 { Add-CACSafeMember; Pause }
            0 { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# USER MENU
# ============================================================
function Show-UserMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== USER MENU ===========" -ForegroundColor Cyan
        Write-Host "1. Refresh User Cache"
        Write-Host "2. Search User (Name or ID)"
        Write-Host "3. Get Users in a Group"
        Write-Host "0. Back"
        Write-Host "================================="

        $choice = Read-Host "Enter your choice"

        switch ($choice) {

            1 { Initialize-CACUserStore; Pause }
            2 {
                $val = Read-Host "Enter Username OR User ID"
                Get-UserDetailsFromStore -InputValue $val
                Pause
            }
            3 {
                $grp = Read-Host "Enter Group Name"
                Get-CACGroupUsers -GroupName $grp | Format-Table
                Pause
            }
            0 { return }
            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# ONBOARDING MENU
# ============================================================
function Show-OnboardingMenu {
    while ($true) {
        Clear-Host
        Write-Host "==== Onboarding Menu ====" -ForegroundColor Cyan
        Write-Host "1. Start Onboarding Workflow"
        Write-Host "0. Back"

        $choice = Read-Host "Select option"

        switch ($choice) {
            '1' {
                $safe = Read-Host "Safe Name"
                $user = Read-Host "Account Name"
                Start-CACOnboarding -SafeName $safe -AccountUser $user
                Pause
            }
            '0' { return }
            default { 
                Write-Host "Invalid option!" -ForegroundColor Yellow 
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# MONITOR MENU
# ============================================================
function Show-MonitorMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== MONITOR MENU ==========="
        Write-Host "1. Fetch PSM Recordings"
        Write-Host "0. Back"
        Write-Host "==================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACPSMRecordings; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# REPORT MENU
# ============================================================
function Show-ReportMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== REPORT MENU ==========="
        Write-Host "1. User License Report"
        Write-Host "2. Get Report (by ID)"
        Write-Host "3. Get Report Schedules"
        Write-Host "4. Create New Report Schedule"
        Write-Host "5. Export Report"
        Write-Host "0. Back"
        Write-Host "==================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACUserLicenseReport; Pause }
            '2' { Get-CACReport; Pause }
            '3' { Get-CACReportSchedule; Pause }
            '4' { New-CACReportSchedule; Pause }
            '5' { Export-CACReport; Pause }
            '0' { return }

            default {
                Write-Host "Invalid selection." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# START THE APPLICATION
# ============================================================
Show-LoginMenu
Show-MainMenu
