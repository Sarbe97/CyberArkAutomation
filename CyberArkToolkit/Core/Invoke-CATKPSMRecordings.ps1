function Invoke-CATKPSMRecordings {
    <#
    .SYNOPSIS
        Retrieves PSM session recordings for the last N days and enriches with cached user information.

    .PARAMETER Session
        CATK session object from Connect-CATK.

    .PARAMETER LastDays
        Number of days of PSM sessions to retrieve.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [int] $LastDays = 7
    )

    $fromTs = [int][DateTimeOffset]::UtcNow.AddDays(-$LastDays).ToUnixTimeSeconds()

    $limit  = 50
    $offset = 0
    $results = @()

    try {
        do {
            $page = Get-PASPSMSession -Session $Session.Session -FromTime $fromTs -Limit $limit -Offset $offset -ErrorAction Stop
            
            if (-not $page) { break }
            if ($page -isnot [System.Collections.IEnumerable]) { $page = @($page) }

            $results += $page
            $offset += $page.Count
        }
        while ($page.Count -eq $limit)
    }
    catch {
        Write-Warning "Failed to fetch PSM recordings: $_"
        return @()
    }

    # Enrichment using cached user details
    $out = foreach ($r in $results) {
        $u = Get-CATKCachedUser -Username $r.User

        if ($u) {
            $fname = ($u.firstName -as [string]).Trim()
            $mname = ($u.middleName -as [string]).Trim()
            $lname = ($u.lastName -as [string]).Trim()
            $fullname = "$fname $mname $lname".Trim()

            $status = if ($u.enableUser) { "Active" } else { "Not-Active" }

            $job  = $u.title
            $dept = $u.department
        }
        else {
            # fallback to live query
            try {
                $live = Get-PASUser -Session $Session.Session -search $r.User -ErrorAction Stop

                if ($live) {
                    $fullname = ("{0} {1} {2}" -f $live.firstName, $live.middleName, $live.lastName).Trim()
                    $status   = if ($live.enableUser) { "Active" } else { "Not-Active" }
                    $job      = $live.title
                    $dept     = $live.department
                }
            }
            catch {
                $fullname = ""
                $status = ""
                $job = ""
                $dept = ""
            }
        }

        [PSCustomObject]@{
            PAS_SessionID       = $r.SessionID
            PAS_User         = $r.User
            PAS_User_FullName        = $fullname
            PAS_User_Status          = $status
            PAS_User_JobTitle        = $job
            PAS_User_Department      = $dept
            PAS_RemoteMachine   = $r.RemoteMachine
            PAS_AccountUser     = $r.AccountUsername
            PAS_AccountPlatform = $r.AccountPlatformID
            PAS_FromIP          = $r.FromIP
            PAS_Protocol        = $r.Protocol
            PAS_StartTime       = [DateTimeOffset]::FromUnixTimeSeconds($r.Start).DateTime
            PAS_EndTime         = [DateTimeOffset]::FromUnixTimeSeconds($r.End).DateTime
            DurationSeconds = $r.Duration
        }
    }

    return $out
}
