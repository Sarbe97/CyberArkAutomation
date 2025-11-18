# Pull-CyberArkPSMRecordings.ps1 - Retrieves all PSM recordings with pagination, saves output, remembers last PVWA URL

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Helpers\Utils.psm1" -Verbose -DisableNameChecking

$configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Config\config.json"
$lastPvwaUrl = $null

if (Test-Path $configPath) {
    $configJson = Get-Content $configPath -Raw | ConvertFrom-Json
    $lastPvwaUrl = $configJson.PvwaUrl
}

if ($lastPvwaUrl) {
    Write-Host "Previous PVWA URL: $lastPvwaUrl"
    $pvwaUrl = Read-Host "Enter PVWA URL (or press Enter to use previous)"
    if ([string]::IsNullOrWhiteSpace($pvwaUrl)) {
        $pvwaUrl = $lastPvwaUrl
    }
}
else {
    $pvwaUrl = Read-Host "Enter PVWA URL (e.g. https://pvwa.myorg.com)"
}

# Save PVWA URL to config for next run
$configObj = @{ PvwaUrl = $pvwaUrl }
if (-not (Test-Path (Split-Path $configPath))) {
    New-Item -ItemType Directory -Path (Split-Path $configPath) -Force | Out-Null
}
$configObj | ConvertTo-Json | Set-Content $configPath

$daysInput = Read-Host "Enter 'From Time' filter in days (e.g. 7 for last 7 days)"
if (-not [int]::TryParse($daysInput, [ref]$null)) {
    Write-Warning "Invalid days input, defaulting to 7."
    $daysInput = 7
}

$fromEpoch = ConvertTo-EpochFromDays -DaysAgo $daysInput

$session = Connect-CyberArk -PvwaUrl $pvwaUrl

try {
    $allRecordings = @()
    $limit = 25
    $offset = 0

    do {
        $recordingsPage = Get-CyberArkPSMRecordings -PvwaUrl $pvwaUrl -Token $session.Token -FromTimeEpoch $fromEpoch -Limit $limit -Offset $offset

        if ($null -eq $recordingsPage) {
            break
        }

        $count = $recordingsPage.Count
        $allRecordings += $recordingsPage

        $offset += $count
    }
    while ($count -eq $limit)

    if ($allRecordings.Count -gt 0) {
        $outputObjects = $allRecordings | ForEach-Object {
            [PSCustomObject]@{
                SessionID       = $_.SessionID
                PSM_User            = $_.User
                PSM_RemoteMachine = $_.RemoteMachine
                PSM_AccountUsername = $_.AccountUsername
                PSM_AccountPlatformID = $_.AccountPlatformID
                PSM_AccountAddress = $_.AccountAddress  
                PSM_ConnectionComponentID = $_.ConnectionComponentID
                PSM_FromIP        = $_.FromIP
                PSM_Protocol        = $_.Protocol
                #Client = $_.Client
                #RiskScore      = $_.RiskScore
                #Severity       = $_.Severity
                PSM_Start           = ([DateTimeOffset]::FromUnixTimeSeconds($_.Start)).DateTime
                PSM_End             = ([DateTimeOffset]::FromUnixTimeSeconds($_.End)).DateTime
                DurationSeconds = $_.Duration
            }
        }

        $outputObjects | Format-Table -AutoSize

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvPath = Join-Path -Path (Get-Location) -ChildPath "PSMRecordings_$timestamp.csv"
        $outputObjects | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Output saved to $csvPath"
    }
    else {
        Write-Host "No recordings found for the specified period."
    }
}
finally {
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
}
