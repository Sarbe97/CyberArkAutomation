# ==========================
# Safes.psm1
# ==========================

# =====================================================================
# HELPER: Flatten Safe Member Permissions
# This ensures nested API permission objects become CSV columns.
# =====================================================================
function New-CACSafeMemberDetailedRow {
    param (
        [string]$SafeName,
        [object]$MemberObj
    )

    # 1. Identify where the permissions are stored.
    # psPAS sometimes puts them in $MemberObj.Permissions or on the root depending on API version.
    $perms = $null
    if ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions -is [System.Collections.IDictionary]) {
        # It's a dictionary (Gen2 API standard response)
        $perms = $MemberObj.Permissions
    }
    elseif ($MemberObj.PSObject.Properties.Match('Permissions') -and $MemberObj.Permissions -is [object]) {
        # It's a nested object
        $perms = $MemberObj.Permissions
    }
    else {
        # Fallback: The object itself might contain the flags (Gen1 API behavior)
        $perms = $MemberObj
    }

    # 2. Create a flat object mapping every specific CyberArk permission
    return [PSCustomObject]@{
        SafeName                       = $SafeName
        MemberName                     = $MemberObj.MemberName
        MemberType                     = $MemberObj.MemberType
        # Membership Expiration (if set)
        MembershipExpirationDate       = $MemberObj.MembershipExpirationDate

        # --- Standard Permissions ---
        UseAccounts                    = [bool]$perms['UseAccounts']
        RetrieveAccounts               = [bool]$perms['RetrieveAccounts']
        ListAccounts                   = [bool]$perms['ListAccounts']
        AddAccounts                    = [bool]$perms['AddAccounts']
        UpdateAccountContent           = [bool]$perms['UpdateAccountContent']
        UpdateAccountProperties        = [bool]$perms['UpdateAccountProperties']
        InitiateCPMAccountManagementOperations = [bool]$perms['InitiateCPMAccountManagementOperations']
        SpecifyNextAccountContent      = [bool]$perms['SpecifyNextAccountContent']
        RenameAccounts                 = [bool]$perms['RenameAccounts']
        DeleteAccounts                 = [bool]$perms['DeleteAccounts']
        MoveAccounts                   = [bool]$perms['MoveAccounts']
        
        # --- Administrative Permissions ---
        ManageSafe                     = [bool]$perms['ManageSafe']
        ManageSafeMembers              = [bool]$perms['ManageSafeMembers']
        BackupSafe                     = [bool]$perms['BackupSafe']
        ViewAuditLog                   = [bool]$perms['ViewAuditLog']
        ViewSafeMembers                = [bool]$perms['ViewSafeMembers']
        AccessSafeWithoutConfirmation  = [bool]$perms['AccessSafeWithoutConfirmation']
        
        # --- Folder Permissions ---
        CreateFolders                  = [bool]$perms['CreateFolders']
        DeleteFolders                  = [bool]$perms['DeleteFolders']
        MoveFolders                    = [bool]$perms['MoveFolders']
        
        # --- Often missed ---
        UnlockAccounts                 = [bool]$perms['UnlockAccounts']
        RequestsAuthorizationLevel1    = [bool]$perms['RequestsAuthorizationLevel1']
        RequestsAuthorizationLevel2    = [bool]$perms['RequestsAuthorizationLevel2']
    }
}

# ============================================================
# Export Safe Members WITH DETAILED PERMISSIONS
# ============================================================
function Export-CACSafeMembers {
    [CmdletBinding()]
    param()

    Write-Log "Started Export-CACSafeMembers()" "DEBUG"

    # --- Input Selection ---
    Write-Host "Choose Input Mode:" -ForegroundColor Cyan
    Write-Host "1 = Enter safe names manually"
    Write-Host "2 = Load safe names from CSV (Header: SafeName)"
    $mode = Read-Host "Enter option (1 or 2)"

    switch ($mode) {
        '1' {
            $safeNames = (Read-Host "Enter safe names (comma separated)") -split "," | ForEach-Object { $_.Trim() }
            $outputToCsv = $false
        }
        '2' {
            $csvPath = Read-Host "Enter full CSV path"
            if (!(Test-Path $csvPath)) { Write-Host "CSV not found!"; return }
            $safeNames = (Import-Csv $csvPath).SafeName | ForEach-Object { $_.Trim() }
            $inputPath = Split-Path -Path $csvPath -Parent
            $outputToCsv = $true
        }
        default { return }
    }

    $rows = @()
    $totalSafes = $safeNames.Count
    $currentSafeIndex = 0

    foreach ($safeName in $safeNames) {
        $currentSafeIndex++
        $pct = ($currentSafeIndex / $totalSafes) * 100
        
        # --- PROGRESS BAR ---
        Write-Progress -Activity "Fetching Safe Permissions" `
            -Status "Safe $currentSafeIndex of $totalSafes : $safeName" `
            -PercentComplete $pct
        # --------------------

        Write-Log "Processing safe: $safeName" "INFO"

        try {
            # Get members using psPAS
            $members = Get-PASSafeMember -SafeName $safeName -ErrorAction Stop
        }
        catch {
            Write-Log "Failed to fetch members for '$safeName': $($_.Exception.Message)" "ERROR"
            continue
        }

        if ($members) {
            foreach ($member in $members) {
                # call the Helper function to Flatten the permissions
                $row = New-CACSafeMemberDetailedRow -SafeName $safeName -MemberObj $member
                $rows += $row
            }
        }
    }

    # Close Progress Bar
    Write-Progress -Activity "Fetching Safe Permissions" -Completed

    if ($rows.Count -eq 0) {
        Write-Host "No members found." -ForegroundColor Yellow
        return
    }

    # --- Output ---
    if ($outputToCsv) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFileName = "safe_members_detailed_$timestamp.csv"
        $outputPath = Join-Path -Path $inputPath -ChildPath $outputFileName
        
        Write-Host "Exporting detailed permissions to CSV..." -ForegroundColor Cyan
        
        # Exporting to CSV now works perfectly because we flattened the object
        $rows | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        
        Write-Host "Export completed: $outputPath" -ForegroundColor Green
        Write-Log "Export successful: $outputPath" "SUCCESS"
    }
    else {
        # Display in GridView because the table is too wide for console now
        Write-Host "Displaying results in GridView (Table too wide for console)" -ForegroundColor Cyan
        $rows | Out-GridView -Title "Safe Member Permissions"
    }
}

# (Other functions like Export-CACAllSafes, Search-CACSafeByName etc. remain the same as previous response)
