# ================================
# CONFIGURATION
# ================================

# List of servers (update this)
$Servers = @(
    "Server1",
    "Server2",
    "Server3"
)

# Service filters (edit as needed)
# Option 1: Prefix match (e.g., CyberArk*)
$ServicePrefix = "CyberArk*"

# Option 2: Explicit service names (leave empty if not needed)
$ServiceNames = @(
    # "CyberArk Vault",
    # "CyberArk Password Manager"
)

# Output file
$OutputFile = "C:\Temp\Server_Audit_Report.csv"

# ================================
# CREDENTIAL PROMPT
# ================================
Write-Host "Please enter credentials to connect to servers..." -ForegroundColor Cyan
$Credential = Get-Credential

# ================================
# INITIALIZE
# ================================
$Results = @()
$Total = $Servers.Count
$Count = 0

Write-Host "Starting server audit..." -ForegroundColor Green

# ================================
# MAIN LOOP
# ================================
foreach ($Server in $Servers) {

    $Count++
    $PercentComplete = ($Count / $Total) * 100

    Write-Progress -Activity "Processing Servers" `
        -Status "Connecting to $Server ($Count of $Total)" `
        -PercentComplete $PercentComplete

    Write-Host "----------------------------------------" -ForegroundColor Yellow
    Write-Host "Connecting to $Server..." -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {

            Write-Host "Connected to $env:COMPUTERNAME" -ForegroundColor Green

            # ================================
            # DISK DETAILS
            # ================================
            Write-Host "Collecting disk details..." -ForegroundColor Cyan
            $Disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
                [PSCustomObject]@{
                    Drive  = $_.DeviceID
                    SizeGB = [math]::Round($_.Size / 1GB, 2)
                    FreeGB = [math]::Round($_.FreeSpace / 1GB, 2)
                }
            }

            # ================================
            # RAM DETAILS
            # ================================
            Write-Host "Collecting RAM details..." -ForegroundColor Cyan
            $TotalRAM = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
            $RAM_GB = [math]::Round($TotalRAM / 1GB, 2)

            # ================================
            # CPU DETAILS
            # ================================
            Write-Host "Collecting CPU details..." -ForegroundColor Cyan
            $CPU = (Get-CimInstance Win32_Processor).Name

            # ================================
            # SERVICE DETAILS
            # ================================
            Write-Host "Checking CyberArk services..." -ForegroundColor Cyan

            if ($using:ServiceNames.Count -gt 0) {
                $Services = Get-Service | Where-Object {
                    $using:ServiceNames -contains $_.Name
                }
            }
            else {
                $Services = Get-Service -Name $using:ServicePrefix -ErrorAction SilentlyContinue
            }

            $ServiceInfo = $Services | ForEach-Object {
                "$($_.Name):$($_.Status)"
            } -join "; "

            # ================================
            # FINAL OBJECT
            # ================================
            foreach ($Disk in $Disks) {
                [PSCustomObject]@{
                    Server   = $env:COMPUTERNAME
                    Drive    = $Disk.Drive
                    SizeGB   = $Disk.SizeGB
                    FreeGB   = $Disk.FreeGB
                    RAM_GB   = $RAM_GB
                    CPU      = $CPU
                    Services = $ServiceInfo
                }
            }

        } -ErrorAction Stop | ForEach-Object {
            $Results += $_
        }

        Write-Host "Completed $Server successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to connect to $Server : $_" -ForegroundColor Red

        $Results += [PSCustomObject]@{
            Server   = $Server
            Drive    = "N/A"
            SizeGB   = "N/A"
            FreeGB   = "N/A"
            RAM_GB   = "N/A"
            CPU      = "N/A"
            Services = "Connection Failed"
        }
    }
}

# ================================
# EXPORT RESULTS
# ================================
Write-Host "Exporting results to $OutputFile..." -ForegroundColor Cyan

$Results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "Audit completed successfully!" -ForegroundColor Green
Write-Host "Report saved at: $OutputFile" -ForegroundColor Yellow