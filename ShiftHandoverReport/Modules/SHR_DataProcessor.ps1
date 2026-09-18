# =============================================================================
# SHR_DataProcessor.ps1
# Excel data processing, categorization, and metrics calculation module
# =============================================================================

function Get-FormattedDateString {
    param ([string]$DateString)
    $d = $null
    if (-not [DateTime]::TryParse($DateString, [ref]$d)) {
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
        [string]$DateString
    )

    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }

    # Handle Excel numeric serial dates (e.g. 45552)
    if ($DateString -match '^\d{5}$') {
        try {
            $serial = [double]$DateString
            return (Get-Date "1899-12-30").AddDays($serial)
        }
        catch {}
    }

    # Handle standard string representations
    $parsed = $null
    if ([DateTime]::TryParse($DateString, [ref]$parsed)) {
        return $parsed
    }

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

    # Column mappings with defaults
    $ColMap = if ($Config.Columns) { $Config.Columns } else {
        [PSCustomObject]@{
            TicketNumber     = @("TicketNumber", "Ticket Number", "Number", "Ticket#")
            TicketType       = @("TicketType", "Ticket Type", "Type")
            Priority         = @("Priority", "Pri", "Severity", "Urgency")
            Status           = @("Status", "State", "Ticket Status")
            OpenDate         = @("OpenDate", "Open Date", "Opened", "Created", "Created Date")
            ClosedDate       = @("ClosedDate", "Closed Date", "Resolved Date", "Completed Date", "Closed")
            ShortDescription = @("ShortDescription", "Short Description", "Description", "Summary", "Title")
            AssignmentGroup  = @("AssignmentGroup", "Assignment Group", "Group", "Team")
            AssignedTo       = @("AssignedTo", "Assigned To", "Owner", "Assignee")
            ETA              = @("ETA", "Target Date", "Estimated Date", "Resolution ETA")
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
                $etaParsed = [DateTime]::MinValue
                if ([DateTime]::TryParse($etaRaw, [ref]$etaParsed)) {
                    $eta = $etaParsed.ToString("yyyy-MM-dd")
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

            # Format Priority (P0, P1, P2, P3, P4 - only for Incidents, can be blank for others)
            $priorityCode = ""
            $priorityDisplay = ""
            if (-not [string]::IsNullOrWhiteSpace($priorityRaw)) {
                $cleanPri = ($priorityRaw -replace '[\s\-_]', '').ToUpper()
                if ($cleanPri -eq "P0" -or $cleanPri -eq "0" -or $cleanPri -like "*BLOCKER*" -or $cleanPri -like "*P0*") {
                    $priorityCode = "P0"
                    $priorityDisplay = "P0"
                }
                elseif ($cleanPri -eq "P1" -or $cleanPri -eq "1" -or $cleanPri -like "*CRITICAL*" -or $cleanPri -like "*P1*") {
                    $priorityCode = "P1"
                    $priorityDisplay = "P1"
                }
                elseif ($cleanPri -eq "P2" -or $cleanPri -eq "2" -or $cleanPri -like "*HIGH*" -or $cleanPri -like "*P2*") {
                    $priorityCode = "P2"
                    $priorityDisplay = "P2"
                }
                elseif ($cleanPri -eq "P3" -or $cleanPri -eq "3" -or $cleanPri -like "*MED*" -or $cleanPri -like "*MODERATE*" -or $cleanPri -like "*P3*") {
                    $priorityCode = "P3"
                    $priorityDisplay = "P3"
                }
                elseif ($cleanPri -eq "P4" -or $cleanPri -eq "4" -or $cleanPri -like "*LOW*" -or $cleanPri -like "*P4*") {
                    $priorityCode = "P4"
                    $priorityDisplay = "P4"
                }
                else {
                    $priorityCode = $cleanPri
                    $priorityDisplay = $priorityRaw
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

            # Date Check for Closed Today
            $isClosedToday = $false
            $parsedClosed = Parse-DateValue -DateString $closedDateStr
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
                    # Example: P4 – 3 (3 – InProgress, 0 - Closed)
                    $prioritySummaries.Add("$pCode – $($matchingPri.Count) ($wipCount – InProgress, $closedCount - Closed)")
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
