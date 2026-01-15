# ============================================================================
# MODULE: Config.psm1
# DESCRIPTION: Configuration management for CyberArk CLI
# ============================================================================

$Script:ConfigPath = "$PSScriptRoot/../config.json"

function Get-CACConfig {
    [CmdletBinding()]
    param()

    $defaults = @{
        PVWAURL = ""
    }

    if (Test-Path $Script:ConfigPath) {
        try {
            $saved = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in $defaults.Keys) {
                if ($saved.PSObject.Properties.Match($key)) {
                    $defaults[$key] = $saved.$key
                }
            }
        }
        catch {
            Write-Log "Failed to load config: $($_.Exception.Message)" "WARN"
        }
    }

    return [PSCustomObject]$defaults
}

function Set-CACConfig {
    [CmdletBinding()]
    param(
        [string]$PVWAURL
    )

    $config = Get-CACConfig

    if ($PVWAURL) { $config.PVWAURL = $PVWAURL }

    try {
        $config | ConvertTo-Json | Set-Content $Script:ConfigPath -Encoding UTF8
        Write-Log "Configuration saved" "DEBUG"
    }
    catch {
        Write-Log "Failed to save config: $($_.Exception.Message)" "ERROR"
    }
}

Export-ModuleMember -Function Get-CACConfig, Set-CACConfig
