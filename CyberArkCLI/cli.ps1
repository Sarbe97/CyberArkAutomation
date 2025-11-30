Clear-Host

# Load psPAS module (must be installed on system)
Import-Module psPAS -ErrorAction Stop

# Load our modules using RELATIVE paths
$modulePath = Join-Path $PSScriptRoot "Modules"
Write-Host $modulePath
Import-Module (Join-Path $modulePath "Login.psm1")     -Force
Import-Module (Join-Path $modulePath "Config.psm1")    -Force
Import-Module (Join-Path $modulePath "Safes.psm1")     -Force
Import-Module (Join-Path $modulePath "Users.psm1")     -Force
Import-Module (Join-Path $modulePath "Onboarding.psm1") -Force


function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== CyberArk CLI ===========" -ForegroundColor Cyan
        Write-Host "1. Login"
        Write-Host "2. Safe Operations"
        Write-Host "3. User Utilities"
        Write-Host "4. Onboarding"
        Write-Host "0. Exit"
        Write-Host "===================================="

        $choice = Read-Host "Select an option"

        switch ($choice) {
            '1' { Invoke-CACLogin }
            '2' { Show-SafeMenu }
            '3' { Show-UserMenu }
            '4' { Show-OnboardingMenu }
            '0' { exit }
            default { Write-Host "Invalid option!" -ForegroundColor Yellow }
        }

        Pause
    }
}


function Show-SafeMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== SAFE MENU ==========="
        Write-Host "1. Export All Safes to CSV"
        Write-Host "2. Export Safe Members"
        Write-Host "3. Create Safe(s)"
        Write-Host "4. Add Safe Member(s)"
        Write-Host "0. Back"
        Write-Host "================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {

            1 {
                Export-CACAllSafes
                Pause
            }

            2 {
                Export-CACSafeMembers
                Pause
            }

            3 {
                New-CACSafe
                Pause
            }

            4 {
                Add-CACSafeMember
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


function Show-UserMenu {
    while ($true) {
        Clear-Host
        Write-Host "=========== USER MENU ==========="
        Write-Host "1. Refresh User Cache (users.csv)"
        Write-Host "2. Export User Details (from cache)"
        Write-Host "3. Get Members of a Group"
        Write-Host "0. Back"
        Write-Host "================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {

            1 {
                Update-CACUserCache
                Pause
            }

            2 {
                Export-CACUserCache
                Pause
            }

            3 {
                $grp = Read-Host "Enter Group Name"
                Get-CACGroupMembers -GroupName $grp | Format-Table
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
            }
            '0' { return }
            default { Write-Host "Invalid option!" -ForegroundColor Yellow }
        }

        Pause
    }
}

Show-MainMenu
