#========================================================================
# Search.psm1 — Global Multi-Server Parallel Search Engine
# Uses PowerShell RunspacePool for concurrent server searching
# Results streamed via ConcurrentQueue to keep UI responsive
#========================================================================

$script:ResultQueue      = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
$script:RunspacePool     = $null
$script:ActiveJobs       = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$script:IsCancelled      = $false
$script:TotalServers     = 0
$script:CompletedServers = 0

# ---------- Public API -------------------------------------------------------

function Start-GlobalSearch {
    <#
    .SYNOPSIS  Starts a parallel search across one or more servers.
    .NOTES     Results accumulate in the queue. Call Get-SearchResults to drain.
               Call Get-SearchStatus to check progress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SearchText,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][array]$Servers,             # Array of hashtables from Get-Servers
        [string]$FilePattern      = '*',
        [switch]$CaseSensitive,
        [switch]$SearchFileNames,                           # If set, also search file names
        [Nullable[DateTime]]$StartDate = $null,
        [Nullable[DateTime]]$EndDate   = $null,
        [long]$MaxFileSizeBytes        = 0,                # 0 = no limit
        [int]$MaxResultsPerServer      = 500,
        [int]$MaxThreads               = 4
    )

    # Reset state
    Stop-GlobalSearch -Quiet
    $script:IsCancelled      = $false
    $script:ResultQueue      = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
    $script:ActiveJobs       = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    $script:TotalServers     = $Servers.Count
    $script:CompletedServers = 0

    $threadCount = [Math]::Max(1, [Math]::Min($MaxThreads, $Servers.Count))
    $script:RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $threadCount)
    $script:RunspacePool.Open()

    $searchScript = {
        param(
            [hashtable]$Server,
            [string]$SearchText,
            [System.Management.Automation.PSCredential]$Credential,
            [string]$FilePattern,
            [bool]$CaseSensitive,
            [bool]$SearchFileNames,
            [Nullable[DateTime]]$StartDate,
            [Nullable[DateTime]]$EndDate,
            [long]$MaxFileSizeBytes,
            [int]$MaxResults,
            [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]$ResultQueue,
            [ref]$CancelledRef,
            [ref]$CompletedRef
        )

        $found     = 0
        $driveName = "SAWSrch$(Get-Random -Maximum 999999)"

        try {
            $null = New-PSDrive -Name $driveName -PSProvider FileSystem `
                                -Root $Server.RootShare -Credential $Credential -ErrorAction Stop

            $gciParams = @{
                Path    = "${driveName}:\"
                Filter  = $FilePattern
                Recurse = $true
                File    = $true
                ErrorAction = 'SilentlyContinue'
            }
            $files = Get-ChildItem @gciParams

            foreach ($file in $files) {
                if ($CancelledRef.Value -or $found -ge $MaxResults) { break }

                # Date filter
                if ($StartDate -and $file.LastWriteTime -lt $StartDate) { continue }
                if ($EndDate   -and $file.LastWriteTime -gt $EndDate)   { continue }

                # Size filter
                if ($MaxFileSizeBytes -gt 0 -and $file.Length -gt $MaxFileSizeBytes) { continue }

                $uncFile = $file.FullName -replace "^${driveName}:", $Server.RootShare

                # File name search
                if ($SearchFileNames) {
                    $nameMatch = if ($CaseSensitive) { $file.Name.Contains($SearchText) }
                                 else { $file.Name.ToLower().Contains($SearchText.ToLower()) }
                    if ($nameMatch) {
                        $ResultQueue.Enqueue([PSCustomObject]@{
                            ServerName    = $Server.Name
                            FilePath      = $uncFile
                            FileName      = $file.Name
                            LineNumber    = 0
                            LineText      = "(filename match)"
                            Timestamp     = $file.LastWriteTime
                            ResultType    = 'FileName'
                        })
                        $found++
                    }
                }

                # Content search (text files only)
                $ext = $file.Extension.ToLower()
                $textExts = @('.log','.txt','.csv','.config','.ini','.json','.xml','.ps1','.psm1','.bat','.cmd')
                if ($ext -notin $textExts) { continue }

                try {
                    $lineNum = 0
                    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                        $lineNum++
                        if ($CancelledRef.Value -or $found -ge $MaxResults) { break }

                        $isMatch = if ($CaseSensitive) { $line.Contains($SearchText) }
                                   else { $line.ToLower().Contains($SearchText.ToLower()) }

                        if ($isMatch) {
                            $ResultQueue.Enqueue([PSCustomObject]@{
                                ServerName = $Server.Name
                                FilePath   = $uncFile
                                FileName   = $file.Name
                                LineNumber = $lineNum
                                LineText   = $line.Trim()
                                Timestamp  = $file.LastWriteTime
                                ResultType = 'Content'
                            })
                            $found++
                        }
                    }
                }
                catch { } # Skip unreadable files
            }
        }
        catch {
            # Inaccessible server — enqueue an error result
            $ResultQueue.Enqueue([PSCustomObject]@{
                ServerName = $Server.Name
                FilePath   = $Server.RootShare
                FileName   = '(connection failed)'
                LineNumber = -1
                LineText   = $_.Exception.Message
                Timestamp  = [DateTime]::Now
                ResultType = 'Error'
            })
        }
        finally {
            if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
            }
            [System.Threading.Interlocked]::Increment($CompletedRef) | Out-Null
        }
    }

    foreach ($server in $Servers) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $script:RunspacePool

        $null = $ps.AddScript($searchScript).AddParameters(@{
            Server             = $server
            SearchText         = $SearchText
            Credential         = $Credential
            FilePattern        = $FilePattern
            CaseSensitive      = $CaseSensitive.IsPresent
            SearchFileNames    = $SearchFileNames.IsPresent
            StartDate          = $StartDate
            EndDate            = $EndDate
            MaxFileSizeBytes   = $MaxFileSizeBytes
            MaxResults         = $MaxResultsPerServer
            ResultQueue        = $script:ResultQueue
            CancelledRef       = [ref]$script:IsCancelled
            CompletedRef       = [ref]$script:CompletedServers
        })

        $handle = $ps.BeginInvoke()
        $script:ActiveJobs.Add([PSCustomObject]@{ PS = $ps; Handle = $handle; Server = $server.Name })
    }

    Write-NexusLog "Global search started: '$SearchText' across $($Servers.Count) servers" -Level INFO -Component 'Search'
}

function Stop-GlobalSearch {
    [CmdletBinding()]
    param([switch]$Quiet)

    $script:IsCancelled = $true

    foreach ($job in $script:ActiveJobs) {
        try { $job.PS.Stop(); $job.PS.Dispose() } catch { }
    }

    if ($script:RunspacePool) {
        try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { }
        $script:RunspacePool = $null
    }

    $script:ActiveJobs = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    if (-not $Quiet) {
        Write-NexusLog 'Global search stopped' -Level INFO -Component 'Search'
    }
}

function Get-SearchResults {
    <#
    .SYNOPSIS  Drains accumulated search results from the queue. Non-blocking.
    #>
    [CmdletBinding()]
    param([int]$MaxItems = 200)

    $results = [System.Collections.ArrayList]::new()
    $item    = $null
    $count   = 0

    while ($count -lt $MaxItems -and $script:ResultQueue.TryDequeue([ref]$item)) {
        $null = $results.Add($item)
        $count++
    }

    return $results.ToArray()
}

function Get-SearchStatus {
    <#
    .SYNOPSIS  Returns current search progress.
    #>
    return [PSCustomObject]@{
        IsRunning   = ($script:CompletedServers -lt $script:TotalServers) -and (-not $script:IsCancelled) -and $script:RunspacePool
        Completed   = $script:CompletedServers
        Total       = $script:TotalServers
        QueueDepth  = $script:ResultQueue.Count
        IsCancelled = $script:IsCancelled
    }
}

Export-ModuleMember -Function Start-GlobalSearch, Stop-GlobalSearch, Get-SearchResults, Get-SearchStatus
