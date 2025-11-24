Set-StrictMode -Version Latest

# ---------------------------------------------------------
# MODULE ROOT
# ---------------------------------------------------------
$ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------
# REQUIREMENTS
# ---------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name psPAS)) {
    Write-Warning "psPAS module is NOT installed. CyberArkToolkit cannot run."
    return
}

Import-Module psPAS -ErrorAction Stop

# ---------------------------------------------------------
# CACHE FOLDERS
# ---------------------------------------------------------

$Global:CATK_PrivatePath = Join-Path $ModuleRoot 'Private'
$Global:CATK_CachePath = Join-Path $Global:CATK_PrivatePath 'Cache'

foreach ($path in @($Global:CATK_PrivatePath, $Global:CATK_CachePath)) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# ---------------------------------------------------------
# HELPER: DOT-SOURCE ALL .ps1 FILES IN A FOLDER
# ---------------------------------------------------------

function DotSource-Folder {
    param([string]$FolderPath)

    if (-not (Test-Path $FolderPath)) { return }

    Get-ChildItem -Path $FolderPath -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object {
        try {
            . $_.FullName
        }
        catch {
            Write-Warning "Failed loading: $($_.FullName)"
            Write-Warning $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------
# LOAD MODULE FILES (Infra, Core, CLI)
# ---------------------------------------------------------

DotSource-Folder (Join-Path $ModuleRoot "Infra")
DotSource-Folder (Join-Path $ModuleRoot "Core")
DotSource-Folder (Join-Path $ModuleRoot "CLI")

# ---------------------------------------------------------
# SAFE FUNCTION DISCOVERY (works INSIDE module loading)
# ---------------------------------------------------------

$module = $MyInvocation.MyCommand.ScriptBlock.Module

$allModuleFunctions = $module.Invoke({
        Get-ChildItem function:
    })

# ---------------------------------------------------------
# BUILD EXPORT LIST
# ---------------------------------------------------------

$exportFunctions = @()

# Core logic functions
$exportFunctions += $allModuleFunctions |
Where-Object { $_.Name -like 'Invoke-CATK*' } |
Select-Object -ExpandProperty Name

# Infra functions
$exportFunctions += $allModuleFunctions |
Where-Object {
    $_.Name -like 'Connect-CATK' -or
    $_.Name -like 'Disconnect-CATK' -or
    $_.Name -like 'Initialize-CATK*' -or
    $_.Name -like 'Get-CATK*' -or
    $_.Name -like 'Set-CATK*'
} |
Select-Object -ExpandProperty Name

# CLI functions
$exportFunctions += $allModuleFunctions |
Where-Object { $_.Name -like 'Show-CATK*' } |
Select-Object -ExpandProperty Name

$exportFunctions = $exportFunctions | Select-Object -Unique

Export-ModuleMember -Function $exportFunctions

# ---------------------------------------------------------
# PUBLIC MODULE INFO
# ---------------------------------------------------------

function Get-CATKModuleInfo {
    [PSCustomObject]@{
        ModuleRoot    = $ModuleRoot
        CachePath     = $Global:CATK_CachePath
        ExportedFuncs = $exportFunctions
        PsPASLoaded   = $null -ne (Get-Module -Name psPAS)  
    }
}

Export-ModuleMember -Function Get-CATKModuleInfo
