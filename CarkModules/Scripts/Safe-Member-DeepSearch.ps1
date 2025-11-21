# Safe-Member-DeepSearch.ps1

Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Verbose -DisableNameChecking
Import-Module "$PSScriptRoot\..\Modules\CyberArkAPIs.psm1" -Verbose -DisableNameChecking

# ---- Login ----
$pvwaUrl = Get-PvwaUrlFromConfigOrPrompt
$session = Connect-CyberArk -PvwaUrl $pvwaUrl

try {
    # ---- Safe name input ----
    Write-Host "`nSafe name input:"
    Write-Host "  1. Enter one or more Safe Names (comma separated)"
    Write-Host "  2. Load Safe Names from a CSV file"
    $inputChoice = Read-Host "Enter 1 or 2"
    $safeNames = @()
    if ($inputChoice -eq '1') {
        $inputSafeNames = Read-Host "Enter Safe Name(s) (comma separated if more than one)"
        $safeNames = $inputSafeNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    } elseif ($inputChoice -eq '2') {
        $csvPath = Read-Host "Enter path to Safe names CSV file (column: SafeName)"
        $safeNames = (Import-Csv -Path $csvPath | Select-Object -ExpandProperty SafeName) | Where-Object { $_ -ne $null -and $_ -ne "" }
    } else {
        throw "Invalid input method selection."
    }

    # ---- Member search string ----
    $memberSearch = Read-Host "Enter member search string (leave empty to get all members)"

    $allResults = @()
    foreach ($safe in $safeNames) {
        Write-Host "Getting members for safe: $safe"
        $members = Get-CyberArkSafeMembers -PvwaUrl $pvwaUrl -Token $session.Token -SafeName $safe

        # Filter within the script:
        if ($memberSearch) {
            $members = $members | Where-Object { $_.memberName -like "*$memberSearch*" }
        }

        foreach ($mem in $members) {
            $basicObj = [PSCustomObject]@{
                SafeName   = $safe
                MemberName = $mem.memberName
                MemberType = $mem.memberType
                MemberId   = $mem.memberId
                Permissions= ($mem.permissions | ConvertTo-Json -Compress)
            }
            $allResults += $basicObj

            # If memberType is Group, resolve the group's users
            if ($mem.memberType -eq "Group" -and $mem.memberId) {
                $groupUsers = Get-CyberArkUserGroupMembers -PvwaUrl $pvwaUrl -Token $session.Token -GroupId $mem.memberId
                foreach ($u in $groupUsers) {
                    $deepObj = [PSCustomObject]@{
                        SafeName   = $safe
                        MemberName = "$($mem.memberName) (Member)"
                        MemberType = "UserInGroup"
                        MemberId   = $u.id
                        Permissions= "Inherited from Group"
                        GroupUser  = $u.UserName
                    }
                    $allResults += $deepObj
                }
            }
        }
    }

    if ($safeNames.Count -eq 1) {
        $allResults | Format-Table -AutoSize | Out-Host
    } else {
        $outfile = "SafeMemberDeepSearch_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
        $allResults | Export-Csv -Path $outfile -NoTypeInformation -Encoding UTF8
        Write-Host "`nOutput exported to $outfile"
    }

}
finally {
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
}
