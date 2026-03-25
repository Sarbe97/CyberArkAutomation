param (
    [Parameter(Mandatory=$false)]
    [string]$ForceRunType = ""
)

$ScriptName = "Main"
$RootPath = $PSScriptRoot
$LogPath = Join-Path $RootPath "Logs\$ScriptName-$(Get-Date -Format yyyyMMdd).log"
$CurrentHour = (Get-Date).Hour

# Load Utils
. (Join-Path $RootPath "Utils.ps1")

Write-Log -Message "Main execution started (Hour: $CurrentHour)" -ScriptName $ScriptName -LogPath $LogPath

# Load Config
$ConfigPath = Join-Path $RootPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Log -Message "config.json not found" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Determine scripts to run based on internal schedule
$ScriptsToRun = @()

if ($config.Schedules) {
    foreach ($sched in $config.Schedules) {
        $shouldRun = $false
        
        # Override if ForceRunType matches Group Name
        if ($ForceRunType -and $sched.Group -ieq $ForceRunType) {
            $shouldRun = $true
            Write-Log -Message "Force running group: $($sched.Group)" -ScriptName $ScriptName -LogPath $LogPath
        }
        elseif (-not $ForceRunType) {
            if ($sched.Frequency -ieq "Hourly") {
                $shouldRun = $true
            }
            elseif ($sched.Frequency -ieq "Daily" -and $sched.Hour -eq $CurrentHour) {
                $shouldRun = $true
            }
        }
        
        if ($shouldRun) {
            $ScriptsToRun += $sched.Scripts
        }
    }
}

$ScriptsToRun = $ScriptsToRun | Select-Object -Unique

if ($ScriptsToRun.Count -eq 0) {
    Write-Log -Message "No schedules matched the current time (Hour: $CurrentHour). Nothing to run." -ScriptName $ScriptName -LogPath $LogPath
}

foreach ($scriptName in $ScriptsToRun) {
    $scriptPath = Join-Path $RootPath $scriptName
    if (Test-Path $scriptPath) {
        Write-Log -Message "Launching $scriptName..." -ScriptName $ScriptName -LogPath $LogPath
        & $scriptPath
    }
    else {
        Write-Log -Message "Script not found: $scriptPath" -Level "ERROR" -ScriptName $ScriptName -LogPath $LogPath
    }
}

Write-Log -Message "Main execution completed" -ScriptName $ScriptName -LogPath $LogPath
