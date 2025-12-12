<#
.SYNOPSIS
    Module for managing CyberArk Platforms.
#>

function Export-CACPlatform {
   
    [CmdletBinding()]
    param()

    # 1. Prompt for CSV Path
    $CsvPath = Read-Host "Enter full path to the Platform CSV file"
    
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Warning "No path provided. Exiting."
        return
    }

    if (-not (Test-Path $CsvPath)) {
        Write-Error "File not found: $CsvPath"
        return
    }

    try {
        $InputData = Import-Csv -Path $CsvPath
    }
    catch {
        Write-Error "Failed to import CSV: $_"
        return
    }

    if (-not $InputData) {
        Write-Warning "CSV is empty."
        return
    }

    # 2. Prepare Output Directory
    $InputFileInfo = Get-Item $CsvPath
    $OutputDir = Join-Path -Path $InputFileInfo.DirectoryName -ChildPath "PlatformExports"
    
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
        Write-Host "Created output directory: $OutputDir" -ForegroundColor Cyan
    }

    # 3. Process Platforms
    foreach ($Row in $InputData) {
        # Check for PlatformID or PlatformName
        $PlatformID = if ($Row.PlatformID) { $Row.PlatformID } elseif ($Row.PlatformName) { $Row.PlatformName } else { $null }

        if ([string]::IsNullOrWhiteSpace($PlatformID)) {
            Write-Warning "Skipping row with missing PlatformID/PlatformName"
            continue
        }

        Write-Host "Processing platform: $PlatformID" -ForegroundColor Cyan

        try {
            # Sanitize filename
            $SafeFileName = $PlatformID -replace '[\\/*?:"<>|]', '_'
            $OutputPath = Join-Path -Path $OutputDir -ChildPath "${SafeFileName}.zip"
            # Export platform package to ZIP
            Export-PASPlatform -ID $PlatformID -OutFile $OutputPath -ErrorAction Stop
            
            Write-Host "Exported to: $OutputPath" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to export platform '$PlatformID': $($_.Exception.Message)"
        }
    }

    Write-Host "Export operation completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function Export-CACPlatform
