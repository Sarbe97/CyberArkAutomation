# Utils.psm1 - Utility helpers with approved verb names

function ConvertTo-EpochFromDays {
    [CmdletBinding()]
    param (
        [int]$DaysAgo
    )

    $date = (Get-Date).ToUniversalTime().AddDays(-$DaysAgo)
    $unixEpochStart = [DateTime]'1970-01-01T00:00:00Z'
    $epoch = [math]::Floor(($date - $unixEpochStart).TotalSeconds)
    return $epoch
}

Export-ModuleMember -Function ConvertTo-EpochFromDays
