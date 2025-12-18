

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

function Get-CACPlatformReport {
    [CmdletBinding()]
    param()

    Write-Host "Fetching all platforms..." -ForegroundColor Cyan
    try {
        $AllPlatforms = Get-PASPlatform
    }
    catch {
        Write-Error "Failed to retrieve platforms: $_"
        return
    }

    if (-not $AllPlatforms) {
        Write-Warning "No platforms found."
        return
    }

    $Total = $AllPlatforms.Count
    Write-Host "Found $Total platforms. Starting detailed retrieval..." -ForegroundColor Cyan

    $Results = @()
    $Counter = 0

    foreach ($Plat in $AllPlatforms) {
        $Counter++
        $ProgressParams = @{
            Activity = "Processing Platforms"
            Status   = "Processing $($Plat.ID) ($Counter / $Total)"
            PercentComplete = ($Counter / $Total) * 100
        }
        Write-Progress @ProgressParams

        try {
            # Get full details for the platform to ensure we have all policy settings
            # Some versions of psPAS/PVWA might require fetching by ID to get policy details
            $Details = Get-PASPlatform -ID $Plat.ID -ErrorAction Stop

            # Extract Policy Settings
            # structure might vary based on API version, attempting to handle common structure
            $PrivilegedAccessWorkflows = $Details.PrivilegedAccessWorkflows
            $PasswordManagement = $Details.PasswordManagement

            $Obj = [PSCustomObject]@{
                PlatformID          = $Details.ID
                PlatformName        = $Details.Name
                Active              = $Details.Active
                SystemType          = $Details.SystemType
                # Check-in/Check-out usually maps to Exclusive Access in policies
                ExclusiveAccess     = if ($PrivilegedAccessWorkflows.ExclusiveAccess) { $PrivilegedAccessWorkflows.ExclusiveAccess } else { $false }
                OneTimePassword     = if ($PrivilegedAccessWorkflows.OTP) { $PrivilegedAccessWorkflows.OTP } else { $false }
                DualControl         = if ($PrivilegedAccessWorkflows.DualControl) { $PrivilegedAccessWorkflows.DualControl } else { $false }
                ReasonRequired      = if ($PrivilegedAccessWorkflows.QuickConnect) { $PrivilegedAccessWorkflows.QuickConnect } else { $false } # Mapping might vary
                VerifyOnAdd         = if ($PasswordManagement.VerifyOnAdd) { $PasswordManagement.VerifyOnAdd } else { $false }
                ChangeOnAdd         = if ($PasswordManagement.ChangeOnAdd) { $PasswordManagement.ChangeOnAdd } else { $false }
            }

            $Results += $Obj
        }
        catch {
            Write-Warning "Failed to fetch details for platform '$($Plat.ID)': $_"
            # Add basic info if detail fetch fails
            $Results += [PSCustomObject]@{
                PlatformID      = $Plat.ID
                PlatformName    = $Plat.Name
                Active          = $Plat.Active
                SystemType      = $Plat.SystemType
                ExclusiveAccess = "ERROR"
                OneTimePassword = "ERROR"
                DualControl     = "ERROR"
                ReasonRequired  = "ERROR"
                VerifyOnAdd     = "ERROR"
                ChangeOnAdd     = "ERROR"
            }
        }
    }

    # Generate Report File
    $Values = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportDir = Join-Path $PSScriptRoot "..\Reports"
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir | Out-Null
    }

    $CsvPath = Join-Path $ReportDir "PlatformReport_$Values.csv"
    
    try {
        $Results | Export-Csv -Path $CsvPath -NoTypeInformation -Force
        Write-Host "Report generated successfully: $CsvPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to save CSV report: $_"
    }

    Write-Progress -Activity "Processing Platforms" -Completed
}

Export-ModuleMember -Function Export-CACPlatform, Get-CACPlatformReport
