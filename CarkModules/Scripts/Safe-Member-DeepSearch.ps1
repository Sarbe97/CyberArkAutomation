# Safe-Member-DeepSearch.ps1

. "$PSScriptRoot\..\Helpers\Reload-Modules.ps1"

# ---- Login ----
Write-Host "[INFO] Starting Safe Member Deep Search script..." -ForegroundColor Cyan
$pvwaUrl = Get-PvwaUrlFromConfigOrPrompt
Write-Host "[INFO] PVWA URL configured: $pvwaUrl" -ForegroundColor Cyan

Write-Host "[INFO] Attempting to connect to CyberArk..." -ForegroundColor Cyan
$session = Connect-CyberArk -PvwaUrl $pvwaUrl
Write-Host "[SUCCESS] Connected successfully. Token received." -ForegroundColor Green

try {
    # ---- Safe name input ----
    Write-Host "`n[INPUT] Safe name input:" -ForegroundColor Yellow
    Write-Host "  1. Enter one or more Safe Names (comma separated)"
    Write-Host "  2. Load Safe Names from a CSV file"
    $inputChoice = Read-Host "Enter 1 or 2"
    
    $safeNames = @()
    if ($inputChoice -eq '1') {
        $inputSafeNames = Read-Host "Enter Safe Name(s) (comma separated if more than one)"
        $safeNames = $inputSafeNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        Write-Host "[INFO] Parsed $($safeNames.Count) safe name(s) from input." -ForegroundColor Cyan
    } 
    elseif ($inputChoice -eq '2') {
        $csvPath = Read-Host "Enter path to Safe names CSV file (column: SafeName)"
        Write-Host "[INFO] Loading Safe names from CSV: $csvPath" -ForegroundColor Cyan
        $safeNames = (Import-Csv -Path $csvPath | Select-Object -ExpandProperty SafeName) | Where-Object { $_ -ne $null -and $_ -ne "" }
        Write-Host "[INFO] Loaded $($safeNames.Count) safe name(s) from CSV." -ForegroundColor Cyan
    } 
    else {
        throw "Invalid input method selection."
    }

    # ---- Member search string ----
    $memberSearch = Read-Host "Enter member search string (leave empty to get all members)"
    if ($memberSearch) {
        Write-Host "[INFO] Member filter applied: *$memberSearch*" -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] No member filter applied. Will retrieve all members." -ForegroundColor Cyan
    }

    $allResults = @()
    $safeCounter = 0
    foreach ($safe in $safeNames) {
        $safeCounter++
        Write-Host "`n[PROCESSING] Safe $safeCounter of $($safeNames.Count): $safe" -ForegroundColor Magenta
        
        try {
            $members = Get-CyberArkSafeMembers -PvwaUrl $pvwaUrl -Token $session.Token -SafeName $safe
            Write-Host "[INFO] Retrieved $($members.Count) member(s) from safe '$safe'." -ForegroundColor Cyan

            # Filter within the script:
            if ($memberSearch) {
                $members = $members | Where-Object { $_.memberName -like "*$memberSearch*" }
                Write-Host "[INFO] After filtering: $($members.Count) member(s) match the search criteria." -ForegroundColor Cyan
            }

            $memberCounter = 0
            foreach ($mem in $members) {
                $memberCounter++
                Write-Host "  [MEMBER $memberCounter] Processing: $($mem.memberName) (Type: $($mem.memberType))" -ForegroundColor Gray
                
                # For User type members - get user details
                if ($mem.memberType -eq "User" -and $mem.memberId) {
                    Write-Host "    [USER] Fetching details for UserID: $($mem.memberId)..." -ForegroundColor Yellow
                    $userDetails = Get-CyberArkUserDetails -PvwaUrl $pvwaUrl -Token $session.Token -UserId $mem.memberId
                    
                    $firstName = if ($userDetails.personalDetails.firstName) { $userDetails.personalDetails.firstName } else { "" }
                    $lastName = if ($userDetails.personalDetails.lastName) { $userDetails.personalDetails.lastName } else { "" }
                    $fullName = "$firstName $lastName".Trim()
                    
                    $userObj = [PSCustomObject]@{
                        SafeName       = $safe
                        MemberType     = "User"
                        MemberUsername = $mem.memberName
                        FullName       = $fullName
                    }
                    $allResults += $userObj
                    Write-Host "    [USER] Added: $($mem.memberName) ($fullName)" -ForegroundColor DarkGray
                }
                
                # For Group type members - resolve group members
                elseif ($mem.memberType -eq "Group" -and $mem.memberId) {
                    Write-Host "    [GROUP] Resolving group members for GroupID: $($mem.memberId)..." -ForegroundColor Yellow
                    
                    try {
                        $groupResponse = Get-CyberArkUserGroupMembers -PvwaUrl $pvwaUrl -Token $session.Token -GroupId $mem.memberId
                        $groupUsers = $groupResponse.members
                        Write-Host "    [GROUP] Found $($groupUsers.Count) user(s) in group '$($mem.memberName)'." -ForegroundColor Cyan
                        
                        # Add the group itself
                        $groupObj = [PSCustomObject]@{
                            SafeName       = $safe
                            MemberType     = "Group"
                            MemberUsername = $mem.memberName
                            FullName       = ""
                        }
                        $allResults += $groupObj
                        
                        # Add each user in the group
                        foreach ($u in $groupUsers) {
                            Write-Host "      [USER IN GROUP] Fetching details for: $($u.UserName) (ID: $($u.id))..." -ForegroundColor DarkYellow
                            $userDetails = Get-CyberArkUserDetails -PvwaUrl $pvwaUrl -Token $session.Token -UserId $u.id
                            
                            $firstName = if ($userDetails.personalDetails.firstName) { $userDetails.personalDetails.firstName } else { "" }
                            $lastName = if ($userDetails.personalDetails.lastName) { $userDetails.personalDetails.lastName } else { "" }
                            $fullName = "$firstName $lastName".Trim()
                            
                            $deepObj = [PSCustomObject]@{
                                SafeName       = $safe
                                MemberType     = "User (from Group: $($mem.memberName))"
                                MemberUsername = $u.UserName
                                FullName       = $fullName
                            }
                            $allResults += $deepObj
                            Write-Host "      [USER IN GROUP] Added: $($u.UserName) ($fullName)" -ForegroundColor DarkGray
                        }
                    }
                    catch {
                        Write-Host "    [WARNING] Failed to retrieve group members for GroupID $($mem.memberId): $_" -ForegroundColor Red
                    }
                }
            }
        }
        catch {
            Write-Host "[ERROR] Failed to retrieve members for safe '$safe': $_" -ForegroundColor Red
        }
    }

    Write-Host "`n[INFO] Total records collected: $($allResults.Count)" -ForegroundColor Cyan

    if ($safeNames.Count -eq 1) {
        Write-Host "`n[OUTPUT] Displaying results on screen (single safe mode)..." -ForegroundColor Green
        $allResults | Format-Table -AutoSize | Out-Host
    } 
    else {
        $outfile = "SafeMemberDeepSearch_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
        Write-Host "`n[OUTPUT] Exporting results to CSV (multiple safes mode)..." -ForegroundColor Green
        $allResults | Export-Csv -Path $outfile -NoTypeInformation -Encoding UTF8
        Write-Host "[SUCCESS] Output exported to: $outfile" -ForegroundColor Green
    }
}
finally {
    Write-Host "`n[INFO] Disconnecting from CyberArk..." -ForegroundColor Cyan
    Disconnect-CyberArk -PvwaUrl $pvwaUrl -Token $session.Token
    Write-Host "[SUCCESS] Disconnected successfully." -ForegroundColor Green
}
