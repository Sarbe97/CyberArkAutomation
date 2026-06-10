# ================================
# CONFIGURATION
# ================================

$Servers = @(
    "Server1",
    "Server2",
    "Server3"
)

$Timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$OutputFile = "C:\Temp\Server_Audit_Report_$Timestamp.csv"

# ================================
# CREDENTIALS
# ================================
Write-Host "Enter PRIMARY credential" -ForegroundColor Cyan
$Cred1 = Get-Credential

Write-Host "Enter SECONDARY credential (fallback)" -ForegroundColor Cyan
$Cred2 = Get-Credential

# ================================
# INITIALIZE
# ================================
$Results = @()
$Total = $Servers.Count
$Count = 0

Write-Host "Starting server audit..." -ForegroundColor Green

# ================================
# FUNCTION: GET SERVER DATA
# ================================
function Get-ServerData {
    param ($Server, $Credential)

    Invoke-Command -ComputerName $Server `
        -Credential $Credential `
        -Authentication Negotiate `
        -SessionOption (New-PSSessionOption -NoMachineProfile) `
        -ScriptBlock {

        # DISK
        $Disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            [PSCustomObject]@{
                Drive  = $_.DeviceID
                SizeGB = [math]::Round($_.Size / 1GB, 2)
                FreeGB = [math]::Round($_.FreeSpace / 1GB, 2)
            }
        }

        # RAM
        $TotalRAM = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        $RAM_GB = [math]::Round($TotalRAM / 1GB, 2)

        # CPU
        $CPU = (Get-CimInstance Win32_Processor).Name
        
        $CurrentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        foreach ($Disk in $Disks) {
            [PSCustomObject]@{
                Timestamp = $CurrentTime
                Server    = $env:COMPUTERNAME
                Drive     = $Disk.Drive
                SizeGB    = $Disk.SizeGB
                FreeGB    = $Disk.FreeGB
                RAM_GB    = $RAM_GB
                CPU       = $CPU
            }
        }

    } -ErrorAction Stop
}

# ================================
# MAIN LOOP
# ================================
foreach ($Server in $Servers) {

    $Count++
    $PercentComplete = ($Count / $Total) * 100

    Write-Progress -Activity "Processing Servers" `
        -Status "Processing $Server ($Count of $Total)" `
        -PercentComplete $PercentComplete

    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Processing: $Server" -ForegroundColor Cyan

    # ----------------------------
    # STEP 1: PING CHECK
    # ----------------------------
    if (-not (Test-Connection -ComputerName $Server -Count 1 -Quiet)) {
        Write-Host "Ping FAILED for $Server" -ForegroundColor Red

        $Results += [PSCustomObject]@{
            Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Server         = $Server
            Drive          = "N/A"
            SizeGB         = "N/A"
            FreeGB         = "N/A"
            RAM_GB         = "N/A"
            CPU            = "N/A"
            CredentialUsed = "None"
            Status         = "Ping Failed"
        }
        continue
    }
    else {
        Write-Host "Ping SUCCESS" -ForegroundColor Green
    }

    # ----------------------------
    # STEP 2: WINRM CHECK
    # ----------------------------
    try {
        Test-WsMan $Server -ErrorAction Stop | Out-Null
        Write-Host "WinRM OK" -ForegroundColor Green
    }
    catch {
        Write-Host "WinRM FAILED on $Server" -ForegroundColor Red

        $Results += [PSCustomObject]@{
            Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Server         = $Server
            Drive          = "N/A"
            SizeGB         = "N/A"
            FreeGB         = "N/A"
            RAM_GB         = "N/A"
            CPU            = "N/A"
            CredentialUsed = "None"
            Status         = "WinRM Failed"
        }
        continue
    }

    $Success = $false

    # ----------------------------
    # STEP 3: TRY PRIMARY
    # ----------------------------
    Write-Host "Trying PRIMARY credential..." -ForegroundColor Cyan

    try {
        $Data = Get-ServerData -Server $Server -Credential $Cred1
        $Data | ForEach-Object { 
            $_ | Add-Member -NotePropertyName CredentialUsed -NotePropertyValue "Primary"
            $_ | Add-Member -NotePropertyName Status -NotePropertyValue "Success"
        }
        $Results += $Data

        Write-Host "SUCCESS with PRIMARY credential" -ForegroundColor Green
        $Success = $true
    }
    catch {
        Write-Host "Primary failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    # ----------------------------
    # STEP 4: TRY SECONDARY
    # ----------------------------
    if (-not $Success) {
        Write-Host "Trying SECONDARY credential..." -ForegroundColor Cyan

        try {
            $Data = Get-ServerData -Server $Server -Credential $Cred2
            $Data | ForEach-Object { 
                $_ | Add-Member -NotePropertyName CredentialUsed -NotePropertyValue "Secondary"
                $_ | Add-Member -NotePropertyName Status -NotePropertyValue "Success"
            }
            $Results += $Data

            Write-Host "SUCCESS with SECONDARY credential" -ForegroundColor Green
            $Success = $true
        }
        catch {
            Write-Host "Secondary failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ----------------------------
    # FINAL FAILURE
    # ----------------------------
    if (-not $Success) {
        $Results += [PSCustomObject]@{
            Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Server         = $Server
            Drive          = "N/A"
            SizeGB         = "N/A"
            FreeGB         = "N/A"
            RAM_GB         = "N/A"
            CPU            = "N/A"
            CredentialUsed = "None"
            Status         = "Connection Failed (Both Creds)"
        }
    }
}

# ================================
# EXPORT
# ================================
Write-Host "Exporting results..." -ForegroundColor Cyan
$Results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "Completed! File saved at $OutputFile" -ForegroundColor Green