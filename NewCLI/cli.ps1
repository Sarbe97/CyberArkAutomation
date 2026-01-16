Clear-Host

# ============================================================================
# CyberArk CLI - NewCLI Edition
# ============================================================================

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
        "SAMLHelper.psm1",
        "Login.psm1",
        "Accounts.psm1",
        "SystemHealth.psm1",
        "Users.psm1",
        "Safes.psm1",
        "Session.psm1",
        "SafeActions.psm1",
        "DiscoveryAndOnboarding.psm1",
        "Platforms.psm1",
        "Applications.psm1"
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

    # Dot-source LoginForm.ps1
    $loginFormPath = Join-Path "$PSScriptRoot/Modules" "LoginForm.ps1"
    if (Test-Path $loginFormPath) {
        . $loginFormPath
        Write-Host "Loaded: LoginForm.ps1" -ForegroundColor Green
    }

    Write-Host "`n==============================================" -ForegroundColor DarkGray
    Write-Host "Exported Functions per Module" -ForegroundColor Cyan
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

# Initialize logging
Initialize-CACLogging

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
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Login"
        Write-Host "2. Reload Modules (Dev Only)"
        Write-Host "0. Exit"
        Write-Host "============================================="

        $choice = Read-Host "Enter choice"

        switch ($choice) {
            '1' {
                Write-Host ""
                Write-Host "Select Login Mode:" -ForegroundColor Cyan
                Write-Host "  1. CyberArk (Username/Password)"
                Write-Host "  2. SAML (SSO)"
                $loginMode = Read-Host "Enter mode (1/2)"

                $loginSuccess = $false
                if ($loginMode -eq '2') {
                    $loginSuccess = Invoke-CACLogin -SAML
                }
                else {
                    $loginSuccess = Invoke-CACLogin
                }

                if ($loginSuccess) {
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
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- MAIN MENU ---" -ForegroundColor Yellow
        Write-Host "1. Session Info"
        Write-Host "2. User Utilities"
        Write-Host "3. System Health"
        Write-Host "4. Account Operations"
        Write-Host "5. Safe Operations"
        Write-Host "6. Safe Activities"
        Write-Host "7. Platform Management"
        Write-Host "8. Discovery & Onboarding"
        Write-Host "9. Application Management"
        Write-Host "10. Logout"
        Write-Host "0. Exit"

        $choice = Read-Host "Select an option"

        switch ($choice) {
            '1' { Show-SessionMenu }
            '2' { Show-UserMenu }
            '3' { Show-SystemHealthMenu }
            '4' { Show-AccountMenu }
            '5' { Show-SafeMenu }
            '6' { Show-SafeActivitiesMenu }
            '7' { Show-PlatformMenu }
            '8' { Show-DiscoveryMenu }
            '9' { Show-ApplicationMenu }

            '10' {
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
# ACCOUNT MENU
# ============================================================
function Show-AccountMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- ACCOUNT MENU ---" -ForegroundColor Yellow
        Write-Host "1. Search Accounts (Keyword or Safe)"
        Write-Host "2. Get Account Details by ID"
        Write-Host "3. View Account Activity by ID"
        Write-Host "4. Reconcile Account"
        Write-Host "5. Change Password (CPM)"
        Write-Host "6. Verify Password (CPM)"
        Write-Host "7. Add New Account"
        Write-Host "8. Delete Account"
        Write-Host "9. Batch Delete Accounts"
        Write-Host "10. Connect via PSM"
        Write-Host "0. Back"
        Write-Host "===================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAccounts; Pause }
            '2' { Get-CACAccountById; Pause }
            '3' { Get-CACAccountActivity; Pause }
            '4' { Invoke-CACAccountReconcile; Pause }
            '5' { Invoke-CACAccountChange; Pause }
            '6' { Invoke-CACAccountVerify; Pause }
            '7' { New-CACAccount; Pause }
            '8' { Remove-CACAccount; Pause }
            '9' { Invoke-CACBatchAccountDeletion; Pause }
            '10' { Invoke-CACPSMConnect; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
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
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- SYSTEM HEALTH ---" -ForegroundColor Yellow
        Write-Host "1. System Health Summary"
        Write-Host "0. Back"

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
# USER UTILITIES MENU
# ============================================================
function Show-UserMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- USER UTILITIES ---" -ForegroundColor Yellow
        Write-Host "1. Get All Groups (Vault + LDAP)"
        Write-Host "2. Get Group Members"
        Write-Host "3. Refresh User Cache"
        Write-Host "4. Lookup User (from Cache)"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAllGroups; Pause }
            '2' { Get-CACGroupMembers; Pause }
            '3' { New-CACUserStore; Pause }
            '4' {
                $user = Read-Host "Enter Username or ID"
                if (-not [string]::IsNullOrWhiteSpace($user)) {
                    $result = Get-CACUserDetailsFromStore -InputValue $user
                    $result | Format-List
                }
                Pause
            }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# SAFE OPERATIONS MENU
# ============================================================
function Show-SafeMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- SAFE OPERATIONS ---" -ForegroundColor Yellow
        Write-Host "1. Export All Safes to CSV"
        Write-Host "2. Search Safe By Name"
        Write-Host "3. Get Safe Details"
        Write-Host "4. Create New Safe"
        Write-Host "5. Get Safe Members"
        Write-Host "6. Add Safe Member"
        Write-Host "7. Safe Account Counts"
        Write-Host "8. Consolidated Safe Report"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Export-CACAllSafes; Pause }
            '2' { Search-CACSafeByName; Pause }
            '3' { Get-CACSafeDetails; Pause }
            '4' { New-CACSafe; Pause }
            '5' { Get-CACSafeMembers; Pause }
            '6' { Add-CACSafeMember; Pause }
            '7' { Export-CACSafeAccountCounts; Pause }
            '8' { Export-CACConsolidatedReport; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# SESSION INFO MENU
# ============================================================
function Show-SessionMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- SESSION INFO ---" -ForegroundColor Yellow
        Write-Host "1. View Current User Details"
        Write-Host "2. View Session Info"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACCurrentUser; Pause }
            '2' { Get-CACSessionInfo; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# SAFE ACTIVITIES MENU
# ============================================================
function Show-SafeActivitiesMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- SAFE ACTIVITIES ---" -ForegroundColor Yellow
        Write-Host "1. Create Safes (from CSV)"
        Write-Host "2. Rename Safes (from CSV)"
        Write-Host "3. Download 'Create Safe' Template"
        Write-Host "4. Download 'Rename Safe' Template"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Invoke-CACBatchSafeCreation; Pause }
            '2' { Invoke-CACBatchSafeRename; Pause }
            '3' { New-CACSafeCreationTemplate; Pause }
            '4' { New-CACSafeRenameTemplate; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# DISCOVERY & ONBOARDING MENU
# ============================================================
function Show-DiscoveryMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- DISCOVERY & ONBOARDING ---" -ForegroundColor Yellow
        Write-Host "1. Search Discovered Accounts"
        Write-Host "2. Get Discovered Account Details"
        Write-Host "3. View All Onboarding Rules"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACDiscoveredAccounts; Pause }
            '2' { Get-CACDiscoveredAccountDetails; Pause }
            '3' { Get-CACOnboardingRules; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# PLATFORM MANAGEMENT MENU
# ============================================================
function Show-PlatformMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- PLATFORM MANAGEMENT ---" -ForegroundColor Yellow
        Write-Host "1. View All Platforms"
        Write-Host "2. Get Platform Details"
        Write-Host "3. Search Platforms"
        Write-Host "4. Export Platform Package (ZIP)"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAllPlatforms; Pause }
            '2' { Get-CACPlatformDetails; Pause }
            '3' { Search-CACPlatform; Pause }
            '4' { Export-CACPlatform; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# APPLICATION MANAGEMENT MENU
# ============================================================
function Show-ApplicationMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- APPLICATION MANAGEMENT ---" -ForegroundColor Yellow
        Write-Host "1. View All Applications"
        Write-Host "2. Get Application Details"
        Write-Host "3. View Application Auth Methods"
        Write-Host "4. Search Applications"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAllApplications; Pause }
            '2' { Get-CACApplicationDetails; Pause }
            '3' { Get-CACAppAuthMethods; Pause }
            '4' { Search-CACApplications; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
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
