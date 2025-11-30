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

    $obj = @{
        PVWAURL = $PVWAURL
    }

    $obj | ConvertTo-Json | Out-File $path -Encoding UTF8
}

Export-ModuleMember -Function Get-CACConfig, Set-CACConfig
