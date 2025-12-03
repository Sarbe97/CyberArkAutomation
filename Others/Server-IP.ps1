# Input CSV Path
$InputCSV = "C:\Temp\Servers.csv"

# Output CSV Path
$OutputCSV = "C:\Temp\ServerIPReport.csv"

# Read input servers
$servers = Import-Csv $InputCSV

$results = foreach ($item in $servers) {
    $server = $item.Server.Trim()

    # Test connectivity
    $ping = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue

    if ($ping) {
        try {
            $dns = Resolve-DnsName -Name $server -ErrorAction Stop
            
            # Extract only IPv4 A records
            $ipList = ($dns | Where-Object { $_.Type -eq "A" }).IPAddress -join ", "

            [PSCustomObject]@{
                Server    = $server
                Status    = "Success"
                IPAddress = $ipList
            }
        }
        catch {
            [PSCustomObject]@{
                Server    = $server
                Status    = "DNS Resolve Failed"
                IPAddress = ""
            }
        }
    }
    else {
        # If ping fails, no further details needed
        [PSCustomObject]@{
            Server    = $server
            Status    = "Failed"
            IPAddress = ""
        }
    }
}

# Export to CSV
$results | Export-Csv $OutputCSV -NoTypeInformation

Write-Host "Report generated: $OutputCSV"
