# Pull-CyberArkPSMRecordings.ps1 - Retrieves all PSM recordings with cached user enrichment

# Reload modules
$modulesToReload = @('Auth', 'CyberArkAPIs', 'Utils', 'UserCache')
foreach ($mod in $modulesToReload) {
    if (Get-Module -Name $mod) {
        Remove-Module -Name $mod -Force -ErrorAction SilentlyContinue
    }
}

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Helpers\Utils.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Helpers\UserCache.psm1" -Verbose -DisableNameChecking

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
    # Initialize user cache (will check/refresh automatically)
    Write-Host "`n[INFO] Initializing user cache..." -ForegroundColor Cyan
    Get-CachedUserDetails -PvwaUrl $pvwaUrl -Token $session.Token -Username "dummy" -RefreshDays 7 | Out-Null

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
        Write-Host "`n[INFO] Enriching recordings with cached user details..." -ForegroundColor Cyan
        $recordingCounter = 0

        $outputObjects = $allRecordings | ForEach-Object {
            $recordingCounter++
            $recording = $_
            
            Write-Host "  [RECORDING $recordingCounter/$($allRecordings.Count)] Processing SessionID: $($recording.SessionID), User: $($recording.User)" -ForegroundColor Gray

            # Initialize user detail fields with defaults
            $userStatus = "Unknown"
            $userJobTitle = ""
            $userDepartment = ""
            $fullName = ""

            # Fetch user details from cache
            if ($recording.User) {
                $userDetails = Get-CachedUserDetails -PvwaUrl $pvwaUrl -Token $session.Token -Username $recording.User -RefreshDays 7

                if ($userDetails) {
                    $userStatus = if ($userDetails.enableUser -eq "True") { "Active" } else { "Not-Active" }
                    $userJobTitle = $userDetails.title
                    $userDepartment = $userDetails.department
                    
                    $firstName = $userDetails.firstName
                    $middleName = if ($userDetails.middleName) { " " + $userDetails.middleName } else { "" }
                    $lastName = $userDetails.lastName
                    $fullName = "$firstName$middleName $lastName".Trim()

                    Write-Host "    [USER] $($recording.User): $fullName ($userStatus)" -ForegroundColor DarkCyan
                }
                else {
                    Write-Host "    [WARNING] User '$($recording.User)' not found in cache" -ForegroundColor Red
                    $userStatus = "Not Found"
                }
            }

            # Build output object
            [PSCustomObject]@{
                SessionID                 = $recording.SessionID
                PSM_User                  = $recording.User
                PSM_User_FullName         = $fullName
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
