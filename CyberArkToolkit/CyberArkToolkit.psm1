Set-StrictMode -Version Latest

Write-Host "=== Loading CyberArkToolkit Module ===" -ForegroundColor Cyan

# ---------------------------------------------------------
# MODULE ROOT
# ---------------------------------------------------------
$ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Module Root: $ModuleRoot" -ForegroundColor DarkCyan

# ---------------------------------------------------------
# REQUIREMENTS
# ---------------------------------------------------------
Write-Host "Checking psPAS module..." -ForegroundColor DarkCyan

if (-not (Get-Module -ListAvailable -Name psPAS)) {
    Write-Warning "psPAS module is NOT installed. CyberArkToolkit cannot run."
    return
}

Write-Host "psPAS module found. Importing..." -ForegroundColor Green
Import-Module psPAS -ErrorAction Stop

# ---------------------------------------------------------
# CACHE FOLDERS
# ---------------------------------------------------------
Write-Host "Preparing cache folders..." -ForegroundColor DarkCyan

$Global:CATK_PrivatePath = Join-Path $ModuleRoot 'Private'
$Global:CATK_CachePath = Join-Path $Global:CATK_PrivatePath 'Cache'

foreach ($path in @($Global:CATK_PrivatePath, $Global:CATK_CachePath)) {
    if (-not (Test-Path $path)) {
        Write-Host "Creating folder: $path" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    else {
        Write-Host "Folder OK: $path" -ForegroundColor Green
    }
}

# ---------------------------------------------------------
# HELPER: DOT-SOURCE ALL .ps1 FILES
# ---------------------------------------------------------
function DotSource-Folder {
    param([string]$FolderPath)

    if (-not (Test-Path $FolderPath)) { 
        Write-Warning "Folder missing: $FolderPath"
        return 
    }

    Write-Host "`n--- Loading from folder: $FolderPath ---" -ForegroundColor Cyan

    $files = Get-ChildItem -Path $FolderPath -Filter '*.ps1' | Sort-Object Name

    if ($files.Count -eq 0) {
        Write-Warning "No .ps1 files found in: $FolderPath"
    }

    $files | ForEach-Object {
        Write-Host "• Loading: $($_.Name)" -NoNewline

        try {
            . $_.FullName
            Write-Host "   [OK]" -ForegroundColor Green
        }
        catch {
            Write-Host "   [FAILED]" -ForegroundColor Red
            Write-Warning "File: $($_.FullName)"
            Write-Warning "Error: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------
# LOAD INFRA, CORE, CLI
# ---------------------------------------------------------

DotSource-Folder (Join-Path $ModuleRoot "Infra")
DotSource-Folder (Join-Path $ModuleRoot "Core")

$CliPath = Join-Path $ModuleRoot "CLI"
DotSource-Folder $CliPath

# ---------------------------------------------------------
# SAFE FUNCTION DISCOVERY
# ---------------------------------------------------------

Write-Host "`nDiscovering module functions..." -ForegroundColor Cyan

$module = $MyInvocation.MyCommand.ScriptBlock.Module

$allModuleFunctions = $module.Invoke({
        Get-ChildItem function:
    })

Write-Host "Functions discovered inside module scope: $($allModuleFunctions.Count)" -ForegroundColor Green
$allModuleFunctions.Name | Sort-Object | ForEach-Object { 
    Write-Host "  - $_" -ForegroundColor DarkGray 
}

# ---------------------------------------------------------
# BUILD EXPORT LIST
# ---------------------------------------------------------

Write-Host "`nSelecting functions to export..." -ForegroundColor Cyan

$exportFunctions = @()

# CORE
$core = $allModuleFunctions |
Where-Object { $_.Name -like 'Invoke-CATK*' } |
Select-Object -ExpandProperty Name

if ($core.Count -gt 0) {
    Write-Host "Core functions:" -ForegroundColor Green
    $core | ForEach-Object { Write-Host "  - $_" }
}
$exportFunctions += $core

# INFRA
$infra = $allModuleFunctions |
Where-Object {
    $_.Name -like 'Connect-CATK' -or
    $_.Name -like 'Disconnect-CATK' -or
    $_.Name -like 'Initialize-CATK*' -or
    $_.Name -like 'Get-CATK*' -or
    $_.Name -like 'Set-CATK*'
} |
Select-Object -ExpandProperty Name

if ($infra.Count -gt 0) {
    Write-Host "Infra functions:" -ForegroundColor Green
    $infra | ForEach-Object { Write-Host "  - $_" }
}
$exportFunctions += $infra

# CLI
$cli = $allModuleFunctions |
Where-Object { $_.Name -like 'Show-CATK*' } |
Select-Object -ExpandProperty Name

if ($cli.Count -gt 0) {
    Write-Host "CLI functions:" -ForegroundColor Green
    $cli | ForEach-Object { Write-Host "  - $_" }
}
$exportFunctions += $cli

$exportFunctions = $exportFunctions | Select-Object -Unique

Write-Host "`nFINAL exported functions:" -ForegroundColor Cyan
$exportFunctions | ForEach-Object { Write-Host "  - $_" }

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

Write-Host "`n=== CyberArkToolkit Module Load Complete ===" -ForegroundColor Cyan
