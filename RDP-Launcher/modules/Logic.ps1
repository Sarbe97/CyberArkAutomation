function Load-Settings {
    $path = "config/settings.json"
    if (-not (Test-Path $path)) {
        throw "settings.json not found in config/"
    }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Save-Settings($settings) {
    $settings | ConvertTo-Json -Depth 5 | Set-Content "config/settings.json"
}

function Build-RDPFile($Template, $Username, $TargetAccount, $Address, $Connector) {
    $content = Get-Content $Template -Raw
    $content = $content -replace "<username>",      $Username
    $content = $content -replace "<targetAccount>", $TargetAccount
    $content = $content -replace "<address>",       $Address
    $content = $content -replace "<connector>",     $Connector
    return $content
}

function Launch-RDP($FilePath) {
    Start-Process $FilePath
}
