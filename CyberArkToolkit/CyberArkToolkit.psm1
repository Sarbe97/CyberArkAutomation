Set-StrictMode -Version Latest

$ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------
# psPAS Requirement
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
$Global:CATK_CachePath   = Join-Path $Global:CATK_PrivatePath 'Cache'

if (-not (Test-Path $Global:CATK_PrivatePath)) { New-Item $Global:CATK_PrivatePath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $Global:CATK_CachePath))   { New-Item $Global:CATK_CachePath   -ItemType Directory -Force | Out-Null }

# ---------------------------------------------------------
# LOAD SCRIPTS HELPER
# ---------------------------------------------------------

function DotSource-Folder {
    param([string]$FolderPath)

    if (-not (Test-Path $FolderPath)) { return }

    Get-ChildItem -Path $FolderPath -Filter '*.ps1' |
        Sort-Object Name |
        ForEach-Object {
            Write-Host "Loading file: $($_.FullName)" -ForegroundColor Cyan
            try {
                . $_.FullName
                Write-Host "Loaded OK: $($_.Name)" -ForegroundColor Green
            }
            catch {
                Write-Host "FAILED in: $($_.Name)" -ForegroundColor Red
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
# EXPORT FUNCTIONS
# ---------------------------------------------------------

$exportFunctions = @()

# Core logic functions
$exportFunctions += (Get-Command -CommandType Function | Where-Object { $_.Name -like 'Invoke-CATK*' }).Name

# Infra functions
$infraPatterns = @('Connect-CATK','Disconnect-CATK','Initialize-CATK*','Get-CATK*','Set-CATK*')

foreach ($pattern in $infraPatterns) {
    $exportFunctions += (Get-Command -CommandType Function | Where-Object { $_.Name -like $pattern }).Name
}

$exportFunctions = $exportFunctions | Select-Object -Unique

Export-ModuleMember -Function $exportFunctions

# ---------------------------------------------------------
# MODULE INFO
# ---------------------------------------------------------

function Get-CATKModuleInfo {
    [PSCustomObject]@{
        ModuleRoot    = $ModuleRoot
        CachePath     = $Global:CATK_CachePath
        ExportedFuncs = $exportFunctions
        PsPASLoaded   = (Get-Module -Name psPAS) -ne $null
    }
}

Export-ModuleMember -Function Get-CATKModuleInfo
