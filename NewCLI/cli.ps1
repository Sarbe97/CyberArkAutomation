Clear-Host

# ============================================================================
# CyberArk CLI - NewCLI Edition
# Pure REST API implementation (no psPAS dependency)
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
        "APIClient.psm1",
        "SAMLHelper.psm1",
        "Login.psm1",
        "Accounts.psm1",
        "SystemHealth.psm1",
        "Users.psm1",
        "Safes.psm1",
        "Session.psm1"
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
        Write-Host "=========== CyberArk CLI (NewCLI) ===========" -ForegroundColor Cyan
        Write-Host "Pure REST API - No psPAS Dependency" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "1. Login (Standard)"
        Write-Host "2. Login (SAML)"
        Write-Host "3. Reload Modules (Dev Only)"
        Write-Host "0. Exit"
        Write-Host "============================================="

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
                if (Invoke-CACLogin -SAML) {
                    $Script:IsLoggedIn = $true
                    return
                }
                else {
                    Write-Host "SAML Login failed. Try again." -ForegroundColor Red
                    Pause
                }
            }

            '3' {
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
        Write-Host "=========== CyberArk CLI (NewCLI) ===========" -ForegroundColor Cyan
        Show-CACSessionHeader
        Write-Host ""
        Write-Host "1. Account Operations"
        Write-Host "2. Safe Operations"
        Write-Host "3. System Health"
        Write-Host "4. User Utilities"
        Write-Host "5. Session Info"
        Write-Host "9. Logout"
        Write-Host "0. Exit"
        Write-Host "============================================="

        $choice = Read-Host "Select an option"

        switch ($choice) {
            '1' { Show-AccountMenu }
            '2' { Show-SafeMenu }
            '3' { Show-SystemHealthMenu }
            '4' { Show-UserMenu }
            '5' { Show-SessionMenu }

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
# ACCOUNT MENU
# ============================================================
function Show-AccountMenu {
    while ($true) {
        Clear-Host
        Show-CACSessionHeader
        Write-Host "=========== ACCOUNT MENU ===========" -ForegroundColor Cyan
        Write-Host "1. Search Accounts (Keyword or Safe)"
        Write-Host "2. Get Account Details by ID"
        Write-Host "3. View Account Activity by ID"
        Write-Host "4. Reconcile Account"
        Write-Host "5. Change Password (CPM)"
        Write-Host "6. Verify Password (CPM)"
        Write-Host "7. Add New Account"
        Write-Host "8. Delete Account"
        Write-Host "9. Batch Delete Accounts"
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
        Show-CACSessionHeader
        Write-Host "=========== SYSTEM HEALTH MENU ===========" -ForegroundColor Cyan
        Write-Host "1. System Health Summary"
        Write-Host "0. Back"
        Write-Host "==========================================="

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
        Show-CACSessionHeader
        Write-Host "=========== USER UTILITIES MENU ===========" -ForegroundColor Cyan
        Write-Host "1. Get All Groups (Vault + LDAP)"
        Write-Host "2. Get Group Members"
        Write-Host "0. Back"
        Write-Host "============================================"

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Get-CACAllGroups; Pause }
            '2' { Get-CACGroupMembers; Pause }
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
        Show-CACSessionHeader
        Write-Host "=========== SAFE OPERATIONS MENU ===========" -ForegroundColor Cyan
        Write-Host "1. Export All Safes to CSV"
        Write-Host "2. Search Safe By Name"
        Write-Host "3. Get Safe Details"
        Write-Host "4. Create New Safe"
        Write-Host "5. Get Safe Members"
        Write-Host "6. Add Safe Member"
        Write-Host "7. Safe Account Counts"
        Write-Host "8. Export Safe Members Report"
        Write-Host "0. Back"
        Write-Host "============================================="

        $choice = Read-Host "Enter Choice"

        switch ($choice) {
            '1' { Export-CACAllSafes; Pause }
            '2' { Search-CACSafeByName; Pause }
            '3' { Get-CACSafeDetails; Pause }
            '4' { New-CACSafe; Pause }
            '5' { Get-CACSafeMembers; Pause }
            '6' { Add-CACSafeMember; Pause }
            '7' { Export-CACSafeAccountCounts; Pause }
            '8' { Export-CACSafeMembersReport; Pause }
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
        Show-CACSessionHeader
        Write-Host "=========== SESSION INFO MENU ===========" -ForegroundColor Cyan
        Write-Host "1. View Current User Details"
        Write-Host "2. View Session Info"
        Write-Host "0. Back"
        Write-Host "=========================================="

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
# START THE APPLICATION
# ============================================================
Show-LoginMenu
Show-MainMenu
