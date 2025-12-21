function Get-CACConfig {
    $path = Join-Path $PSScriptRoot "..\config.json"

    if (Test-Path $path) {
        return Get-Content $path | ConvertFrom-Json
    }

    return @{ PVWAURL = "" }
}

function Set-CACConfig {
    param([string]$PVWAURL)

    $path = Join-Path $PSScriptRoot "..\config.json"
    
    # 1. Read existing config to preserve other keys
    if (Test-Path $path) {
        try {
            $currentConfig = Get-Content $path -Raw | ConvertFrom-Json
        }
        catch {
            $currentConfig = [PSCustomObject]@{}
        }
    }
    else {
        $currentConfig = [PSCustomObject]@{}
    }

    # 2. Update PVWAURL if provided
    if (-not [string]::IsNullOrWhiteSpace($PVWAURL)) {
        if ($currentConfig.PSObject.Properties.Match('PVWAURL').Count) {
            $currentConfig.PVWAURL = $PVWAURL
        }
        else {
            $currentConfig | Add-Member -MemberType NoteProperty -Name "PVWAURL" -Value $PVWAURL
        }
    }

    # 3. Write back with sufficient depth
    $currentConfig | ConvertTo-Json -Depth 10 | Out-File $path -Encoding UTF8
}

Export-ModuleMember -Function Get-CACConfig, Set-CACConfig
