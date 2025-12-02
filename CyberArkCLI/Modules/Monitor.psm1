# Monitor.psm1 - PSM Recording Monitoring (CORRECTED Field Names)

# ==========================
# Get-CACPSMRecordings - Fetch PSM recordings with user enrichment
# ==========================
function Get-CACPSMRecordings {
    param(
        [int]$Days = 7
    )

    Write-Log "Started Get-CACPSMRecordings()" "DEBUG"
    Write-Log "Fetching PSM recordings for last $Days days" "INFO"

    # Handle interactive mode
    if ($Days -eq 0) {
        $userInput = Read-Host "Enter number of days to look back (e.g., 7 for last 7 days)"
        if ([int]::TryParse($userInput, [ref]$Days)) {
            Write-Log "User entered: $Days days" "DEBUG"
        }
        else {
            Write-Log "Invalid input, using default 7 days" "WARN"
            $Days = 7
        }
    }

    try {
        # Calculate time range
        $toTime = Get-Date
        $fromTime = $toTime.AddDays(-$Days)

        Write-Log "Time range: $fromTime to $toTime" "DEBUG"
        Write-Log "Calling Get-PASPSMRecording with FromTime and ToTime" "DEBUG"

        # Fetch recordings from psPAS
        $recordings = Get-PASPSMRecording -FromTime $fromTime -ToTime $toTime

        if (-not $recordings -or $recordings.Count -eq 0) {
            Write-Log "No recordings found for the given period" "WARN"
            return
        }

        Write-Log "Total recordings retrieved: $($recordings.Count)" "INFO"

        # ============================================================
        # Initialize user cache for enrichment
        # ============================================================
        Write-Log "Initializing user cache for enrichment" "DEBUG"
        Initialize-CACUserCache

        # ============================================================
        # Create output directory
        # ============================================================
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

        # ============================================================
        # Process recordings with user enrichment
        # ============================================================
        Write-Log "Starting enrichment of recordings with user data" "INFO"

        $formatted = @()
        $successCount = 0
        $errorCount = 0
        $totalRecordings = $recordings.Count

        foreach ($recording in $recordings) {
            $recordingIndex = $recordings.IndexOf($recording) + 1

            try {
                Write-Log "Processing recording ($recordingIndex/$totalRecordings): $($recording.SessionID)" "DEBUG"

                # CORRECTED: Use .User instead of .PSMVaultUserName
                $psmUser = $recording.User
                $userDetails = Get-CACUserDetailsFromStore -Username $psmUser

                # Build enriched recording object with CORRECTED field names
                $enrichedRecording = [PSCustomObject]@{
                    # Recording Identifiers
                    SessionID            = $recording.SessionID
                    SessionGuid          = $recording.SessionGuid
                    FileName             = $recording.FileName

                    # PSM User Information
                    PSM_User             = $psmUser
                    PSM_User_Id          = $userDetails.Id
                    PSM_User_FullName    = $userDetails.FullName
                    PSM_User_Department  = $userDetails.Department
                    PSM_User_Title       = $userDetails.Title
                    PSM_User_Organization = $userDetails.Organization

                    # Target Machine Information
                    RemoteMachine        = $recording.RemoteMachine
                    AccountUsername      = $recording.AccountUsername
                    AccountAddress       = $recording.AccountAddress
                    AccountPlatformID    = $recording.AccountPlatformID

                    # Connection Information
                    FromIP               = $recording.FromIP
                    Client               = $recording.Client
                    Protocol             = $recording.Protocol

                    # Safe Information
                    SafeName             = $recording.SafeName
                    FolderName           = $recording.FolderName

                    # Session Timing (CORRECTED: Start/End instead of PSMStartTime/PSMEndTime)
                    Start                = $recording.Start
                    End                  = $recording.End
                    Duration_Seconds     = $recording.Duration

                    # Risk and Ticket
                    RiskScore            = $recording.RiskScore
                    Severity             = $recording.Severity
                    TicketID             = $recording.TicketID

                    # Additional fields
                    ProtectedBy          = $recording.ProtectedBy
                    ProtectionEnabled    = $recording.ProtectionEnabled
                    ConnectionComponentID = $recording.ConnectionComponentID
                }

                $formatted += $enrichedRecording
                $successCount++
                Write-Log "Successfully enriched recording: $($recording.SessionID)" "DEBUG"
            }
            catch {
                $errorCount++
                $msg = $_.Exception.Message
                Write-Log "Error processing recording $recordingIndex ($($recording.SessionID)): $msg" "ERROR"
            }
        }

        Write-Log "Enrichment complete. Success: $successCount, Errors: $errorCount" "INFO"

        # ============================================================
        # Export to CSV
        # ============================================================
        if ($formatted.Count -eq 0) {
            Write-Log "No successfully enriched recordings to export" "WARN"
            return
        }

        $outputFile = "$outputDir/PSM_Recordings_${Days}days_$timestamp.csv"
        Write-Log "Exporting $($formatted.Count) recordings to CSV: $outputFile" "INFO"

        $formatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "CSV export successful: $outputFile" "SUCCESS"

        # ============================================================
        # Summary
        # ============================================================
        Write-Log "Completed Get-CACPSMRecordings()" "DEBUG"
        Write-Host "Export Summary" -ForegroundColor Cyan
        Write-Host "  Days: $Days"
        Write-Host "  Total Recordings: $($recordings.Count)"
        Write-Host "  Successfully Enriched: $successCount"
        Write-Host "  Enrichment Errors: $errorCount"
        Write-Host "  Output File: $outputFile" -ForegroundColor Green
    }
    catch {
        Write-Log "Error during Get-CACPSMRecordings(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# ============================================================
# EXPORT ALL PUBLIC FUNCTIONS
# ============================================================
Export-ModuleMember -Function Get-CACPSMRecordings
