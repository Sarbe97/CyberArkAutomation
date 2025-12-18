

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

    # 1. Verification: Print structure of the first platform from the list
    Write-Host "`n--- VERIFICATION: Sample Platform Structure (First Item from List) ---" -ForegroundColor Yellow
    $AllPlatforms[0] | ConvertTo-Json -Depth 10 | Write-Host
    Write-Host "--- END OF VERIFICATION ---`n" -ForegroundColor Yellow

    $Total = $AllPlatforms.Count
    Write-Host "Found $Total platforms. Mapping data..." -ForegroundColor Cyan

    $Results = @()
    $Counter = 0

    foreach ($Plat in $AllPlatforms) {
        $Counter++
        $ProgressParams = @{
            Activity = "Processing Platforms"
            Status   = "Mapping $($Plat.PlatformID) ($Counter / $Total)"
            PercentComplete = ($Counter / $Total) * 100
        }
        Write-Progress @ProgressParams

        # Mapping based on the actual system response structure
        $Gen = $Plat.Details
        $Workflows = $Gen.PrivilegedAccessWorkflows

        $Obj = [PSCustomObject]@{
            PlatformID          = $Plat.PlatformID
            PlatformName        = $Gen.Name
            Active              = $Plat.Active
            SystemType          = $Gen.SystemType
            PlatformType        = $Plat.PlatformType
            
            # Privileged Access Workflows - Accessing IsActive property for each setting
            CheckinCheckout     = if ($null -ne $Workflows.EnforceCheckinCheckoutExclusiveAccess.IsActive) { $Workflows.EnforceCheckinCheckoutExclusiveAccess.IsActive } else { "N/A" }
            OTP                 = if ($null -ne $Workflows.EnforceOnetimePasswordAccess.IsActive) { $Workflows.EnforceOnetimePasswordAccess.IsActive } else { "N/A" }
            DualControl         = if ($null -ne $Workflows.RequireDualControlPasswordAccessApproval.IsActive) { $Workflows.RequireDualControlPasswordAccessApproval.IsActive } else { "N/A" }
            ReasonRequired      = if ($null -ne $Workflows.RequireUsersToSpecifyReasonForAccess.IsActive) { $Workflows.RequireUsersToSpecifyReasonForAccess.IsActive } else { "N/A" }
        }

        $Results += $Obj
    }

    # Generate Report File in CyberArkCLI/output
    $Values = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportDir = Join-Path $PSScriptRoot "..\output"
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir | Out-Null
        Write-Host "Created output directory: $ReportDir" -ForegroundColor Gray
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
