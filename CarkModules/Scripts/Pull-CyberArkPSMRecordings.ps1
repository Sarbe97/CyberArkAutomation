# Pull-CyberArkPSMRecordings.ps1 - Retrieves all PSM recordings with pagination, enriches with user details, saves output

# Reload modules
$modulesToReload = @('Auth', 'CyberArkAPIs', 'Utils')
foreach ($mod in $modulesToReload) {
    if (Get-Module -Name $mod) {
        Remove-Module -Name $mod -Force -ErrorAction SilentlyContinue
        Write-Verbose "Unloaded module: $mod"
    }
}

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Helpers\Utils.psm1" -Verbose -DisableNameChecking

Write-Host "[INFO] Starting PSM Recordings retrieval script..." -ForegroundColor Cyan

$pvwaUrl = Get-PvwaUrlFromConfigOrPrompt
Write-Host "[INFO] PVWA URL configured: $pvwaUrl" -ForegroundColor Cyan

$daysInput = Read-Host "Enter 'From Time' filter in days (e.g. 7 for last 7 days)"
if (-not [int]::TryParse($daysInput, [ref]$null)) {
    Write-Warning "Invalid days input, defaulting to 7."
    $daysInput = 7
}

$fromEpoch = ConvertTo-EpochFromDays -DaysAgo $daysInput
Write-Host "[INFO] Retrieving recordings from last $daysInput days (Epoch: $fromEpoch)..." -ForegroundColor Cyan

Write-Host "[INFO] Connecting to CyberArk..." -ForegroundColor Cyan
$session = Connect-CyberArk -PvwaUrl $pvwaUrl
Write-Host "[SUCCESS] Connected successfully." -ForegroundColor Green

try {
    $allRecordings = @()
    $limit = 25
    $offset = 0
    $pageCounter = 0

    Write-Host "`n[INFO] Fetching PSM recordings with pagination..." -ForegroundColor Cyan

    do {
        $pageCounter++
        Write-Host "  [PAGE $pageCounter] Fetching recordings (offset: $offset, limit: $limit)..." -ForegroundColor Gray
        
        $recordingsPage = Get-CyberArkPSMRecordings -PvwaUrl $pvwaUrl -Token $session.Token -FromTimeEpoch $fromEpoch -Limit $limit -Offset $offset

        if ($null -eq $recordingsPage) {
            Write-Host "  [PAGE $pageCounter] No more recordings found." -ForegroundColor Gray
            break
        }

        $count = $recordingsPage.Count
        $allRecordings += $recordingsPage
        Write-Host "  [PAGE $pageCounter] Retrieved $count recording(s). Total so far: $($allRecordings.Count)" -ForegroundColor Cyan

        $offset += $count
    }
    while ($count -eq $limit)

    Write-Host "`n[INFO] Total recordings retrieved: $($allRecordings.Count)" -ForegroundColor Cyan

    if ($allRecordings.Count -gt 0) {
        Write-Host "`n[INFO] Enriching recordings with user details..." -ForegroundColor Cyan
        
        # Create a cache for user details to avoid redundant API calls
        $userDetailsCache = @{}
        $recordingCounter = 0

        $outputObjects = $allRecordings | ForEach-Object {
            $recordingCounter++
            $recording = $_
            
            Write-Host "  [RECORDING $recordingCounter/$($allRecordings.Count)] Processing SessionID: $($recording.SessionID), User: $($recording.User)" -ForegroundColor Gray

            # Initialize user detail fields with defaults
            $userStatus = "Unknown"
            $userJobTitle = ""
            $userDepartment = ""

            # Fetch user details if User field is present
            if ($recording.User) {
                try {
                    # Check cache first
                    if ($userDetailsCache.ContainsKey($recording.User)) {
                        Write-Host "    [CACHE] Using cached user details for: $($recording.User)" -ForegroundColor DarkGray
                        $userDetails = $userDetailsCache[$recording.User]
                    }
                    else {
                        Write-Host "    [API] Fetching user details for: $($recording.User)..." -ForegroundColor Yellow
                        # Note: PSM recordings return username, but API needs user ID
                        # We'll attempt to fetch by username - you may need to search for user first
                        # For now, trying direct username as ID (adjust if needed)
                        $userDetails = Get-CyberArkUserDetails -PvwaUrl $pvwaUrl -Token $session.Token -UserId $recording.User
                        $userDetailsCache[$recording.User] = $userDetails
                        Write-Host "    [API] User details fetched successfully." -ForegroundColor DarkGreen
                    }

                    if ($userDetails) {
                        # Map enableUser to Active/Not-Active
                        $userStatus = if ($userDetails.enableUser -eq $true) { "Active" } else { "Not-Active" }
                        $userJobTitle = if ($userDetails.personalDetails.title) { $userDetails.personalDetails.title } else { "" }
                        $userDepartment = if ($userDetails.personalDetails.department) { $userDetails.personalDetails.department } else { "" }
                        
                        Write-Host "    [USER INFO] Status: $userStatus, Title: $userJobTitle, Dept: $userDepartment" -ForegroundColor DarkCyan
                    }
                }
                catch {
                    Write-Host "    [WARNING] Failed to fetch user details for '$($recording.User)': $_" -ForegroundColor Red
                    $userStatus = "Error"
                }
            }

            # Build output object
            [PSCustomObject]@{
                SessionID                 = $recording.SessionID
                PSM_User                  = $recording.User
                PSM_UserStatus            = $userStatus
                PSM_User_JobTitle         = $userJobTitle
                PSM_User_Department       = $userDepartment
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

        Write-Host "`n[INFO] Displaying output preview..." -ForegroundColor Green
        $outputObjects | Select-Object -First 10 | Format-Table -AutoSize

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvPath = Join-Path -Path (Get-Location) -ChildPath "PSMRecordings_$timestamp.csv"
        
        Write-Host "`n[INFO] Exporting to CSV..." -ForegroundColor Cyan
        $outputObjects | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "[SUCCESS] Output saved to: $csvPath" -ForegroundColor Green
    }
    else {
        Write-Host "[INFO] No recordings found for the specified period." -ForegroundColor Yellow
    }
}
finally {
    Write-Host "`n[INFO] Disconnecting from CyberArk..." -ForegroundColor Cyan
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
    Write-Host "[SUCCESS] Disconnected successfully." -ForegroundColor Green
}
