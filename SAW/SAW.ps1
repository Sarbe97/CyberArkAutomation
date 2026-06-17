#Requires -Version 5.1
#========================================================================
# SAW.ps1 — Server Access Workbench
# CyberArk Log Explorer & Operations Console
# Entry point: loads modules, shows login, launches main window
#
# SECURITY: Credentials are NEVER stored to disk.
#           All passwords are held in [PSCredential] in memory only.
#========================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ──────────────────────────────────────────────────────────
$script:AppRoot   = $PSScriptRoot
$script:ModuleDir = Join-Path $AppRoot 'Modules'
$script:UIDir     = Join-Path $AppRoot 'UI'
$script:ConfigDir = Join-Path $AppRoot 'Config'
$script:LogDir    = Join-Path $AppRoot 'Logs'

# Ensure directories exist
foreach ($dir in @($script:LogDir, $script:ConfigDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ── Load WPF / Windows assemblies ─────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic   # For InputBox

# WPF STA requirement
[System.Threading.Thread]::CurrentThread.SetApartmentState([System.Threading.ApartmentState]::STA) 2>$null

# ── Import modules ─────────────────────────────────────────────────────────
$moduleLoadOrder = @(
    'AppLogger'
    'Auth'
    'ServerManager'
    'FileExplorer'
    'LogViewer'
    'Search'
    'Favorites'
)

foreach ($modName in $moduleLoadOrder) {
    $modPath = Join-Path $script:ModuleDir "$modName.psm1"
    if (-not (Test-Path $modPath)) {
        throw "Required module not found: $modPath"
    }
    Import-Module $modPath -Force -Global -ErrorAction Stop
}

# ── Initialize subsystems ──────────────────────────────────────────────────
Initialize-AppLogger   -LogDirectory $script:LogDir
Initialize-ServerManager -ConfigDirectory $script:ConfigDir
Initialize-Favorites   -ConfigDirectory $script:ConfigDir

Write-NexusLog 'SAW initialisation complete — showing login dialog' -Level INFO -Component 'SAW'

# ── Dot-source main window (after modules so all functions are available) ──
. (Join-Path $script:UIDir 'MainWindow.ps1')

# ── Show login ─────────────────────────────────────────────────────────────
$script:Credential = Show-LoginDialog -DefaultUsername 'NA\S123456'

if (-not $script:Credential) {
    Write-NexusLog 'Login cancelled — exiting' -Level INFO -Component 'SAW'
    exit 0
}

Write-NexusLog "Session authenticated: $($script:Credential.UserName)" -Level INFO -Component 'SAW'

# ── Launch main window ─────────────────────────────────────────────────────
try {
    Show-MainWindow -Credential $script:Credential
}
catch {
    Write-NexusLog "Fatal error in main window: $($_.Exception.Message)" -Level ERROR -Component 'SAW' -Exception $_.Exception
    [System.Windows.MessageBox]::Show(
        "A fatal error occurred:`n`n$($_.Exception.Message)`n`nPlease check the application log at:`n$(Join-Path $script:LogDir "SAW_$(Get-Date -Format 'yyyyMMdd').log")",
        'SAW — Fatal Error', 'OK', 'Error') | Out-Null
}
finally {
    Write-NexusLog 'SAW session ended' -Level INFO -Component 'SAW'
}
