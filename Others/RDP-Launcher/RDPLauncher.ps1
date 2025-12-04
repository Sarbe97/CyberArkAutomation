# RDP Launcher - Single File Version
# Inline CLI-based RDP file creator and launcher

param(
    [switch]$EditConfig = $false
)

# Configuration file path
$configPath = "$PSScriptRoot\rdp-config.json"
$defaultConfig = @{
    cyberArkUser       = ""
    connectors         = @("PSM-RDP", "PSM-SSH")
    addresses          = @()
    targetAccounts     = @()
    PSM_server_address = "PSM_Server1"
}

# ========================================
# Configuration Management
# ========================================

function Initialize-Config {
    if (-not (Test-Path $configPath)) {
        Write-Host "Creating default configuration..." -ForegroundColor Cyan
        $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content $configPath
        Write-Host "Config created: $configPath" -ForegroundColor Green
    }
}

function Load-Config {
    try {
        return Get-Content $configPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "Error loading config: $_" -ForegroundColor Red
        return $defaultConfig
    }
}

function Save-Config($config) {
    try {
        $config | ConvertTo-Json -Depth 5 | Set-Content $configPath
        Write-Host "Configuration saved" -ForegroundColor Green
    }
    catch {
        Write-Host "Error saving config: $_" -ForegroundColor Red
    }
}

# ========================================
# Interactive Input Functions
# ========================================

function Get-AddressInput($config) {
    Write-Host ""
    Write-Host "Available Addresses:" -ForegroundColor Yellow
    
    $uniqueAddresses = @($config.addresses | Sort-Object -Unique)
    
    for ($i = 0; $i -lt $uniqueAddresses.Count; $i++) {
        Write-Host "$($i + 1). $($uniqueAddresses[$i])"
    }
    Write-Host "$($uniqueAddresses.Count + 1). Enter custom address"
    
    $choice = Read-Host "Select address (1-$($uniqueAddresses.Count + 1))"
    $idx = [int]$choice - 1
    
    if ($idx -ge 0 -and $idx -lt $uniqueAddresses.Count) {
        return $uniqueAddresses[$idx]
    }
    elseif ($choice -eq $uniqueAddresses.Count + 1) {
        $customAddr = Read-Host "Enter IP/Hostname"
        
        if (-not [string]::IsNullOrWhiteSpace($customAddr)) {
            if ($customAddr -notin $config.addresses) {
                $config.addresses += $customAddr
                Save-Config $config
            }
            return $customAddr
        }
        else {
            Write-Host "Invalid input" -ForegroundColor Red
            return $null
        }
    }
    else {
        Write-Host "Invalid selection" -ForegroundColor Red
        return $null
    }
}

function Get-CyberArkUserInput($config) {
    Write-Host ""
    Write-Host "Enter CyberArk login user (default: $($config.cyberArkUser))"
    $input = Read-Host "CyberArk login user"
    
    if ([string]::IsNullOrWhiteSpace($input)) {
        if ([string]::IsNullOrWhiteSpace($config.cyberArkUser)) {
            Write-Host "CyberArk login user is required" -ForegroundColor Red
            return $null
        }
        return $config.cyberArkUser
    }
    
    $config.cyberArkUser = $input
    Save-Config $config
    return $input
}

function Get-TargetAccountInput($config) {
    Write-Host ""
    Write-Host "Saved Target Accounts:" -ForegroundColor Yellow
    
    $uniqueTargets = @($config.targetAccounts | Sort-Object -Unique)
    
    if ($uniqueTargets.Count -gt 0) {
        for ($i = 0; $i -lt $uniqueTargets.Count; $i++) {
            Write-Host "$($i + 1). $($uniqueTargets[$i])"
        }
        Write-Host "$($uniqueTargets.Count + 1). Enter custom target account"
        
        $choice = Read-Host "Select or enter target account (1-$($uniqueTargets.Count + 1))"
        $idx = [int]$choice - 1
        
        if ($idx -ge 0 -and $idx -lt $uniqueTargets.Count) {
            return $uniqueTargets[$idx]
        }
        elseif ($choice -eq $uniqueTargets.Count + 1) {
            $customTarget = Read-Host "Enter target account (provide full username like user@domain for domain accounts or simple username for local accounts)"
            
            if (-not [string]::IsNullOrWhiteSpace($customTarget)) {
                if ($customTarget -notin $config.targetAccounts) {
                    $config.targetAccounts += $customTarget
                    Save-Config $config
                }
                return $customTarget
            }
        }
        else {
            Write-Host "Invalid selection" -ForegroundColor Red
            return $null
        }
    }
    else {
        Write-Host "No saved target accounts. Enter a new one." -ForegroundColor Yellow
        $customTarget = Read-Host "Enter target account (provide full username like user@domain for domain accounts or simple username for local accounts)"
        
        if (-not [string]::IsNullOrWhiteSpace($customTarget)) {
            $config.targetAccounts += $customTarget
            Save-Config $config
            return $customTarget
        }
    }
    
    Write-Host "Target account is required" -ForegroundColor Red
    return $null
}

