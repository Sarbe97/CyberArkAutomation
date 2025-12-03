
Write-Host "`n===================================================="
Write-Host "  REMOTE USER & GROUP COLLECTION SCRIPT"
Write-Host "====================================================`n"

#-------------------------------------------
# Get input mode
#-------------------------------------------
Write-Host "Choose Input Mode:"
Write-Host "1. Enter servers manually"
Write-Host "2. Load from CSV file (column: Server)"
$mode = Read-Host "Enter 1 or 2"

$servers = @()
$useCsv = $false

if ($mode -eq "1") {
    $servers = (Read-Host "Enter comma-separated server names").Split(",") | ForEach-Object { $_.Trim() }
}
elseif ($mode -eq "2") {
    $csvPath = Read-Host "Enter full CSV path"
    if (!(Test-Path $csvPath)) {
        Write-Host "CSV file not found! Exiting." -ForegroundColor Red
        exit
    }
    $servers = Import-Csv $csvPath | Select-Object -ExpandProperty Server
    $useCsv = $true
}
else {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    exit
}

# Test WSMan connectivity
Write-Host "`nTesting remote WSMan connectivity..." -ForegroundColor Yellow
$validServers = @()

foreach ($srv in $servers) {
    try {
        Test-WSMan -ComputerName $srv -ErrorAction Stop | Out-Null
        Write-Host "SUCCESS: $srv reachable" -ForegroundColor Green
        $validServers += $srv
    }
    catch {
        Write-Host "FAILED: $srv not reachable" -ForegroundColor Red
    }
}

if ($validServers.Count -eq 0) {
    Write-Host "No reachable servers found. Exiting." -ForegroundColor Red
    exit
}

# Get credential
Write-Host "`nEnter domain credentials:"
$cred = Get-Credential

#-------------------------------------------
# Collect data
#-------------------------------------------
$final = @()

foreach ($srv in $validServers) {

    Write-Host "`n=============================="
    Write-Host " Querying $srv"
    Write-Host "=============================="

    #------------------------------
    # Fetch Local Users
    #------------------------------
    Write-Host " -> Getting local users..."

    try {
        $users = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
            Get-LocalUser | Select-Object Name, Enabled, Description, LastLogon
        }

        foreach ($u in $users) {
            $final += [pscustomobject]@{
                Server      = $srv
                Type        = "User"
                GroupName   = "-"
                MemberName  = $u.Name
                MemberType  = "LocalUser"
                Enabled     = $u.Enabled
                Description = $u.Description
                LastLogon   = $u.LastLogon
            }
        }
    }
    catch {
        Write-Host "ERROR fetching users from $srv" -ForegroundColor Red
    }

    #------------------------------
    # Fetch Groups + Members
    #------------------------------
    Write-Host " -> Getting local groups and members..."

    try {
        $groups = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
            Get-LocalGroup | Select-Object Name, Description
        }

        foreach ($g in $groups) {
            $members = Invoke-Command -ComputerName $srv -Credential $cred -ScriptBlock {
                param($grp)
                Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue | 
                    Select-Object Name, ObjectClass, PrincipalSource
            } -ArgumentList $g.Name

            foreach ($m in $members) {
                $final += [pscustomobject]@{
                    Server      = $srv
                    Type        = "GroupMember"
                    GroupName   = $g.Name
                    MemberName  = $m.Name
                    MemberType  = $m.ObjectClass
                    Enabled     = "-"
                    Description = $g.Description
                    LastLogon   = "-"
                }
            }
        }
    }
    catch {
        Write-Host "ERROR fetching group details from $srv" -ForegroundColor Red
    }

    Write-Host " -> Completed: $srv" -ForegroundColor Green
}

#-------------------------------------------
# OUTPUT
#-------------------------------------------
if ($useCsv -eq $false) {
    Write-Host "`n===== FINAL OUTPUT =====" -ForegroundColor Cyan
    $final | Format-Table -AutoSize
}
else {
    $time = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $base = [IO.Path]::GetFileNameWithoutExtension($csvPath)
    $folder = Split-Path $csvPath
    $outfile = Join-Path $folder "$base-output-$time.csv"

    $final | Export-Csv -Path $outfile -NoTypeInformation
    Write-Host "`nOutput saved to: $outfile" -ForegroundColor Green
}

Write-Host "`nDone!" -ForegroundColor Cyan
