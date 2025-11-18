# Load logic module
. "./modules/Logic.ps1"

# Load settings
$settings = Load-Settings

# Ensure arrays
$connectors = @($settings.connectors)

# Build dropdown items like "12.0.0.0 - CPM"
$addrList = @()
foreach ($a in $settings.addresses) {
    $addrList += "$($a.address) - $($a.alias)"
}

# GUI call ONCE
$result = & "./modules/Gui.ps1" `
    -Addresses $addrList `
    -SavedUsername $settings.username `
    -SavedTarget $settings.targetAccount `
    -Connectors $connectors

if (-not $result) { exit }

# Save username + target account
$settings.username = $result.Username
$settings.targetAccount = $result.TargetAccount

# SAVE NEW ADDRESS + ALIAS
if ($result.Address -and $result.Alias) {

    $match = $settings.addresses |
        Where-Object { $_.address -eq $result.Address }

    if (-not $match) {
        $settings.addresses += @(
            @{
                address = $result.Address
                alias   = $result.Alias
            }
        )
    }
}

Save-Settings $settings

# Build RDP
$rdpPath = "rdp-$($result.Address).rdp"
$template = "templates/base.rdp"

$rdpContent = Build-RDPFile -Template $template `
                           -Username $result.Username `
                           -TargetAccount $result.TargetAccount `
                           -Address $result.Address `
                           -Connector $result.Connector

$rdpContent | Set-Content $rdpPath

# Launch RDP
Launch-RDP $rdpPath
