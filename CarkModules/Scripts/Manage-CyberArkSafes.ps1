# Manage-CyberArkSafes.ps1

# Helper for module reload to ensure latest code
$modulesToReload = @('Auth', 'CyberArkAPIs')
foreach ($mod in $modulesToReload) {
    if (Get-Module -Name $mod) {
        Remove-Module -Name $mod -Force -ErrorAction SilentlyContinue
    }
}

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking

# ---- 1. Login ----
$pvwaUrl = Get-PvwaUrlFromConfigOrPrompt
$session = Connect-CyberArk -PvwaUrl $pvwaUrl

try {
    # ---- 2. Ask for input method ----
    Write-Host "`nSelect Safe input method:"
    Write-Host "  1. One Safe Name (manual entry)"
    Write-Host "  2. Upload a CSV file with Safe Names"
    $inputChoice = Read-Host "Enter 1 or 2"
    $safeNames = @()

    if ($inputChoice -eq '1') {
        $safeName = Read-Host "Enter Safe Name"
        $safeNames = @($safeName)
    }
    elseif ($inputChoice -eq '2') {
        $csvPath = Read-Host "Enter path to Safe names CSV file (column: SafeName)"
        $safeNames = (Import-Csv -Path $csvPath | Select-Object -ExpandProperty SafeName) | Where-Object { $_ -ne $null -and $_ -ne "" }
    }
    else {
        throw "Invalid input method selection."
    }

    # ---- 3. Ask for operation type ----
    Write-Host "`nSelect operation type:"
    Write-Host "  1. Add Safe"
    Write-Host "  2. Get Safe Details"
    Write-Host "  3. Get All Safe Members"
    $opChoice = Read-Host "Enter 1, 2, or 3"

    # ---- 4. Process Choice ----
    $results = @()
    foreach ($sn in $safeNames) {
        switch ($opChoice) {
            '1' {
                $result = Add-CyberArkSafe -PvwaUrl $pvwaUrl -Token $session.Token -SafeName $sn
                $results += $result
            }
            '2' {
                $result = Get-CyberArkSafeDetails -PvwaUrl $pvwaUrl -Token $session.Token -SafeName $sn
                $results += $result
            }
            '3' {
                $members = Get-CyberArkSafeMembers -PvwaUrl $pvwaUrl -Token $session.Token -SafeName $sn
                foreach ($mem in $members) {
                    $mem.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty('SafeName', $sn)))
                    $results += $mem
                }
            }
        }
    }

    # ---- 5. Output results ----
    if ($inputChoice -eq '1') {
        # Manual entry: show on screen
        if ($opChoice -eq '3') {
            $results | Select-Object SafeName, memberName, memberType, isPredefinedUser, permissions | Format-Table -AutoSize
        }
        else {
            $results | Format-List
        }
    }
    else {
        # Bulk: export to CSV
        $time = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvOut = switch ($opChoice) {
            '1' { "AddSafes_$time.csv" }
            '2' { "SafeDetails_$time.csv" }
            '3' { "SafeMembers_$time.csv" }
        }
        $outPath = Join-Path (Get-Location) $csvOut
        $results | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
        Write-Host "`nOutput exported to $outPath"
    }
}
finally {
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
}
