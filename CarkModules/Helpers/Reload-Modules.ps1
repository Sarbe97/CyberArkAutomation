# Reload-Modules.ps1 - Centralized module reload helper

$modulesToReload = @('Auth', 'CyberArkAPIs', 'Utils')

foreach ($mod in $modulesToReload) {
    if (Get-Module -Name $mod) {
        Remove-Module -Name $mod -Force -ErrorAction SilentlyContinue
        Write-Verbose "Unloaded module: $mod"
    }
}

# Get the path relative to this helper script
$helperPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import fresh modules
Import-Module "$helperPath\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$helperPath\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking
Import-Module "$helperPath\Utils.psm1" -Verbose -DisableNameChecking