function Get-ConnectorInput($config) {
    Write-Host ""
    Write-Host "Available Connectors:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $config.connectors.Count; $i++) {
        Write-Host "$($i + 1). $($config.connectors[$i])"
    }
    
    $choice = Read-Host "Select connector (1-$($config.connectors.Count))"
    $idx = [int]$choice - 1
    
    if ($idx -ge 0 -and $idx -lt $config.connectors.Count) {
        return $config.connectors[$idx]
    }
    else {
        Write-Host "Invalid selection, using default: $($config.connectors[0])" -ForegroundColor Yellow
        return $config.connectors[0]
    }
}

# ========================================
# RDP File Management
# ========================================

function Build-RDPContent($params, $psmServerAddress) {
    $rdpContent = "full address:s:$psmServerAddress`r`nalternate shell:s:psm /u $($params.targetAccount) /a $($params.address) /c $($params.connector)`r`nusername:s:$($params.cyberArkUser)`r`ndesktopwidth:i:1920`r`ndesktopheight:i:1080`r`nsession bpp:i:32"
    return $rdpContent
}

function Get-RDPFilePath($targetAccount, $address) {
    $rdpFileName = "$($targetAccount)-$($address).rdp"
    $rdpPath = Join-Path $PSScriptRoot $rdpFileName
    return $rdpPath
}

function Check-Or-CreateRDPFile($params, $config) {
    $rdpPath = Get-RDPFilePath $params.targetAccount $params.address
    
    $content = Build-RDPContent $params $config.PSM_server_address
    
    try {
        if (Test-Path $rdpPath) {
            Write-Host ""
            Write-Host "Updating RDP file: $([System.IO.Path]::GetFileName($rdpPath))" -ForegroundColor Green
            Set-Content -Path $rdpPath -Value $content -Force
        }
        else {
            Write-Host ""
            Write-Host "RDP file created: $([System.IO.Path]::GetFileName($rdpPath))" -ForegroundColor Green
            Set-Content -Path $rdpPath -Value $content
        }
        return $rdpPath
    }
    catch {
        Write-Host "Error creating RDP file: $_" -ForegroundColor Red
        return $null
    }
}

# ========================================
# RDP Launcher
# ========================================

function Show-RDPConnectionInstructions {
    Write-Host ""
    Write-Host "RDP Connection Instructions:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. A Remote Desktop Connection window will open momentarily" -ForegroundColor White
    Write-Host "   - Enter your CyberArk 'U' ID password when prompted" -ForegroundColor White
    Write-Host ""
    Write-Host "2. If you see a 'Reason for Access' prompt" -ForegroundColor White
    Write-Host "   - Enter the reason for accessing this system and press OK" -ForegroundColor White
    Write-Host ""
    Write-Host "3. Please wait while your connection is being established" -ForegroundColor White
    Write-Host "   - The target system should appear once the connection is ready" -ForegroundColor White
    Write-Host ""
}

function Launch-RDP($rdpPath) {
    if (-not (Test-Path $rdpPath)) {
        Write-Host "RDP file not found: $rdpPath" -ForegroundColor Red
        return $false
    }
    
    try {
        Show-RDPConnectionInstructions
        Start-Process $rdpPath
        return $true
    }
    catch {
        Write-Host "Error launching RDP: $_" -ForegroundColor Red
        return $false
    }
}

# ========================================
# Configuration Editor
# ========================================

