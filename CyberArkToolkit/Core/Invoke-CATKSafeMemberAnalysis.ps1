function Invoke-CATKSafeMemberAnalysis {
    <#
    .SYNOPSIS
        Retrieves safe members and resolves group members & enrichment.

    .DESCRIPTION
        - Gets safe members
        - If member is a Vault Group, expands to group members
        - Enriches user info from cache
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Session,
        [Parameter(Mandatory=$true)][string] $SafeName
    )

    try {
        $members = Get-PASSafeMember -Session $Session.Session -SafeName $SafeName -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to get safe members: $_"
        return @()
    }

    $output = @()

    foreach ($m in $members) {

        # If this is a group - expand members
        if ($m.memberType -eq "Vault" -and $m.memberName) {
            try {
                $groupMembers = Get-PASGroupMember -Session $Session.Session -GroupId $m.memberName -ErrorAction Stop
            }
            catch {
                $groupMembers = @()
            }

            foreach ($gm in $groupMembers) {
                $u = Get-CATKCachedUser -Username $gm.username

                $fullname = if ($u) { "$($u.firstName) $($u.middleName) $($u.lastName)".Trim() } else { "" }

                $output += [PSCustomObject]@{
                    SafeName   = $SafeName
                    MemberName = $gm.username
                    Display    = $gm.displayName
                    SourceType = "Group:$($m.memberName)"
                    FullName   = $fullname
                }
            }
        }
        else {
            # regular user
            $u = Get-CATKCachedUser -Username $m.memberName
            $fullname = if ($u) { "$($u.firstName) $($u.middleName) $($u.lastName)".Trim() } else { "" }

            $output += [PSCustomObject]@{
                SafeName   = $SafeName
                MemberName = $m.memberName
                Display    = $m.memberName
                SourceType = $m.memberType
                FullName   = $fullname
            }
        }
    }

    return $output
}
