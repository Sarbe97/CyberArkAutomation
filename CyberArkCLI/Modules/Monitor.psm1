# Modules/Monitor.psm1

function Get-CACPSMRecordings {
    param(
        [int]$Days = 7
    )

    $cfg = Get-CACConfig

    # Ask user for days if not provided
    if (-not $Days) {
        $daysInput = Read-Host "Enter 'From Time' filter in days (e.g. 7 for last 7 days)"
        if (-not [int]::TryParse($daysInput, [ref]$Days)) {
            Write-Warning "Invalid input, defaulting to 7 days."
            $Days = 7
        }
    }

    # Convert days to epoch
    $fromEpoch = (Get-Date).AddDays(-$Days).ToUniversalTime() | ForEach-Object { [int][double]($_ -as [datetimeoffset]).ToUnixTimeSeconds() }

    Write-Host "[INFO] Fetching PSM recordings for last $Days day(s)..." -ForegroundColor Cyan

    # Check if logged in
    if (-not $global:CACSessionToken) {
        throw "No session token found. Please login first."
    }

    # Load user cache
    $usersCsv = Join-Path $PSScriptRoot "../Data/users.csv"
    if (-not (Test-Path $usersCsv)) {
        Write-Warning "users.csv not found. Please refresh user cache first."
        return
    }

    $userCache = Import-Csv $usersCsv

    # Pagination settings
    $allRecordings = @()
    $limit = 25
    $offset = 0
    $pageCounter = 0

    do {
        $pageCounter++
        Write-Host "  [PAGE $pageCounter] Fetching recordings (offset: $offset, limit: $limit)..." -ForegroundColor Gray

        # Fetch recordings - replace with real psPAS call or REST
        $recordingsPage = Get-PASRecording -FromEpoch $fromEpoch -Limit $limit -Offset $offset -Token $global:CACSessionToken
        # $recordingsPage should return an array of PSCustomObject similar to your sample

        if (-not $recordingsPage -or $recordingsPage.Count -eq 0) { break }

        $allRecordings += $recordingsPage
        $offset += $recordingsPage.Count
    }
    while ($recordingsPage.Count -eq $limit)

    Write-Host "[INFO] Total recordings retrieved: $($allRecordings.Count)" -ForegroundColor Cyan

    # Enrich with user details
    $outputObjects = $allRecordings | ForEach-Object {
        $recording = $_
        $userDetails = $userCache | Where-Object { $_.username -eq $recording.User }

        [PSCustomObject]@{
            SessionID                 = $recording.SessionID
            PSM_User                  = $recording.User
            PSM_User_FullName         = if ($userDetails) { "$($userDetails.firstName) $($userDetails.lastName)" } else { "" }
            PSM_UserStatus            = if ($userDetails) { $userDetails.status } else { "Unknown" }
            PSM_User_JobTitle         = if ($userDetails) { $userDetails.title } else { "" }
            PSM_User_Department       = if ($userDetails) { $userDetails.department } else { "" }
            PSM_RemoteMachine         = $recording.RemoteMachine
            PSM_AccountUsername       = $recording.AccountUsername
            PSM_AccountPlatformID     = $recording.AccountPlatformID
            PSM_AccountAddress        = $recording.AccountAddress
            PSM_ConnectionComponentID = $recording.ConnectionComponentID
            PSM_FromIP                = $recording.FromIP
            PSM_Protocol              = $recording.Protocol
            PSM_Start                 = ([DateTimeOffset]::FromUnixTimeSeconds($recording.Start)).DateTime
            PSM_End                   = ([DateTimeOffset]::FromUnixTimeSeconds($recording.End)).DateTime
            DurationSeconds           = $recording.Duration
        }
    }

    # Export CSV
    if ($outputObjects.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvPath = Join-Path -Path (Get-Location) -ChildPath "PSMRecordings_$timestamp.csv"

        Write-Host "[INFO] Exporting recordings to CSV..." -ForegroundColor Cyan
        $outputObjects | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "[SUCCESS] CSV saved: $csvPath" -ForegroundColor Green
    }
    else {
        Write-Host "[INFO] No recordings found for the given period." -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Get-CACPSMRecordings