function Edit-ConfigInteractive($config) {
    while ($true) {
        Write-Host ""
        Write-Host "Configuration Editor" -ForegroundColor Cyan
        Write-Host "1. Edit default CyberArk login user"
        Write-Host "2. Add new address"
        Write-Host "3. View all addresses"
        Write-Host "4. Add new target account"
        Write-Host "5. View all target accounts"
        Write-Host "6. View connectors"
        Write-Host "7. View PSM Server Address"
        Write-Host "8. Back to main menu"
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            "1" {
                $newUser = Read-Host "Enter new CyberArk login user"
                if (-not [string]::IsNullOrWhiteSpace($newUser)) {
                    $config.cyberArkUser = $newUser
                    Save-Config $config
                }
            }
            "2" {
                $newAddr = Read-Host "Enter IP/Hostname"
                if (-not [string]::IsNullOrWhiteSpace($newAddr)) {
                    if ($newAddr -notin $config.addresses) {
                        $config.addresses += $newAddr
                        Save-Config $config
                        Write-Host "Address added" -ForegroundColor Green
                    }
                    else {
                        Write-Host "Address already exists" -ForegroundColor Yellow
                    }
                }
            }
            "3" {
                Write-Host ""
                Write-Host "Configured Addresses:" -ForegroundColor Yellow
                if ($config.addresses.Count -eq 0) {
                    Write-Host "  No addresses configured"
                }
                else {
                    $config.addresses | Sort-Object -Unique | ForEach-Object {
                        Write-Host "  $_"
                    }
                }
            }
            "4" {
                $newTarget = Read-Host "Enter new target account"
                if (-not [string]::IsNullOrWhiteSpace($newTarget)) {
                    if ($newTarget -notin $config.targetAccounts) {
                        $config.targetAccounts += $newTarget
                        Save-Config $config
                        Write-Host "Target account added" -ForegroundColor Green
                    }
                    else {
                        Write-Host "Target account already exists" -ForegroundColor Yellow
                    }
                }
            }
            "5" {
                Write-Host ""
                Write-Host "Configured Target Accounts:" -ForegroundColor Yellow
                if ($config.targetAccounts.Count -eq 0) {
                    Write-Host "  No target accounts configured"
                }
                else {
                    $config.targetAccounts | Sort-Object -Unique | ForEach-Object {
                        Write-Host "  $_"
                    }
                }
            }
            "6" {
                Write-Host ""
                Write-Host "Configured Connectors:" -ForegroundColor Yellow
                $config.connectors | ForEach-Object {
                    Write-Host "  $_"
                }
            }
            "7" {
                Write-Host ""
                Write-Host "PSM Server Address (Read-Only):" -ForegroundColor Yellow
                Write-Host "  $($config.PSM_server_address)"
                Write-Host ""
                Write-Host "Note: This is a fixed system value and cannot be modified from this interface." -ForegroundColor Gray
            }
            "8" { return $config }
            default { Write-Host "Invalid option" -ForegroundColor Red }
        }
    }
}

# ========================================
# Main Menu
# ========================================

function Show-MainMenu {
    # Clear-Host
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "RDP Launcher..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Launch RDP Connection"
    Write-Host "2. Edit Configuration"
    Write-Host "3. Exit"
    Write-Host ""
}

function Show-PreConnectionWarning {
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "Important Information Before Connecting:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. You will need to authenticate with your CyberArk credentials" -ForegroundColor White
    Write-Host "2. A 'Reason for Access' may be requested - please provide business justification" -ForegroundColor White
    Write-Host "3. Your session will be monitored and recorded for security and compliance" -ForegroundColor White
    Write-Host "4. Please ensure you are authorized to access this system" -ForegroundColor White
    Write-Host "================================================================================" -ForegroundColor Yellow

}

function Main {
    Initialize-Config
    $config = Load-Config
    
    if ($EditConfig) {
        $config = Edit-ConfigInteractive $config
        return
    }
    
    while ($true) {
        Show-MainMenu
        $mainChoice = Read-Host "Select option (1-3)"
        
        switch ($mainChoice) {
            "1" {
                Write-Host ""
                Write-Host "RDP Connection Configuration" -ForegroundColor Cyan
                Write-Host ""
                
                # Get all inputs
                $address = Get-AddressInput $config
                if (-not $address) { continue }
                
                $cyberArkUser = Get-CyberArkUserInput $config
                if (-not $cyberArkUser) { continue }
                
                $targetAccount = Get-TargetAccountInput $config
                if (-not $targetAccount) { continue }
                
                $connector = Get-ConnectorInput $config
                
                # Summary
                Write-Host ""
                Write-Host "Connection Summary:" -ForegroundColor Cyan
                Write-Host "Address:           $address"
                Write-Host "CyberArk User:     $cyberArkUser"
                Write-Host "Target Account:    $targetAccount"
                Write-Host "Connector:         $connector"
                Write-Host ""
                
                # Show important information before proceeding
                Show-PreConnectionWarning
                
                $confirm = Read-Host "Proceed? (y/n)"
                
                if ($confirm -eq "y") {
                    $rdpPath = Check-Or-CreateRDPFile @{
                        address       = $address
                        cyberArkUser  = $cyberArkUser
                        targetAccount = $targetAccount
                        connector     = $connector
                    } $config
                    
                    if ($rdpPath) {
                       $status = Launch-RDP $rdpPath
                       if($status) {
                           Write-Host "RDP launched successfully." -ForegroundColor Green
                       }
                       else {
                           Write-Host "Failed to launch RDP." -ForegroundColor Red
                       }
                    }
                }
            }
            "2" {
                $config = Edit-ConfigInteractive $config
            }
            "3" {
                Write-Host ""
                Write-Host "Goodbye!" -ForegroundColor Green
                exit
            }
            default {
                Write-Host "Invalid option" -ForegroundColor Red
            }
        }
    }
}

# ========================================
# Entry Point
# ========================================

Main
