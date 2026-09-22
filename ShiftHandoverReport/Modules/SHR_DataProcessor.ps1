# =============================================================================
# SHR_DataProcessor.ps1
# Excel data processing, categorization, and metrics calculation module
# =============================================================================

function Get-FormattedDateString {
    param ([string]$DateString)
    $d = $null
    if (-not [string]::IsNullOrWhiteSpace($DateString)) {
        try {
            $d = [DateTime]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            try { $d = [DateTime]::Parse($DateString) } catch {}
        }
    }
    if ($null -eq $d) {
        $d = Get-Date
    }
    return "$($d.Day)-$($d.ToString('MMMM'))"
}

# Retain backward-compatible alias
function Get-OrdinalDateString {
    param ([string]$DateString)
    return Get-FormattedDateString -DateString $DateString
}

function Get-CurrentShiftName {
    param (
        [PSCustomObject]$ShiftsConfig
    )

    if ($null -eq $ShiftsConfig -or $null -eq $ShiftsConfig.Windows -or $ShiftsConfig.Windows.Count -eq 0) {
        return "1st Shift"
    }

    $currentTime = Get-Date
    $currentSpan = [TimeSpan]::Parse($currentTime.ToString("HH:mm"))

    foreach ($win in $ShiftsConfig.Windows) {
        try {
            $startSpan = [TimeSpan]::Parse($win.Start)
            $endSpan = [TimeSpan]::Parse($win.End)

            if ($startSpan -le $endSpan) {
                # Window within the same day (e.g. 03:30 to 15:30)
                if ($currentSpan -ge $startSpan -and $currentSpan -lt $endSpan) {
                    return $win.Name
                }
            }
            else {
                # Window crosses midnight (e.g. 15:30 to 03:30)
                if ($currentSpan -ge $startSpan -or $currentSpan -lt $endSpan) {
                    return $win.Name
                }
            }
        }
        catch {}
    }

    return "1st Shift"
}

function Get-NormalizedCellValue {
    param (
        [object]$Row,
        [string[]]$AliasList
    )

    if ($null -eq $Row -or $null -eq $AliasList) { return "" }

    $propNames = $Row.PSObject.Properties.Name
    foreach ($alias in $AliasList) {
        $cleanAlias = ($alias -replace '[\s_#\-\?]', '').ToLower()
        foreach ($prop in $propNames) {
            $cleanProp = ($prop -replace '[\s_#\-\?]', '').ToLower()
            if ($cleanAlias -eq $cleanProp) {
                $val = $Row.$prop
                if ($null -ne $val) {
                    return ("$val").Trim()
                }
            }
        }
    }
    return ""
}

