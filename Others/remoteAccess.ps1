
Write-Host "===================================================="
Write-Host " FETCH LOCAL USERS & GROUPS FROM REMOTE SERVERS"
Write-Host "====================================================`n"

#-------------------------------------------------------
# Ask the user for input mode
#-------------------------------------------------------
Write-Host "Choose Input Mode:"
Write-Host "1. Enter servers manually"
Write-Host "2. Load from CSV file (column name: Server)"
$mode = Read-Host "Enter 1 or 2"

#-------------------------------------------------------
# Load servers list
#-------------------------------------------------------
$servers = @()

if ($mode -eq "1") {
    $userInput = Read-Host "Enter server names separated by commas"
    $servers = $userInput.Split(",") | ForEach-Object { $_.Trim() }
    $useCsv = $false
}
elseif ($mode -eq "2") {
    $csvPath = Read-Host "Enter full path of CSV file"
    if (!(Test-Path $csvPath)) {
        Write-Host "CSV file does not exist! Exiting." -ForegroundColor Red
        exit
    }
    $servers = Import-Csv $csvPath | Select-Object -ExpandProperty Server
    $useCsv = $true
}
else {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    exit
}

Write-Host "`nServers to be checked:" -ForegroundColor Cyan
$servers | ForEach-Object { Write-Host " - $_" }

Write-Host "`nPerforming WSMan connectivity check..." -ForegroundColor Yellow

#-------------------------------------------------------
# Test connectivity (No credential needed)
#-------------------------------------------------------
$validServers = @()

foreach ($srv in $servers) {
    try {
        if (Test-WSMan -ComputerName $srv -ErrorAction Stop) {
            Write-Host "SUCCESS: WSMan available on $srv" -ForegroundColor Green
            $validServers += $srv
        }
    }
    catch {
        Write-Host "FAILED: Cannot reach $srv via WSMan." -ForegroundColor Red
    }
}

if ($validServers.Count -eq 0) {
    Write-Host "`nNo servers passed WSMan test. Exiting." -ForegroundColor Red
    exit
}

Write-Host "`nValid servers ready for querying:" -ForegroundColor Cyan
$validServers | ForEach-Object { Write-Host " - $_" }

#-------------------------------------------------------
# Ask for credentials only now
#-------------------------------------------------------
Write-Host "`nPlease enter domain credentials to query local accounts."
$cred = Get-Credential

#-------------------------------------------------------
# Query servers
#-------------------------------------------------------
$finalResults = @()

foreach ($srv in $validServers) {
    Write-Host "`n============================================="
    Write-Host " Querying server: $srv"
    Write-Host "============================================="

    try {
        # Get Local Users
        Write-Host " -> Fetching local users..."
        $users = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
            Get-LocalUser | Select-Object Name, Enabled, Description, LastLogon
        }

        foreach ($u in $users) {
            $finalResults += [pscustomobject]@{
                Server      = $srv
                Type        = "User"
                Name        = $u.Name
                Enabled     = $u.Enabled
                Description = $u.Description
                Members     = "-"
                LastLogon   = $u.LastLogon
            }
        }

        # Get Local Groups
        Write-Host " -> Fetching local groups..."
        $groups = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
            Get-LocalGroup | Select-Object Name, Description
        }

        foreach ($g in $groups) {
            Write-Host "    -> Group: $($g.Name)"

            $members = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
                param($grp) 
                Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue | Select-Object Name
            } -ArgumentList $g.Name

            $memberList = ($members.Name) -join "; "

            $finalResults += [pscustomobject]@{
                Server      = $srv
                Type        = "Group"
                Name        = $g.Name
                Enabled     = "-"
                Description = $g.Description
                Members     = $memberList
                LastLogon   = "-"
            }
        }

        Write-Host " -> Completed: $srv" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR querying $srv : $_" -ForegroundColor Red
    }
}

#-------------------------------------------------------
# Output handling
#-------------------------------------------------------
if ($useCsv -eq $false) {
    Write-Host "`n============ FINAL OUTPUT ============" -ForegroundColor Cyan
    $finalResults | Format-Table -AutoSize
}
else {
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $base = [System.IO.Path]::GetFileNameWithoutExtension($csvPath)
    $folder = Split-Path $csvPath
    $outputPath = Join-Path $folder "$base-output-$timestamp.csv"

    $finalResults | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nOutput CSV saved to:" -ForegroundColor Green
    Write-Host "$outputPath"
}

Write-Host "`nScript Completed." -ForegroundColor Cyan
