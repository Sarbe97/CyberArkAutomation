Clear-Host

# ============================================================================
# CyberArk CLI
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
        "UserManagement.psm1",
        "SafeOperations.psm1",
        "Session.psm1",
        "SafeActions.psm1",
        "DiscoveryAndOnboarding.psm1",
        "Platforms.psm1",
        "Applications.psm1",
        "SecondaryAccountOnboarding.psm1"
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

# Validate Configuration
if (-not (Test-CACConfiguration)) {
    Write-Host "`n[!] Configuration errors detected." -ForegroundColor Red
    Write-Host "    Please check config.json."
    Pause
    # We don't exit here to allow user to potentially fix it or reload, 
    # but strictly speaking we could exit.
}

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
                Write-Host "  2. LDAP (Domain Credentials)"
                Write-Host "  3. SAML (SSO)"
                Write-Host "  4. CCP (Central Credential Provider)"
                $loginMode = Read-Host "Enter mode (1/2/3/4)"

                $loginSuccess = $false
                switch ($loginMode) {
                    '2' { $loginSuccess = Invoke-CACLogin -LDAP }
                    '3' { $loginSuccess = Invoke-CACLogin -SAML }
                    '4' { $loginSuccess = Invoke-CACLogin -CCP }
                    default { $loginSuccess = Invoke-CACLogin }
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
        Write-Host "2. System Health"
        Write-Host "3. User Operations"
        Write-Host "4. User & Group Management"
        Write-Host "5. Account Operations"
        Write-Host "6. Safe Operations"
        Write-Host "7. Safe Bulk Activities"
        Write-Host "8. Platform Management"
        Write-Host "9. Discovery & Onboarding"
        Write-Host "10. Application Management"
        Write-Host "R. Reload Modules (Dev Only)" -ForegroundColor DarkGray
        Write-Host "0. Exit"

        $choice = Read-Host "Select an option"

        switch ($choice) {
            '1' { Show-CACSessionDetails; Pause }
            '2' { Get-CACSystemHealth; Pause }
            '3' { Show-UserMenu }
            '4' { Show-UserManagementMenu }
            '5' { Show-AccountMenu }
            '6' { Show-SafeMenu }
            '7' { Show-SafeActivitiesMenu }
            '8' { Show-PlatformMenu }
            '9' { Show-DiscoveryMenu }
            '10' { Show-ApplicationMenu }

            'R' { 
                Reload-CACModules
                Write-Host ""
                Write-Host "Session preserved. You are still logged in." -ForegroundColor Green
                Pause
            }

            '0' {
                Invoke-CACLogout
                $Script:IsLoggedIn = $false
                Pause
                Show-LoginMenu
            }

            #'0' { Invoke-CACLogout; exit }

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
        Write-Host "2. Get Failed Accounts (PolicyFailures)"
        Write-Host "3. Get Account Details by ID"
        Write-Host "4. View Account Activity by ID"
        Write-Host "5. Reconcile Account"
        Write-Host "6. Change Password (CPM)"
        Write-Host "7. Verify Password (CPM)"
        Write-Host "8. Add New Account"
        Write-Host "9. Delete Account"
        Write-Host "10. Batch Delete Accounts"
        Write-Host "11. Connect via PSM"
        Write-Host "12. Batch Onboard Accounts (CSV)"
        Write-Host "13. Secondary Account Onboarding (with Email)"
        Write-Host "0. Back"
        Write-Host "===================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAccounts; Pause }
            '2' { Get-CACAccounts -FailedAccounts; Pause }
            '3' { Get-CACAccountById; Pause }
            '4' { Get-CACAccountActivity; Pause }
            '5' { Invoke-CACAccountReconcile; Pause }
            '6' { Invoke-CACAccountChange; Pause }
            '7' { Invoke-CACAccountVerify; Pause }
            '8' { New-CACAccount; Pause }
            '9' { Remove-CACAccount; Pause }
            '10' { Invoke-CACBatchAccountDeletion; Pause }
            '11' { Invoke-CACPSMConnect; Pause }
            '12' { Invoke-CACBatchAccountOnboarding; Pause }
            '13' { Invoke-CACSecondaryAccountOnboarding; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}



# ============================================================
# USER OPERATIONS MENU
# ============================================================
function Show-UserMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- USER OPERATIONS ---" -ForegroundColor Yellow
        Write-Host "1. Refresh User Cache"
        Write-Host "2. Lookup User (from Cache)"
        Write-Host "3. Get All Groups (Vault + LDAP)"
        Write-Host "4. Get Members of a Group"
        Write-Host "5. Get Groups of a User"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { New-CACUserStore; Pause }
            '2' { Invoke-CACUserLookup; Pause }
            '3' { Get-CACAllGroups; Pause }
            '4' { Invoke-CACGroupMembersLookup; Pause }
            '5' { Get-CACGroupsOfUser; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}

# ============================================================
# GROUP & USER MANAGEMENT MENU
# ============================================================
function Show-UserManagementMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- GROUP & USER MANAGEMENT ---" -ForegroundColor Yellow
        Write-Host "1. Create Groups (Manual or CSV)"
        Write-Host "2. Add Users to Group (Manual or CSV)"
        Write-Host "3. Delete Groups (Manual or CSV)"
        Write-Host "4. Reset User Password"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Invoke-CACBatchGroupCreation; Pause }
            '2' { Invoke-CACBatchAddUsersToGroup; Pause }
            '3' { Invoke-CACGroupDeletion; Pause }
            '4' { Reset-CACUserPassword; Pause }
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
        Write-Host "2. Safe Account Counts"
        Write-Host "3. Consolidated Safe Report"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Export-CACAllSafes; Pause }
            '2' { Export-CACSafeAccountCounts; Pause }
            '3' { Export-CACConsolidatedReport; Pause }
            '0' { return }

            default {
                Write-Host "Invalid option." -ForegroundColor Yellow
                Start-Sleep 1
            }
        }
    }
}



