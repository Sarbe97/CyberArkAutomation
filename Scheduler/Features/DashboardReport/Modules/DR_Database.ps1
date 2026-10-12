# =============================================================================
# DR_Database.ps1
# Handles database queries against the CyberArk EVD (Export Vault Data) database
# to retrieve CPM failure error messages and Windows Return Codes (winRC).
# Exposes: Get-EVDAccountErrors
# =============================================================================

function Get-EVDAccountErrors {
    param (
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$DatabaseConfig,

        [array]$AccountIds = @(),

        [PSCustomObject]$GlobalCCPConfig = $null,
        [switch]$ManualLogin,
        [string]$ScriptName = "DashboardReport",
        [string]$LogPath
    )

    $errorLookup = @{}

    if ($null -eq $DatabaseConfig -or -not $DatabaseConfig.Enabled) {
        Write-Log -Message "EVD Database integration is disabled or not configured in config.json. Skipping error enrichment." -ScriptName $ScriptName -LogPath $LogPath
        return $errorLookup
    }

    try {
        # Ensure System.Data assembly is available for ADO.NET
        Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

        $server   = if ($DatabaseConfig.Server) { $DatabaseConfig.Server } else { "localhost" }
        $database = if ($DatabaseConfig.Database) { $DatabaseConfig.Database } else { "CyberArkEVD" }
        $timeout  = if ($DatabaseConfig.ConnectionTimeoutSec) { [int]$DatabaseConfig.ConnectionTimeoutSec } else { 15 }

        Write-Log -Message "Connecting to EVD database '$database' on '$server'..." -ScriptName $ScriptName -LogPath $LogPath

        # Build Connection String
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder.DataSource = $server
        $builder.InitialCatalog = $database
        $builder.ConnectTimeout = $timeout

        if ($DatabaseConfig.UseIntegratedSecurity) {
            # Windows Authentication (e.g. for AD service account such as nadev\kadevd)
            $builder.IntegratedSecurity = $true
            Write-Log -Message "Using Windows Integrated Authentication for EVD database connection." -ScriptName $ScriptName -LogPath $LogPath
        }
        else {
            # Credential resolution (Direct credentials -> CCP -> Manual Login)
            $dbCred = $null
            $hasDirect = (-not [string]::IsNullOrWhiteSpace($DatabaseConfig.Username)) -and (-not [string]::IsNullOrWhiteSpace($DatabaseConfig.Password))

            if ($hasDirect) {
                Write-Log -Message "Using direct database credentials for user '$($DatabaseConfig.Username)'." -ScriptName $ScriptName -LogPath $LogPath
                $dbCred = @{
                    Username = $DatabaseConfig.Username
                    Password = $DatabaseConfig.Password
                }
            }
            elseif ($DatabaseConfig.CCP -and $DatabaseConfig.CCP.AppId -and $DatabaseConfig.CCP.Safe -and $DatabaseConfig.CCP.Object) {
                $ccpUrl = if ($DatabaseConfig.CCP.Url) { $DatabaseConfig.CCP.Url } elseif ($GlobalCCPConfig -and $GlobalCCPConfig.Url) { $GlobalCCPConfig.Url } else { "" }
                $ccpCfg = [PSCustomObject]@{
                    Url    = $ccpUrl
                    AppId  = $DatabaseConfig.CCP.AppId
                    Safe   = $DatabaseConfig.CCP.Safe
                    Object = $DatabaseConfig.CCP.Object
                }
                Write-Log -Message "Retrieving EVD database password from CCP ($($DatabaseConfig.CCP.Safe)/$($DatabaseConfig.CCP.Object))..." -ScriptName $ScriptName -LogPath $LogPath
                $dbCred = Get-CCPCredential -CCPConfig $ccpCfg -ScriptName $ScriptName -LogPath $LogPath
            }
            elseif ($ManualLogin) {
                Write-Log -Message "Prompting for manual EVD database credentials..." -ScriptName $ScriptName -LogPath $LogPath
                $prompt = Get-Credential -UserName $DatabaseConfig.Username -Message "Enter EVD Database Credentials"
                $dbCred = @{
                    Username = $prompt.UserName
                    Password = $prompt.GetNetworkCredential().Password
                }
            }

            if ($dbCred) {
                $builder.UserID = $dbCred.Username
                $builder.Password = $dbCred.Password
                $builder.IntegratedSecurity = $false
            }
            else {
                # Fallback to Integrated Security if no explicit password could be resolved
                Write-Log -Message "No explicit DB password found; falling back to Windows Integrated Security." -ScriptName $ScriptName -LogPath $LogPath
                $builder.IntegratedSecurity = $true
            }
        }

        # Build SQL Query against CAObjectProperties
        # CONCAT(op.CAOPSafeId, '_', op.CAOPFileId) matches the REST API AccountID format
        $sql = "SELECT 
                    CONCAT(op.CAOPSafeId, '_', op.CAOPFileId) AS AccountID,
                    op.CAOPObjectPropertyValue AS ErrorMessage
                FROM CAObjectProperties op
                WHERE op.CAOPObjectPropertyName = 'CPMErrorDetails'
                  AND op.CAOPObjectPropertyValue IS NOT NULL"

        if ($AccountIds -and $AccountIds.Count -gt 0) {
            # Sanitize IDs to numeric_numeric format (e.g. '123_45') to prevent SQL injection
            $sanitizedIds = @($AccountIds | Where-Object { $_ -match '^\d+_\d+$' } | ForEach-Object { "'$_'" })
            if ($sanitizedIds.Count -gt 0) {
                $idList = $sanitizedIds -join ','
                $sql += " AND CONCAT(op.CAOPSafeId, '_', op.CAOPFileId) IN ($idList)"
            }
        }

        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $command.CommandTimeout = 30

        $reader = $command.ExecuteReader()
        $matchCount = 0
        while ($reader.Read()) {
            $accId  = "$($reader['AccountID'])"
            $errMsg = "$($reader['ErrorMessage'])"
            if (-not [string]::IsNullOrWhiteSpace($accId) -and -not [string]::IsNullOrWhiteSpace($errMsg)) {
                $errorLookup[$accId] = $errMsg.Trim()
                $matchCount++
            }
        }

        $reader.Close()
        $connection.Close()

        Write-Log -Message "Successfully retrieved $matchCount CPM error details from EVD database." -ScriptName $ScriptName -LogPath $LogPath
    }
    catch {
        # Resilient error handling: DB failure must never break the main reporting workflow
        Write-Log -Message "Warning: EVD Database query failed: $($_.Exception.Message). Continuing without database enrichment." -Level "WARN" -ScriptName $ScriptName -LogPath $LogPath
    }

    return $errorLookup
}
