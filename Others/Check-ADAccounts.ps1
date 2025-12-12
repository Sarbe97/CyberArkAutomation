
# Hardcoded CSV Path - PLEASE UPDATE THIS PATH
$CsvPath = "C:\Path\To\Your\Input.csv"

# Check if RSAT is installed/Module available
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Warning "ActiveDirectory module is not found. Please install RSAT."
}

# Import CSV
if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found at $CsvPath. Please update the `$CsvPath variable in the script."
    exit
}

$InputFileInfo = Get-Item $CsvPath
$OutputPath = Join-Path -Path $InputFileInfo.DirectoryName -ChildPath ($InputFileInfo.BaseName + "-op" + $InputFileInfo.Extension)

try {
    $InputData = Import-Csv -Path $CsvPath
}
catch {
    Write-Error "Failed to import CSV: $_"
    exit
}

$Results = @()

foreach ($Row in $InputData) {
    $AccountName = $Row.AccountName
    $DomainName = $Row.DomainName

    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        Write-Warning "Skipping row with empty AccountName"
        continue
    }

    $ResultObject = [PSCustomObject]@{
        InputAccountName = $AccountName
        InputDomain      = $DomainName
        IsPresent        = $false
        SamAccountName   = $null
        Enabled          = $null
        LastLogonDate    = $null
        DistinguishedName = $null
        Error            = $null
    }

    try {
        # Construct parameters for Get-ADUser
        $ADParams = @{
            Identity = $AccountName
            Properties = "LastLogonDate", "Enabled"
            ErrorAction = "Stop"
        }
        
        if (-not [string]::IsNullOrWhiteSpace($DomainName)) {
            $ADParams["Server"] = $DomainName
        }

        $ADUser = Get-ADUser @ADParams

        $ResultObject.IsPresent = $true
        $ResultObject.SamAccountName = $ADUser.SamAccountName
        $ResultObject.Enabled = $ADUser.Enabled
        $ResultObject.LastLogonDate = $ADUser.LastLogonDate
        $ResultObject.DistinguishedName = $ADUser.DistinguishedName
        
        Write-Host "Found user: $AccountName in $DomainName" -ForegroundColor Green

    }
    catch {
        $ErrorMessage = $_.Exception.Message
        if ($ErrorMessage -like "*Cannot find an object with identity*") {
            $ResultObject.Error = "User not found"
            Write-Host "User not found: $AccountName in $DomainName" -ForegroundColor Yellow
        }
        else {
            $ResultObject.Error = $ErrorMessage
            Write-Host "Error checking $AccountName : $ErrorMessage" -ForegroundColor Red
        }
    }

    $Results += $ResultObject
}

# Export Results
try {
    $Results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "Results exported to $OutputPath" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to export results: $_"
}
