#========================================================================
# LogViewer.psm1 — Log File Content & Viewer Support Module
# Supports: pagination, search highlighting, large file streaming
#========================================================================

function Get-LogFileContent {
    <#
    .SYNOPSIS   Reads a remote log file via UNC and returns paginated, numbered content.
    .PARAMETER  UNCFilePath     Full UNC path to the file (\\server\share\path\file.log)
    .PARAMETER  Credential      PSCredential for UNC access
    .PARAMETER  MaxLines        Max lines to return per page (default 5000)
    .PARAMETER  StartLine       1-based line to start reading from
    .PARAMETER  HighlightText   Search term to flag matching lines
    .OUTPUTS    PSCustomObject with Lines, TotalLines, IsTruncated, etc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UNCFilePath,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [int]$MaxLines      = 5000,
        [int]$StartLine     = 1,
        [string]$HighlightText = '',
        [switch]$CaseSensitive
    )

    Write-NexusLog "Opening log file: $UNCFilePath (line $StartLine, max $MaxLines)" -Level INFO -Component 'LogViewer'
    return Get-UNCFileContent -UNCFilePath $UNCFilePath -Credential $Credential `
                               -MaxLines $MaxLines -StartLine $StartLine `
                               -HighlightText $HighlightText
}

function Search-LogFile {
    <#
    .SYNOPSIS  Searches a single log file for matching lines (in-file search).
    .OUTPUTS   Array of [PSCustomObject]@{ LineNumber; Text; Context }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UNCFilePath,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$SearchText,
        [switch]$CaseSensitive,
        [int]$ContextLines = 0
    )

    Write-NexusLog "Searching '$SearchText' in: $UNCFilePath" -Level INFO -Component 'LogViewer'

    $clean  = $UNCFilePath.TrimStart('\')
    $parts  = $clean -split '\\'
    $share  = '\\' + $parts[0] + '\' + $parts[1]
    $rel    = ($parts[2..($parts.Count-1)]) -join '\'

    $driveName = "SAWLV$(Get-Random -Maximum 99999)"
    $results   = [System.Collections.ArrayList]::new()

    try {
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem `
                            -Root $share -Credential $Credential -ErrorAction Stop
        $localPath = "${driveName}:\$rel"

        $allLines  = Get-Content $localPath -ErrorAction Stop
        $lineIndex = 0

        foreach ($line in $allLines) {
            $lineIndex++
            $isMatch = if ($CaseSensitive) {
                $line.Contains($SearchText)
            } else {
                $line.ToLower().Contains($SearchText.ToLower())
            }

            if ($isMatch) {
                $null = $results.Add([PSCustomObject]@{
                    LineNumber  = $lineIndex
                    Text        = $line
                    MatchStart  = if ($CaseSensitive) { $line.IndexOf($SearchText) }
                                  else { $line.ToLower().IndexOf($SearchText.ToLower()) }
                    MatchLength = $SearchText.Length
                })
            }
        }
    }
    finally {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }

    Write-NexusLog "Search found $($results.Count) matches in $UNCFilePath" -Level INFO -Component 'LogViewer'
    return $results.ToArray()
}

function Get-LogTail {
    <#
    .SYNOPSIS  Returns the last N lines of a file (tail).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UNCFilePath,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [int]$Lines = 200
    )

    $clean  = $UNCFilePath.TrimStart('\')
    $parts  = $clean -split '\\'
    $share  = '\\' + $parts[0] + '\' + $parts[1]
    $rel    = ($parts[2..($parts.Count-1)]) -join '\'

    $driveName = "SAWTL$(Get-Random -Maximum 99999)"
    try {
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem `
                            -Root $share -Credential $Credential -ErrorAction Stop
        $localPath = "${driveName}:\$rel"

        $allLines   = Get-Content $localPath -ErrorAction Stop
        $arr        = @($allLines)
        $totalLines = $arr.Count
        $start      = [Math]::Max(1, $totalLines - $Lines + 1)
        $slice      = $arr | Select-Object -Last $Lines

        $numbered = for ($i = 0; $i -lt @($slice).Count; $i++) {
            [PSCustomObject]@{
                LineNumber = $start + $i
                Text       = $slice[$i]
                IsMatch    = $false
            }
        }

        return [PSCustomObject]@{
            Lines      = @($numbered)
            TotalLines = $totalLines
            StartLine  = $start
            EndLine    = $totalLines
            IsTruncated = $false
            FilePath   = $UNCFilePath
        }
    }
    finally {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Get-LogFileContent, Search-LogFile, Get-LogTail
