function Get-CACPSMRecordings {
    param(
        [int]$Days = 0
    )

    Write-Log "Started Get-CACPSMRecordings()" "DEBUG"

    if ($Days -le 0) {
        $userInput = Read-Host "Enter number of days to look back (default: 7)"
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $Days = 7
        }
        elseif ([int]::TryParse($userInput, [ref]$Days)) {
            Write-Log "User entered: $Days days" "DEBUG"
        }
        else {
            Write-Log "Invalid input, using default 7 days" "WARN"
            $Days = 7
        }
    }

    Write-Log "Fetching PSM recordings for last $Days days" "INFO"

    try {
        $fromTime = (Get-Date).AddDays(-$Days)

        Write-Log "From date: $fromTime" "DEBUG"
        Write-Log "Calling Get-PASPSMRecording" "DEBUG"

        $recordings = Get-PASPSMRecording -FromTime $fromTime

        if (-not $recordings -or $recordings.Count -eq 0) {
            Write-Log "No recordings found for the given period" "WARN"
            Write-Host "No recordings found for last $Days days." -ForegroundColor Yellow
            return
        }

        Write-Log "Total recordings retrieved: $($recordings.Count)" "INFO"

        Write-Log "Initializing user cache for enrichment" "DEBUG"
        Initialize-CACUserCache

        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

        Write-Log "Starting enrichment of recordings with user data" "INFO"

        $formatted = @()
        $successCount = 0
        $errorCount = 0
        $totalRecordings = $recordings.Count

        foreach ($recording in $recordings) {
            $recordingIndex = $recordings.IndexOf($recording) + 1

            try {
                Write-Log "Processing recording ($recordingIndex/$totalRecordings): $($recording.SessionID)" "DEBUG"

                $psmUser = $recording.User
                $userDetails = Get-CACUserDetailsFromStore -InputValue $psmUser

                $enrichedRecording = [PSCustomObject]@{
                    SessionID             = $recording.SessionID
                    PAS_User              = $psmUser
                    PAS_User_FullName     = $userDetails.FullName
                    PAS_User_Department   = $userDetails.Department
                    PAS_User_Title        = $userDetails.Title
                    RemoteMachine         = $recording.RemoteMachine
                    AccountUsername       = $recording.AccountUsername
                    AccountAddress        = $recording.AccountAddress
                    AccountPlatformID     = $recording.AccountPlatformID
                    FromIP                = $recording.FromIP
                    Client                = $recording.Client
                    Protocol              = $recording.Protocol
                    SafeName              = $recording.SafeName
                    FolderName            = $recording.FolderName
                    PSM_Start             = Convert-CACTimestamp $recording.Start
                    PSM_End               = Convert-CACTimestamp $recording.End
                    PSM_Duration_Seconds  = $recording.Duration
                    RiskScore             = $recording.RiskScore
                    Severity              = $recording.Severity
                    TicketID              = $recording.TicketID
                    ProtectedBy           = $recording.ProtectedBy
                    ProtectionEnabled     = $recording.ProtectionEnabled
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

        if ($formatted.Count -eq 0) {
            Write-Log "No successfully enriched recordings to export" "WARN"
            return
        }

        $outputFile = "$outputDir/PSM_Recordings_${Days}days_$timestamp.csv"
        Write-Log "Exporting $($formatted.Count) recordings to CSV: $outputFile" "INFO"

        $formatted | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "CSV export successful: $outputFile" "SUCCESS"

        Write-Log "Completed Get-CACPSMRecordings()" "DEBUG"
        Write-Host "Export Summary" -ForegroundColor Cyan
        Write-Host "Days: $Days"
        Write-Host "Total Recordings: $($recordings.Count)"
        Write-Host "Successfully Enriched: $successCount"
        Write-Host "Enrichment Errors: $errorCount"
        Write-Host "Output File: $outputFile" -ForegroundColor Green
    }
    catch {
        Write-Log "Error during Get-CACPSMRecordings(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-CACAccountActivityByName {
    param(
        [string]$AccountName
    )

    Write-Log "Started Get-CACAccountActivityByName()" "DEBUG"

    try {
        if ([string]::IsNullOrWhiteSpace($AccountName)) {
            $AccountName = Read-Host "Enter account name to search"
            if ([string]::IsNullOrWhiteSpace($AccountName)) {
                Write-Log "Account name not provided" "WARN"
                Write-Host "Account name is required." -ForegroundColor Yellow
                return
            }
        }

        Write-Log "Searching for accounts matching: $AccountName" "INFO"
        Write-Host "Searching for accounts matching: $AccountName" -ForegroundColor Cyan

        # Call psPAS directly to search accounts
        $accounts = Get-PASAccount -search $AccountName -ErrorAction Stop

        if (-not $accounts -or $accounts.Count -eq 0) {
            Write-Log "No accounts found matching: $AccountName" "WARN"
            Write-Host "No accounts found matching '$AccountName'." -ForegroundColor Yellow
            return
        }

        Write-Log "Found $($accounts.Count) account(s) matching: $AccountName" "INFO"
        Write-Host "Found $($accounts.Count) account(s)" -ForegroundColor Green
        Write-Host ""

        # Display search results
        $accounts | Format-Table -AutoSize @(
            @{Label = "ID"; Expression = { $_.id } },
            @{Label = "Name"; Expression = { $_.name } },
            @{Label = "Username"; Expression = { $_.userName } },
            @{Label = "Address"; Expression = { $_.address } },
            @{Label = "Safe"; Expression = { $_.safeName } }
        )

        Write-Host ""
        $accountId = Read-Host "Enter Account ID to fetch activities (from list above)"

        if ([string]::IsNullOrWhiteSpace($accountId)) {
            Write-Log "Account ID not provided" "WARN"
            Write-Host "Account ID is required to fetch activities." -ForegroundColor Yellow
            return
        }

        Write-Log "Fetching activities for Account ID: $accountId" "DEBUG"
        Write-Host "Fetching activities for Account ID: $accountId..." -ForegroundColor Cyan

        # Call psPAS directly to get account activity
        $activities = Get-PASAccountActivity -AccountID $accountId -ErrorAction Stop

        if (-not $activities -or $activities.Count -eq 0) {
            Write-Log "No activities found for account: $accountId" "WARN"
            Write-Host "No activities found for this account." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($activities.Count) activity records" "INFO"

        Write-Host ""
        Write-Host "Account Activity Summary" -ForegroundColor Cyan
        Write-Host ""

        # Format and display activities
        $formattedActivities = $activities | ForEach-Object {
            [PSCustomObject]@{
                Time        = Convert-CACTimestamp $_.Time
                Activity    = $_.Activity
                UserName    = $_.UserName
                AccountName = $_.AccountName
            }
        }

        $formattedActivities | Format-Table -AutoSize

        # Export to CSV
        $outputDir = "$PSScriptRoot/../Output"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
            Write-Log "Output directory created: $outputDir" "DEBUG"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFile = "$outputDir/account_activity_${accountId}_$timestamp.csv"

        Write-Log "Exporting $($formattedActivities.Count) activity records to CSV: $outputFile" "INFO"
        $formattedActivities | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "CSV export successful: $outputFile" "SUCCESS"

        Write-Host ""
        Write-Host "Export Summary" -ForegroundColor Cyan
        Write-Host "Total Activities: $($formattedActivities.Count)"
        Write-Host "Output File: $outputFile" -ForegroundColor Green

        Write-Log "Completed Get-CACAccountActivityByName()" "DEBUG"
    }
    catch {
        Write-Log "Error during Get-CACAccountActivityByName(): $($_.Exception.Message)" "ERROR"
        Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Export-ModuleMember -Function Get-CACPSMRecordings, Get-CACAccountActivityByName