function Parse-DateValue {
    param (
        [object]$DateValue
    )

    if ($null -eq $DateValue) { return $null }

    # If it is already a DateTime object (e.g. returned directly by ImportExcel)
    if ($DateValue -is [DateTime]) {
        return $DateValue
    }

    $str = ("$DateValue").Trim()
    if ([string]::IsNullOrWhiteSpace($str)) { return $null }

    # Handle Excel numeric serial dates (e.g. 45552 or 45552.6041666667)
    if ($str -match '^\d{5}(\.\d+)?$') {
        try {
            $serial = [double]$str
            return (Get-Date "1899-12-30").AddDays($serial)
        }
        catch {}
    }

    # Handle explicit date & time formats: MM/dd/yyyy HH:mm (24-hour), M/d/yyyy H:mm, etc.
    $formats = @(
        "MM/dd/yyyy HH:mm",
        "M/d/yyyy HH:mm",
        "MM/dd/yyyy H:mm",
        "M/d/yyyy H:mm",
        "MM/dd/yyyy HH:mm:ss",
        "M/d/yyyy HH:mm:ss",
        "MM/dd/yyyy",
        "M/d/yyyy",
        "MM-dd-yyyy HH:mm",
        "MM-dd-yyyy",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm",
        "yyyy/MM/dd",
        "dd/MM/yyyy HH:mm",
        "dd/MM/yyyy",
        "dd-MM-yyyy HH:mm",
        "dd-MM-yyyy"
    )

    try {
        return [DateTime]::ParseExact($str, $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
    }
    catch {}

    # Invariant culture fallback
    try {
        return [DateTime]::Parse($str, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {}

    # Current thread culture fallback
    try {
        return [DateTime]::Parse($str)
    }
    catch {}

    return $null
}

function Get-ShiftHandoverMetrics {
    param (
        [Parameter(Mandatory = $true)][string]$WorkbookPath,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][string]$ReportDate,
        [string]$ScriptName = "DataProcessor",
        [string]$LogPath
    )

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw "The PowerShell module 'ImportExcel' is required but not installed. Run: Install-Module ImportExcel -Scope CurrentUser"
    }
    Import-Module ImportExcel -ErrorAction Stop

    # Column mappings with defaults (supports Open/Close and Change Start/End dates)
    $ColMap = if ($Config.Columns) { $Config.Columns } else {
        [PSCustomObject]@{
            TicketNumber     = @("TicketNumber", "Ticket Number", "Number", "Ticket#")
            TicketType       = @("TicketType", "Ticket Type", "Type")
            Priority         = @("Priority", "Pri", "Severity", "Urgency")
            Status           = @("Status", "State", "Ticket Status")
            OpenDate         = @("OpenDate", "Open Date", "Opened", "Created", "Created Date", "Start Date", "StartDate", "Start", "Planned Start Date", "Actual Start Date")
            ClosedDate       = @("ClosedDate", "Closed Date", "Resolved Date", "Completed Date", "Closed", "End Date", "EndDate", "End", "Planned End Date", "Actual End Date")
            ShortDescription = @("ShortDescription", "Short Description", "Description", "Summary", "Title")
            AssignmentGroup  = @("AssignmentGroup", "Assignment Group", "Group", "Team")
            AssignedTo       = @("AssignedTo", "Assigned To", "Owner", "Assignee")
            ETA              = @("ETA", "Target Date", "Estimated Date", "Resolution ETA", "Due Date")
            HandedOver       = @("HandedOver", "Handed Over", "Handover", "Handover?", "Shift Handover", "Handoff", "Hand Over", "IsHandover")
            HandoverNotes    = @("HandoverNotes", "Handover Notes", "Handed Over Notes", "HandedOverNotes", "UserNotes")
            Comments         = @("Comments", "Comment", "Notes", "Update", "Latest Update")
            SpecialRemarks   = @("SpecialRemarks", "Special Remarks", "Remarks", "Notes / Remarks")
            Source           = @("Source", "Origin", "Ticket Source")
            LastSyncDateTime = @("LastSyncDateTime", "Last Sync Date Time", "LastSync")
        }
    }

    $statusMap = $Config.StatusMapping
    $ClosedStatuses = if ($statusMap.ClosedStatuses) { $statusMap.ClosedStatuses } else { @("Closed", "Resolved", "Completed", "Cancelled") }
    $ImplementedStatuses = if ($statusMap.ImplementedStatuses) { $statusMap.ImplementedStatuses } else { @("Implemented", "Closed", "Completed") }
    $InProgressStatuses = if ($statusMap.InProgressStatuses) { $statusMap.InProgressStatuses } else { @("In Progress", "Work in Progress", "WIP", "Active") }
    $PendingStatuses = if ($statusMap.PendingStatuses) { $statusMap.PendingStatuses } else { @("Pending", "On Hold", "Awaiting Info", "Awaiting Vendor", "Awaiting User", "Awaiting Customer") }
    $OpenStatuses = if ($statusMap.OpenStatuses) { $statusMap.OpenStatuses } else { @("Open", "New", "Assigned", "Submitted") }

    # Identify sheets
    $AvailableSheets = @()
    try {
        $AvailableSheets = (Get-ExcelSheetInfo -Path $WorkbookPath).Name
        Write-Log -Message "Discovered sheet(s) in workbook: $($AvailableSheets -join ', ')" -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        Write-Log -Message "Could not inspect sheets via Get-ExcelSheetInfo. Falling back to configured application sheets." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    $ConfiguredSheets = if ($Config.ApplicationSheets -and $Config.ApplicationSheets.Count -gt 0) {
        $Config.ApplicationSheets
    } else {
        $AvailableSheets
    }

    Write-Log -Message "Processing application sheet(s): $($ConfiguredSheets -join ', ')" -ScriptName $ScriptName -LogPath $LogPath

    $ApplicationDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
    $CriticalIncidents  = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sheet in $ConfiguredSheets) {
        Write-Log -Message "Reading records from sheet '$sheet'..." -ScriptName $ScriptName -LogPath $LogPath
        
        $rawRows = $null
        try {
            $rawRows = Import-Excel -Path $WorkbookPath -WorksheetName $sheet -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Could not read sheet '$sheet': $($_.Exception.Message)" -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
            continue
        }

        $validRows = @($rawRows | Where-Object { $_ -ne $null })
        Write-Log -Message "Sheet '$sheet' loaded ($($validRows.Count) rows)." -ScriptName $ScriptName -LogPath $LogPath

        $appIncidents = [System.Collections.Generic.List[PSCustomObject]]::new()
        $appRequests  = [System.Collections.Generic.List[PSCustomObject]]::new()
        $appChanges   = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($row in $validRows) {
            $ticketNumber = Get-NormalizedCellValue -Row $row -AliasList $ColMap.TicketNumber
            if ([string]::IsNullOrWhiteSpace($ticketNumber)) { continue }

            $ticketType   = Get-NormalizedCellValue -Row $row -AliasList $ColMap.TicketType
            $priorityRaw  = Get-NormalizedCellValue -Row $row -AliasList $ColMap.Priority
            $status       = Get-NormalizedCellValue -Row $row -AliasList $ColMap.Status
            $openDateStr  = Get-NormalizedCellValue -Row $row -AliasList $ColMap.OpenDate
            $closedDateStr= Get-NormalizedCellValue -Row $row -AliasList $ColMap.ClosedDate
            $shortDesc    = Get-NormalizedCellValue -Row $row -AliasList $ColMap.ShortDescription
            $assignedTo   = Get-NormalizedCellValue -Row $row -AliasList $ColMap.AssignedTo
            $etaRaw         = Get-NormalizedCellValue -Row $row -AliasList $ColMap.ETA
            $eta            = "&mdash;"
            if (-not [string]::IsNullOrWhiteSpace($etaRaw)) {
                $parsedEta = Parse-DateValue -DateValue $etaRaw
                if ($null -ne $parsedEta) {
                    $eta = $parsedEta.ToString("yyyy-MM-dd")
                }
                elseif ($etaRaw -match '^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})') {
                    $eta = $matches[1]
                }
                elseif ($etaRaw -match '^(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})') {
                    $eta = $matches[1]
                }
                else {
                    $eta = $etaRaw
                }
            }

            # For Change tickets: if ETA column is blank, fall back to End Date (ClosedDate) or Start Date (OpenDate)
            if ($isChg -and ($eta -eq "&mdash;" -or [string]::IsNullOrWhiteSpace($eta))) {
                if (-not [string]::IsNullOrWhiteSpace($closedDateStr)) {
                    $parsedEnd = Parse-DateValue -DateValue $closedDateStr
                    if ($null -ne $parsedEnd) { $eta = $parsedEnd.ToString("yyyy-MM-dd") }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($openDateStr)) {
                    $parsedStart = Parse-DateValue -DateValue $openDateStr
                    if ($null -ne $parsedStart) { $eta = $parsedStart.ToString("yyyy-MM-dd") }
                }
            }

            $handedOverStr  = Get-NormalizedCellValue -Row $row -AliasList $ColMap.HandedOver
            if ([string]::IsNullOrWhiteSpace($handedOverStr)) {
                $handedOverStr = Get-NormalizedCellValue -Row $row -AliasList $ColMap.Handover
            }
            $handoverNotes  = Get-NormalizedCellValue -Row $row -AliasList $ColMap.HandoverNotes
            $comments       = Get-NormalizedCellValue -Row $row -AliasList $ColMap.Comments
            $specialRemarks = Get-NormalizedCellValue -Row $row -AliasList $ColMap.SpecialRemarks

            # Classify Ticket Type (Incidents: INC; Requests: SCTASK, RITM, CTASK; Changes: CHG)
            $isInc = ($ticketNumber -match '^INC') -or ($ticketType -like "*Incident*")
            $isReq = ($ticketNumber -match '^(SCTASK|RITM|CTASK)') -or ($ticketType -like "*Request*" -or $ticketType -like "*SCTASK*" -or $ticketType -like "*RITM*" -or $ticketType -like "*CTASK*")
            $isChg = ($ticketNumber -match '^CHG') -or ($ticketType -like "*Change*")
            if (-not $isInc -and -not $isReq -and -not $isChg) { $isInc = $true }

            # Format Priority (4 - Low, 3 - Moderate, 2 - High, 1 - Critical)
            # Only for Incidents; can be blank for others
            $priorityCode = ""
            $priorityDisplay = ""
            if (-not [string]::IsNullOrWhiteSpace($priorityRaw)) {
                $pTrimmed = $priorityRaw.Trim()
                if ($pTrimmed -match '^0\b' -or $pTrimmed -match '(?i)\b(P0|Blocker)\b') {
                    $priorityCode = "P0"
                    $priorityDisplay = "0 - Blocker"
                }
                elseif ($pTrimmed -match '^1\b' -or $pTrimmed -match '(?i)\b(P1|Critical)\b') {
                    $priorityCode = "P1"
                    $priorityDisplay = "1 - Critical"
                }
                elseif ($pTrimmed -match '^2\b' -or $pTrimmed -match '(?i)\b(P2|High)\b') {
                    $priorityCode = "P2"
                    $priorityDisplay = "2 - High"
                }
                elseif ($pTrimmed -match '^3\b' -or $pTrimmed -match '(?i)\b(P3|Moderate|Medium|Med)\b') {
                    $priorityCode = "P3"
                    $priorityDisplay = "3 - Moderate"
                }
                elseif ($pTrimmed -match '^4\b' -or $pTrimmed -match '(?i)\b(P4|Low)\b') {
                    $priorityCode = "P4"
                    $priorityDisplay = "4 - Low"
                }
                else {
                    $priorityCode = ($pTrimmed -replace '[\s\-_]', '').ToUpper()
                    $priorityDisplay = $pTrimmed
                }
            }

            # Status Flags
            $isClosed = $false
            foreach ($cs in $ClosedStatuses) {
                if ($status -ieq $cs) { $isClosed = $true; break }
            }

            $isImplemented = $false
            foreach ($ims in $ImplementedStatuses) {
                if ($status -ieq $ims) { $isImplemented = $true; break }
            }

            $isWip = $false
            foreach ($w in $InProgressStatuses) {
                if ($status -ieq $w) { $isWip = $true; break }
            }

            $isPending = $false
            foreach ($p in $PendingStatuses) {
                if ($status -ieq $p) { $isPending = $true; break }
            }

            $isOpen = $false
            foreach ($o in $OpenStatuses) {
                if ($status -ieq $o) { $isOpen = $true; break }
            }

            # Date Check for Closed Today (supports MM/dd/yyyy h24:mm)
            $isClosedToday = $false
            $parsedClosed = Parse-DateValue -DateValue $closedDateStr
            if ($null -ne $parsedClosed) {
                if ($parsedClosed.ToString("yyyy-MM-dd") -eq $ReportDate) {
                    $isClosedToday = $true
                }
            }

            $isHandover = ($handedOverStr -ieq "Yes") -or ($handedOverStr -ieq "Y") -or ($handedOverStr -ieq "True")

            $record = [PSCustomObject]@{
                Application     = $sheet
                TicketNumber    = $ticketNumber
                TicketType      = if ($isInc) { "Incident" } elseif ($isReq) { "Service Request" } else { "Change" }
                PriorityCode    = $priorityCode
                PriorityDisplay = $priorityDisplay
                State           = $status
                ShortDescription= $shortDesc
                AssignedTo      = $assignedTo
                ETA             = $eta
                HandedOver      = if ($isHandover) { "Yes" } else { "No" }
                HandoverNotes   = $handoverNotes
                Comments        = $comments
                SpecialRemarks  = $specialRemarks
                IsClosed        = $isClosed
                IsClosedToday   = $isClosedToday
                IsWip           = $isWip
                IsPending       = $isPending
                IsOpen          = $isOpen
                IsHandover      = $isHandover
            }

            if ($isInc) {
                # Count if active or closed today
                if (-not $isClosed -or $isClosedToday) {
                    $appIncidents.Add($record)
                }
                # Check for Critical / Major (P0, P1, P2)
                if ($priorityCode -in @("P0", "P1", "P2") -and (-not $isClosed -or $isClosedToday)) {
                    $CriticalIncidents.Add($record)
                }
            }
            elseif ($isReq) {
                if (-not $isClosed -or $isClosedToday) {
                    $appRequests.Add($record)
                }
            }
            elseif ($isChg) {
                $appChanges.Add($record)
            }
        }

        # -------------------------------------------------------------
        # Compute Incident Breakdown for this Application
        # -------------------------------------------------------------
        $incTotalCount = $appIncidents.Count
        $prioritySummaries = [System.Collections.Generic.List[string]]::new()
        $activeIncidentsList = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($incTotalCount -gt 0) {
            # Group by priority: P0, P1, P2, P3, P4
            foreach ($pCode in @("P0", "P1", "P2", "P3", "P4")) {
                $matchingPri = @($appIncidents | Where-Object { $_.PriorityCode -eq $pCode })
                if ($matchingPri.Count -gt 0) {
                    $wipCount = @($matchingPri | Where-Object { -not $_.IsClosed }).Count
                    $closedCount = @($matchingPri | Where-Object { $_.IsClosedToday }).Count
                    $pLabel = switch ($pCode) {
                        "P0" { "0 - Blocker" }
                        "P1" { "1 - Critical" }
                        "P2" { "2 - High" }
                        "P3" { "3 - Moderate" }
                        "P4" { "4 - Low" }
                        default { $pCode }
                    }
                    # Example: 4 - Low - 3 (3 - InProgress, 0 - Closed)
                    $prioritySummaries.Add("$pLabel - $($matchingPri.Count) ($wipCount - InProgress, $closedCount - Closed)")
                }
            }

            # Incidents to show in table: active tickets (or flagged for handover)
            foreach ($inc in ($appIncidents | Where-Object { -not $_.IsClosed -or $_.IsHandover })) {
                $activeIncidentsList.Add($inc)
            }
        }

        # -------------------------------------------------------------
        # Compute Service Request Breakdown for this Application
        # -------------------------------------------------------------
        $reqTotalCount = $appRequests.Count
        $reqSummaryString = ""

        if ($reqTotalCount -eq 0) {
            $reqSummaryString = "0"
        }
        else {
            $reqClosed = @($appRequests | Where-Object { $_.IsClosedToday }).Count
            $reqWip    = @($appRequests | Where-Object { $_.IsWip -or ($_.IsOpen -and -not $_.IsPending -and -not $_.IsClosed) }).Count
            $reqPending= @($appRequests | Where-Object { $_.IsPending }).Count

            $parts = [System.Collections.Generic.List[string]]::new()
            if ($reqClosed -gt 0)  { $parts.Add("$reqClosed-closed") }
            if ($reqWip -gt 0)     { $parts.Add("$reqWip- InProgress") }
            if ($reqPending -gt 0) { $parts.Add("$reqPending -Pending") }

            if ($parts.Count -gt 0) {
                $reqSummaryString = "$reqTotalCount ($($parts -join ', '))"
            } else {
                $reqSummaryString = "$reqTotalCount"
            }
        }

        # -------------------------------------------------------------
        # Compute Change Request Breakdown for this Application
        # -------------------------------------------------------------
        $chgTotalCount = $appChanges.Count
        $chgSummaryString = ""

        if ($chgTotalCount -eq 0) {
            $chgSummaryString = "0"
        }
        else {
            $chgClosed     = @($appChanges | Where-Object { $_.IsClosedToday -or $_.IsImplemented }).Count
            $chgWip        = @($appChanges | Where-Object { $_.IsWip }).Count
            $chgPending    = @($appChanges | Where-Object { $_.IsPending }).Count
            $chgScheduled  = @($appChanges | Where-Object { $_.IsOpen -or ($_.State -like "*Schedule*") }).Count

            $chgParts = [System.Collections.Generic.List[string]]::new()
            if ($chgClosed -gt 0)    { $chgParts.Add("$chgClosed - Implemented") }
            if ($chgWip -gt 0)       { $chgParts.Add("$chgWip - InProgress") }
            if ($chgPending -gt 0)   { $chgParts.Add("$chgPending - Pending") }
            if ($chgScheduled -gt 0) { $chgParts.Add("$chgScheduled - Scheduled") }

            if ($chgParts.Count -gt 0) {
                $chgSummaryString = "$chgTotalCount ($($chgParts -join ', '))"
            } else {
                $chgSummaryString = "$chgTotalCount"
            }
        }

        $ApplicationDetails.Add([PSCustomObject]@{
            Application         = $sheet
            IncidentCount       = $incTotalCount
            PrioritySummaries   = $prioritySummaries
            ActiveIncidents     = $activeIncidentsList
            RequestCount        = $reqTotalCount
            RequestSummary      = $reqSummaryString
            ActiveRequests      = @($appRequests | Where-Object { -not $_.IsClosed -or $_.IsHandover })
            ChangeCount         = $chgTotalCount
            ChangeSummary       = $chgSummaryString
            ActiveChanges       = @($appChanges | Where-Object { -not $_.IsClosed -or $_.IsHandover -or $_.IsClosedToday })
        })
    }

    $totActiveInc   = 0
    $totActiveReq   = 0
    $totActiveChg   = 0
    $totClosedToday = 0
    $totHandovers   = 0

    foreach ($app in $ApplicationDetails) {
        $totActiveInc   += ($app.ActiveIncidents | Where-Object { -not $_.IsClosed }).Count
        $totActiveReq   += ($app.ActiveRequests | Where-Object { -not $_.IsClosed }).Count
        $totActiveChg   += ($app.ActiveChanges | Where-Object { -not $_.IsClosed -and -not $_.IsImplemented }).Count
        $totClosedToday += ($app.ActiveIncidents | Where-Object { $_.IsClosedToday }).Count + ($app.ActiveRequests | Where-Object { $_.IsClosedToday }).Count + ($app.ActiveChanges | Where-Object { $_.IsClosedToday -or $_.IsImplemented }).Count
        $totHandovers   += ($app.ActiveIncidents | Where-Object { $_.IsHandover }).Count + ($app.ActiveRequests | Where-Object { $_.IsHandover }).Count + ($app.ActiveChanges | Where-Object { $_.IsHandover }).Count
    }

    return [PSCustomObject]@{
        Applications       = $ApplicationDetails
        ApplicationMetrics = $ApplicationDetails
        CriticalIncidents  = $CriticalIncidents
        TotalActiveInc     = $totActiveInc
        TotalActiveReq     = $totActiveReq
        TotalActiveChg     = $totActiveChg
        TotalClosedToday   = $totClosedToday
        TotalHandoverItems = $totHandovers
    }
}
