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
function Reload-CACModules {
    Write-Host "==============================================" -ForegroundColor DarkGray
    Write-Host "Reloading CyberArk CLI modules..." -ForegroundColor Cyan
    Write-Host "=============================================="


    $moduleFiles = @(
        "Utils.psm1",
        "Config.psm1",
        "Models.psm1",
        "APIClient.psm1",
        "Login.psm1",
        "Users.psm1",
        "Safes.psm1",
        "Accounts.psm1",
        "SystemHealth.psm1",
        "Onboarding.psm1",
        "Monitor.psm1",
        "Reports.psm1",
        "Platforms.psm1",
        "BatchOnboarding.psm1"
    )


    $modulePaths = $moduleFiles | ForEach-Object { Join-Path "$PSScriptRoot/Modules" $_ }


    Write-Host "Unloading existing modules..." -ForegroundColor Yellow
    foreach ($path in $modulePaths) {
        $loaded = Get-Module | Where-Object { $_.Path -eq $path }
        if ($loaded) {
            Remove-Module -Name $loaded.Name -Force
            Write-Host ("Unloaded module: {0}" -f $loaded.Name) -ForegroundColor Yellow
        }
    }


    Write-Host "`nLoading modules..." -ForegroundColor Green
    foreach ($path in $modulePaths) {
        if (Test-Path $path) {
            Import-Module $path -Force
            Write-Host ("Loaded module: {0}" -f (Split-Path $path -Leaf)) -ForegroundColor Green
        }
        else {
            Write-Host ("Module not found: {0}" -f $path) -ForegroundColor Red
        }
    }


    Write-Host "`n=============================================="
    Write-Host "Exported Functions per Module"
    Write-Host "=============================================="


    foreach ($path in $modulePaths) {
        $mod = Get-Module | Where-Object { $_.Path -eq $path }
        if ($mod) {
            Write-Host "`nModule: $(Split-Path $path -Leaf)" -ForegroundColor Cyan
            $functions = $mod.ExportedFunctions.Keys | Sort-Object
            if ($functions) {
                $functions | ForEach-Object {
                    Write-Host "   $($_)" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "   (no exported functions)" -ForegroundColor DarkGray
            }
        }
    }


    Write-Host "`n=============================================="
    Write-Host "Module reload completed successfully" -ForegroundColor Green
    Write-Host "=============================================="
}


# Initial load
Reload-CACModules


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
                Reload-CACModules
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
        Write-Host "2. Account Operations"
        Write-Host "3. User Utilities"
        Write-Host "4. Onboarding"
        Write-Host "5. Monitoring"
        Write-Host "6. Reports"
        Write-Host "7. System Health"
        Write-Host "8. Platform Operations"
        Write-Host "9. Logout"
        Write-Host "0. Exit"
        Write-Host "===================================="


        $choice = Read-Host "Select an option"


        switch ($choice) {


            '1' { Show-SafeMenu }
            '2' { Show-AccountMenu }
            '3' { Show-UserMenu }
            '4' { Show-OnboardingMenu }
            '5' { Show-MonitorMenu }
            '6' { Show-ReportMenu }
            '7' { Show-SystemHealthMenu }
            '8' { Show-PlatformMenu }

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
# SYSTEM HEALTH MENU
# ============================================================
function Show-SystemHealthMenu {
    while ($true) {
        Clear-Host
        Write-Host "===== SYSTEM HEALTH MENU =====" -ForegroundColor Cyan
        Write-Host "1. System Health Summary"
        Write-Host "0. Back"
        Write-Host "=============================="


        $choice = Read-Host "Enter Choice"


        switch ($choice) {
            '1' { Get-CACSystemHealth; Pause }
            '0' { return }


            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
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
        Write-Host "3. View Safe Members With Users (No Permissions)"
        Write-Host "4. Search A Safe By Name"
        Write-Host "5. Create Safe(s)"
        Write-Host "6. Add Safe Member(s)"
        Write-Host "7. Scan Safes for Account Counts"
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
            7 { Export-CACSafeAccountCounts; Pause }
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


            1 { New-CACUserStore; Pause }
            2 {
                $val = Read-Host "Enter Username OR User ID"
                Get-CACUserDetailsFromStore -InputValue $val
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
# ACCOUNT MENU 
# ============================================================
function Show-AccountMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== ACCOUNT MENU ===========" -ForegroundColor Cyan
        Write-Host "1. Search Accounts (Keyword or Safe)"
        Write-Host "2. Get Account Details by ID"
        Write-Host "3. View Account Activity by ID"
        Write-Host "4. Reconcile Account Credentials"
        Write-Host "5. Connect via PSM"
        Write-Host "6. Create Account Template"
        Write-Host "7. Add Accounts from CSV"
        Write-Host "0. Back"
        Write-Host "===================================="


        $choice = Read-Host "Enter Choice"


        switch ($choice) {
            '1' { Get-CACAccounts; Pause }
            '2' { Get-CACAccountById; Pause }
            '3' { Get-CACAccountActivity; Pause }
            '4' { Invoke-CACAccountReconcile; Pause }
            '5' { New-CACPSMConnection; Pause }
            '6' { New-CACAccountTemplate; Pause }
            '7' { New-CACAccountsFromCsv; Pause }
            '0' { return }


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
        Write-Host "1. Start Manual Onboarding Workflow"
        Write-Host "2. Run Batch Onboarding (Safes CSV)"
        Write-Host "3. Download CSV Template"
        Write-Host "0. Back"


        $choice = Read-Host "Select option"


        switch ($choice) {
            '1' {
                $safe = Read-Host "Safe Name"
                $user = Read-Host "Account Name"
                Start-CACOnboarding -SafeName $safe -AccountUser $user
                Pause
            }
            '2' {
                $path = Read-Host "Enter full path to Onboarding CSV"
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    Invoke-CACBatchOnboarding -CsvPath $path
                }
                Pause
            }
            '3' {
                $path = Read-Host "Enter path to save template (Press Enter for current directory)"
                if ([string]::IsNullOrWhiteSpace($path)) {
                    New-CACOnboardingTemplate
                }
                else {
                    New-CACOnboardingTemplate -Path $path
                }
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
        Write-Host "2. Fetch Account Activities by Name"
        Write-Host "0. Back"
        Write-Host "==================================="


        $choice = Read-Host "Enter Choice"


        switch ($choice) {
            '1' { Get-CACPSMRecordings; Pause }
            '2' { Get-CACAccountActivityByName; Pause }
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
# PLATFORM MENU
# ============================================================
function Show-PlatformMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== PLATFORM MENU ==========="
        Write-Host "1. Export Platform Packages (ZIP)"
        Write-Host "2. Export Platform Report to CSV"
        Write-Host "0. Back"
        Write-Host "====================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Export-CACPlatform; Pause }
            '2' { Get-CACPlatformReport; Pause }
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
