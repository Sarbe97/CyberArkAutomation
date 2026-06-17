#========================================================================
# Build-Executable.ps1 - Package SAW into a standalone .exe
# Uses PS2EXE (install with: Install-Module -Name ps2exe -Scope CurrentUser)
#
# Usage:
#   .\Build\Build-Executable.ps1
#   .\Build\Build-Executable.ps1 -OutputDir "C:\Output"
#========================================================================
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\dist')
)

$AppRoot  = Resolve-Path (Join-Path $PSScriptRoot '..')
$MainScript = Join-Path $AppRoot 'SAW.ps1'
$OutputExe  = Join-Path $OutputDir 'SAW.exe'

Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Server Access Workbench - Build Script' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# Ensure output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "Created output directory: $OutputDir" -ForegroundColor Gray
}

# Check PS2EXE
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "`nPS2EXE module not found. Installing..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

# Copy required files to dist
$distApp = Join-Path $OutputDir 'SAW'
if (-not (Test-Path $distApp)) { New-Item -ItemType Directory -Path $distApp -Force | Out-Null }

$dirsToCopy = @('Modules','UI','Config')
foreach ($d in $dirsToCopy) {
    $src = Join-Path $AppRoot $d
    $dst = Join-Path $distApp $d
    if (Test-Path $src) {
        Copy-Item $src -Destination $dst -Recurse -Force
        Write-Host "Copied: $d" -ForegroundColor Gray
    }
}

# Create Logs and Config dirs if missing in dist
foreach ($d in @('Logs','Config')) {
    $p = Join-Path $distApp $d
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

Write-Host "`nBuilding executable..." -ForegroundColor Yellow

$ps2exeParams = @{
    InputFile   = $MainScript
    OutputFile  = (Join-Path $distApp 'SAW.exe')
    Title       = 'Server Access Workbench'
    Description = 'CyberArk Operations Console'
    Company     = 'CyberArk'
    Version     = '1.0.0'
    Icon        = $null
    NoConsole   = $true
    RequireAdmin = $false
    MTA         = $false
    STA         = $true
}

Invoke-ps2exe @ps2exeParams

if (Test-Path (Join-Path $distApp 'SAW.exe')) {
    Write-Host "`nâœ…  Build successful!" -ForegroundColor Green
    Write-Host "Output: $(Join-Path $distApp 'SAW.exe')" -ForegroundColor Green
} else {
    Write-Host "`nâŒ  Build failed. Check PS2EXE output above." -ForegroundColor Red
}

Write-Host "`nDistribution files: $distApp" -ForegroundColor Cyan