# ============================================================
# SAFE BULK ACTIVITIES MENU
# ============================================================
function Show-SafeActivitiesMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============== CyberArk CLI ===============" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host "============================================="
        Write-Host ""
        Write-Host "--- SAFE BULK ACTIVITIES ---" -ForegroundColor Yellow
        Write-Host "1. Create Safes (from CSV)"
        Write-Host "2. Rename Safes (from CSV)"
        Write-Host "3. Manage Safe Members (from CSV)"
        Write-Host "4. Delete Safes (Batch)"
        Write-Host "---" -ForegroundColor DarkGray
        Write-Host "5. Download 'Create Safe' Template"
        Write-Host "6. Download 'Rename Safe' Template"
        Write-Host "7. Download 'Safe Member' Template"
        Write-Host "8. Download 'Delete Safe' Template"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Invoke-CACBatchSafeCreation; Pause }
            '2' { Invoke-CACBatchSafeRename; Pause }
            '3' { Invoke-CACBatchSafeMember; Pause }
            '4' { Invoke-CACBatchSafeDelete; Pause }
            '5' { New-CACSafeCreationTemplate; Pause }
            '6' { New-CACSafeRenameTemplate; Pause }
            '7' { New-CACSafeMemberTemplate; Pause }
            '8' { New-CACSafeDeleteTemplate; Pause }
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
        Write-Host "1. Search Discovered Accounts (with full details)"
        Write-Host "2. View All Onboarding Rules"
        Write-Host "3. Delete Discovered Accounts"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACDiscoveredAccounts; Pause }
            '2' { Get-CACOnboardingRules; Pause }
            '3' { Remove-CACDiscoveredAccounts; Pause }
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
        Write-Host "1. View All Platforms (with full details)"
        Write-Host "2. Export Platform Package (ZIP)"
        Write-Host "0. Back"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAllPlatforms; Pause }
            '2' { Export-CACPlatform; Pause }
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
