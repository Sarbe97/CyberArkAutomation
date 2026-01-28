# ============================================================================
# MODULE: SecondaryAccountOnboarding.psm1
# DESCRIPTION: Secondary Account bulk onboarding with email notifications
# ============================================================================

function Invoke-CACSecondaryAccountOnboarding {
    <#
    .SYNOPSIS
        Onboard secondary accounts from CSV, processing one employee at a time.
    .DESCRIPTION
        Reads secondary account data from CSV, groups by employee, and for each employee:
        - Shows their accounts
        - Prompts for reconcile/email/proceed options
        - Processes that employee's accounts
        - Moves to next employee
        
        Required CSV columns: EmpNbr, UserFullName, Email, SafeName, PlatformId, Address, UserName
        Optional CSV columns: Name, Password
    #>
    [CmdletBinding()]
    param()

    $outputDir = Get-CACOutputDir
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputCsvPath = "$outputDir/SecondaryAccountOnboarding_Result_$timestamp.csv"

    Write-Log "Started Invoke-CACSecondaryAccountOnboarding()" "DEBUG"

    # Prompt for CSV path
    Write-Host "===== Secondary Account Onboarding =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Required CSV columns: EmpNbr, UserFullName, Email, SafeName, PlatformId, Address, UserName" -ForegroundColor Yellow
    Write-Host "Optional CSV columns: Name, Password" -ForegroundColor Yellow
    Write-Host ""

    $CsvPath = Read-Host "Enter CSV Path"
    
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        Write-Host "CSV path cannot be empty." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV file not found: $CsvPath" -ForegroundColor Red
        return
    }

    Write-Log "Processing CSV: $CsvPath" "INFO"
    
    try {
        $itemsToProcess = Import-Csv $CsvPath
    }
    catch {
        Write-Host "Error reading CSV: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ($itemsToProcess.Count -eq 0) {
        Write-Host "No items found in CSV." -ForegroundColor Yellow
        return
    }

    # ============================================================
    # CC Address Configuration
    # ============================================================
    $mailConfig = Get-CACMailConfig
    $defaultCC = if ($mailConfig -and $mailConfig.DefaultCC) { @($mailConfig.DefaultCC) } else { @() }
    
    Write-Host ""
    Write-Host "===== Email CC Configuration =====" -ForegroundColor Cyan
    if ($defaultCC.Count -gt 0) {
        Write-Host "Default CC addresses from config:" -ForegroundColor White
        foreach ($cc in $defaultCC) {
            Write-Host "  - $cc" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "No default CC addresses configured." -ForegroundColor Yellow
    }
    
    Write-Host ""
    $changeCCInput = Read-Host "Change CC addresses? (Y/N)"
    
    $ccAddresses = $defaultCC
    if ($changeCCInput -eq 'Y' -or $changeCCInput -eq 'y') {
        $ccInput = Read-Host "Enter CC addresses (comma-separated, or leave empty for none)"
        if ([string]::IsNullOrWhiteSpace($ccInput)) {
            $ccAddresses = @()
            Write-Host "CC addresses cleared." -ForegroundColor Yellow
        }
        else {
            $ccAddresses = $ccInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            Write-Host "CC addresses updated:" -ForegroundColor Green
            foreach ($cc in $ccAddresses) {
                Write-Host "  - $cc" -ForegroundColor Gray
            }
        }
    }

    # Group by employee and sort
    $employeeGroups = $itemsToProcess | Group-Object -Property EmpNbr | Sort-Object Name
    $totalEmployees = $employeeGroups.Count
    $totalAccounts = $itemsToProcess.Count

    Write-Host ""
    Write-Host "===== CSV Summary =====" -ForegroundColor Cyan
    Write-Host "Total Accounts: $totalAccounts" -ForegroundColor White
    Write-Host "Total Employees: $totalEmployees" -ForegroundColor White
    Write-Host ""

    # ============================================================
    # Collect Global Options ONCE at the Beginning
    # ============================================================
    Write-Host "===== Processing Options =====" -ForegroundColor Cyan
    
    $doReconcileInput = Read-Host "Trigger reconcile after onboarding? (Y/N)"
    $doReconcile = ($doReconcileInput -eq 'Y' -or $doReconcileInput -eq 'y')
    
    $doSendEmailInput = Read-Host "Send email notifications? (Y/N)"
    $doSendEmail = ($doSendEmailInput -eq 'Y' -or $doSendEmailInput -eq 'y')
    
    Write-Host ""
    Write-Host "Settings: Reconcile=$doReconcile, Email=$doSendEmail" -ForegroundColor Gray
    Write-Host ""
    
    $startConfirm = Read-Host "Start processing? (Y/N)"
    if ($startConfirm -ne 'Y' -and $startConfirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    # Global results collection
    $allResults = @()
    $globalSuccessCount = 0
    $globalFailCount = 0
    $globalReconcileCount = 0
    $globalEmailsSent = 0
    $employeesProcessed = 0
    $employeesSkipped = 0
    $processAllRemaining = $false

    # ============================================================
    # Process Each Employee One at a Time
    # ============================================================
    $empIndex = 0
    foreach ($empGroup in $employeeGroups) {
        $empIndex++
        $empNbr = $empGroup.Name
        $empAccounts = $empGroup.Group
        $empEmail = ($empAccounts | Select-Object -First 1).Email
        $empFullName = ($empAccounts | Select-Object -First 1).UserFullName
        $accountCount = $empAccounts.Count

        Clear-Host
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "  Employee $empIndex of $totalEmployees" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "EmpNbr:    $empNbr" -ForegroundColor White
        Write-Host "Full Name: $empFullName" -ForegroundColor White
        Write-Host "Email:     $empEmail" -ForegroundColor White
        Write-Host ""

        # Show this employee's accounts
        Write-Host "Accounts to onboard ($accountCount):" -ForegroundColor Yellow
        $empAccounts | Format-Table SafeName, PlatformId, Address, UserName, Name -AutoSize

        # ============================================================
        # Process This Employee's Accounts
        # ============================================================
        Write-Host "Processing accounts for EmpNbr: $empNbr..." -ForegroundColor Cyan
        
        $empResults = @()
        $empSuccessCount = 0
        $empFailCount = 0

        foreach ($item in $empAccounts) {
            $resObj = $item | Select-Object *

            # Get fields
            $safeName = $item.SafeName
            $platformId = $item.PlatformId
            $address = $item.Address
            $userName = $item.UserName
            
            $name = if ($item.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($item.Name)) { 
                $item.Name 
            }
            else { 
                "$userName@$address" 
            }
            $password = if ($item.PSObject.Properties['Password']) { $item.Password } else { $null }

            # Validate required fields
            $missingFields = @()
            if ([string]::IsNullOrWhiteSpace($safeName)) { $missingFields += "SafeName" }
            if ([string]::IsNullOrWhiteSpace($platformId)) { $missingFields += "PlatformId" }
            if ([string]::IsNullOrWhiteSpace($address)) { $missingFields += "Address" }
            if ([string]::IsNullOrWhiteSpace($userName)) { $missingFields += "UserName" }

            if ($missingFields.Count -gt 0) {
                Write-Host "  $userName@$address ... " -NoNewline
                Write-Host "Skipped (Missing: $($missingFields -join ', '))" -ForegroundColor Yellow
                
                $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Skipped" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Missing: $($missingFields -join ', ')" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                $empResults += $resObj
                $empFailCount++
                continue
            }

            Write-Host "  $name ... " -NoNewline

            try {
                $accountBody = @{
                    safeName   = $safeName
                    platformId = $platformId
                    name       = $name
                    address    = $address
                    userName   = $userName
                }

                if (-not [string]::IsNullOrWhiteSpace($password)) {
                    $accountBody["secret"] = $password
                }

                # FOR TESTING: Uncomment below and comment out the actual API call
                # $result = @{ id = "TEST_$(Get-Random -Maximum 99999)" }
                
                $result = Invoke-CACAPIRequest -Method POST -Endpoint "/API/Accounts" -Body $accountBody

                Write-Host "Success (ID: $($result.id))" -ForegroundColor Green
                
                $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Success" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Account created" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value $result.id -Force
                
                Write-Log "Account created: $name (ID: $($result.id)) for EmpNbr: $empNbr" "SUCCESS"
                $empSuccessCount++
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Host "Failed ($errMsg)" -ForegroundColor Red
                
                $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Failed" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value $errMsg -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                
                Write-Log "Failed to create $name for EmpNbr $empNbr : $errMsg" "ERROR"
                $empFailCount++
            }

            $empResults += $resObj
        }

        # Update global counts
        $globalSuccessCount += $empSuccessCount
        $globalFailCount += $empFailCount
        $employeesProcessed++

        # ============================================================
        # Reconcile for This Employee (if selected and has successes)
        # ============================================================
        if ($doReconcile -and $empSuccessCount -gt 0) {
            Write-Host ""
            Write-Host "Triggering reconcile for $empSuccessCount account(s)..." -ForegroundColor Cyan
            
            $successfulAccounts = $empResults | Where-Object { $_.OnboardingStatus -eq "Success" }
            
            foreach ($acc in $successfulAccounts) {
                $accountId = $acc.AccountId
                Write-Host "  Reconciling $($acc.UserName) (ID: $accountId)... " -NoNewline
                
                try {
                    # FOR TESTING: Uncomment below and comment out the actual API call
                    # Write-Host "Initiated (SIMULATED)" -ForegroundColor Green
                    
                    Invoke-CACAPIRequest -Method POST -Endpoint "/API/Accounts/$accountId/Reconcile"
                    Write-Host "Initiated" -ForegroundColor Green
                    $globalReconcileCount++
                }
                catch {
                    Write-Host "Failed" -ForegroundColor Red
                }
            }
        }

        # ============================================================
        # Send Email for This Employee (if selected)
        # ============================================================
        if ($doSendEmail -and $empSuccessCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($empEmail)) {
            Write-Host ""
            Write-Host "Sending email to $empEmail... " -NoNewline
            
            # Static data paths (relative to CyberArkCLI folder)
            $staticDataDir = Join-Path (Split-Path $PSScriptRoot -Parent) "Static_Data"
            $imagePath = Join-Path $staticDataDir "RDP-Connect.png"
            $attachmentPath = Join-Path $staticDataDir "CyberArk_PSM_Guide.docx"
            
            $emailBody = New-CACSecondaryAccountEmailBody -UserFullName $empFullName -Accounts $empResults -ImagePath $imagePath
            
            $emailParams = @{
                To          = $empEmail
                Subject     = "CyberArk Secondary Account Onboarding Notification"
                Body        = $emailBody
                IsHtml      = $true
                Attachments = @($attachmentPath)
            }
            
            # Add CC if configured
            if ($ccAddresses -and $ccAddresses.Count -gt 0) {
                $emailParams["CC"] = $ccAddresses
            }
            
            $emailResult = Send-CACEmail @emailParams

            if ($emailResult) {
                Write-Host "Sent" -ForegroundColor Green
                $globalEmailsSent++
            }
            else {
                Write-Host "Failed" -ForegroundColor Red
            }
        }

        # Add to global results
        $allResults += $empResults

        # ============================================================
        # Save Results After Each Employee (Incremental Save)
        # ============================================================
        $allResults | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
        Write-Log "Saved results for EmpNbr $empNbr to $OutputCsvPath" "DEBUG"

        # Employee summary
        Write-Host ""
        Write-Host "===== EmpNbr $empNbr Complete =====" -ForegroundColor Cyan
        Write-Host "  Success: $empSuccessCount" -ForegroundColor Green
        Write-Host "  Failed:  $empFailCount" -ForegroundColor $(if ($empFailCount -gt 0) { "Red" } else { "White" })
        Write-Host "  (Results saved to file)" -ForegroundColor Gray
        Write-Host ""
        
        # ============================================================
        # Prompt for Next Employee (Y/N/A)
        # ============================================================
        if ($empIndex -lt $totalEmployees -and -not $processAllRemaining) {
            $nextEmpNbr = ($employeeGroups[$empIndex]).Name
            Write-Host "Next: EmpNbr $nextEmpNbr" -ForegroundColor Yellow
            Write-Host "Options: Y=Proceed, N=Abort, A=Yes to All remaining" -ForegroundColor Yellow
            $continueChoice = Read-Host "Continue? (Y/N/A)"
            
            # Handle Abort (N)
            if ($continueChoice -eq 'N' -or $continueChoice -eq 'n') {
                Write-Host ""
                Write-Host "Aborting remaining employees..." -ForegroundColor Yellow
                
                # Mark remaining employees as NotProcessed
                $remainingGroups = $employeeGroups | Select-Object -Skip $empIndex
                foreach ($remGroup in $remainingGroups) {
                    foreach ($acc in $remGroup.Group) {
                        $resObj = $acc | Select-Object *
                        $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "NotProcessed" -Force
                        $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Aborted by user" -Force
                        $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                        $allResults += $resObj
                    }
                }
                
                # Final save and exit
                $allResults | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
                Write-Host "Results saved to: $OutputCsvPath" -ForegroundColor Green
                Write-Log "Aborted by user after EmpNbr $empNbr. Processed: $employeesProcessed employees" "WARN"
                break
            }
            
            # Handle Yes to All (A)
            if ($continueChoice -eq 'A' -or $continueChoice -eq 'a') {
                Write-Host "Processing all remaining employees without prompts..." -ForegroundColor Cyan
                $processAllRemaining = $true
            }
            
            # Y or any other input continues to next employee
        }
    }

    # ============================================================
    # Export Final Results
    # ============================================================
    $allResults | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8

    # ============================================================
    # Final Summary
    # ============================================================
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Secondary Account Onboarding Complete" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "===== Final Summary =====" -ForegroundColor Cyan
    Write-Host "  Total Employees:     $totalEmployees"
    Write-Host "  Employees Processed: $employeesProcessed"
    Write-Host "  Employees Skipped:   $employeesSkipped"
    Write-Host ""
    Write-Host "  Total Accounts:      $totalAccounts"
    Write-Host "  Success:             $globalSuccessCount" -ForegroundColor Green
    Write-Host "  Failed:              $globalFailCount" -ForegroundColor $(if ($globalFailCount -gt 0) { "Red" } else { "White" })
    Write-Host ""
    Write-Host "  Reconciles Initiated: $globalReconcileCount"
    Write-Host "  Emails Sent:          $globalEmailsSent"
    Write-Host ""
    Write-Host "Results saved to: $OutputCsvPath" -ForegroundColor Green
    
    Write-Log "Secondary Account Onboarding Complete. Processed: $employeesProcessed, Skipped: $employeesSkipped, Success: $globalSuccessCount, Failed: $globalFailCount" "INFO"
}

# ============================================================
# Helper: Build Email Body for Employee
# ============================================================
function New-CACSecondaryAccountEmailBody {
    param(
        [string]$UserFullName,
        [array]$Accounts,
        [string]$ImagePath = ""  # Optional: Path to image file to embed in PSM section
    )

    $successAccounts = $Accounts | Where-Object { $_.OnboardingStatus -eq "Success" }

    # Prepare Base64 image tag if image path provided
    $imageHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($ImagePath) -and (Test-Path $ImagePath)) {
        try {
            $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
            $base64Image = [Convert]::ToBase64String($imageBytes)
            $extension = [System.IO.Path]::GetExtension($ImagePath).TrimStart('.').ToLower()
            $mimeType = switch ($extension) {
                "png" { "image/png" }
                "jpg" { "image/jpeg" }
                "jpeg" { "image/jpeg" }
                "gif" { "image/gif" }
                default { "image/png" }
            }
            $imageHtml = "<br><img src='data:$mimeType;base64,$base64Image' alt='PSM Guide' style='max-width: 100%; margin-top: 10px;' />"
        }
        catch {
            Write-Log "Failed to embed image: $($_.Exception.Message)" "WARN"
        }
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; font-size: 13px; color: #333; line-height: 1.5; }
        table { border-collapse: collapse; margin: 10px 0; }
        th, td { border: 1px solid #000; padding: 4px 8px; text-align: left; }
        th { background-color: #000; color: #fff; }
        .highlight { background-color: #fff3cd; border: 1px solid #ffc107; padding: 12px; margin: 15px 0; border-radius: 4px; }
    </style>
</head>
<body>
    <p>Hi $UserFullName,</p>
    
    <p>The below secondary account(s) was discovered by CyberArk and onboarded to your personal safe.</p>
    
    <table>
        <tr>
            <th>UserName</th>
            <th>Address</th>
            <th>Safe</th>
        </tr>
"@

    foreach ($acc in $successAccounts) {
        $html += @"
        <tr>
            <td>$($acc.UserName)</td>
            <td>$($acc.Address)</td>
            <td>$($acc.SafeName)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <div class="highlight">
        <strong>PSM Recommendation:</strong> As we continue to progressively adopt CyberArk PSM, 
        we recommend using <strong>CyberArk PSM (RDP)</strong> for accessing Windows machines 
        wherever possible, instead of copying or manually using passwords for connectivity. 
        This will help ensure that access is properly monitored and aligned with privileged 
        access best practices.$imageHtml
    </div>
    
    <p>Please let us know if you have any questions or need any assistance with CyberArk or PSM access.</p>
    
    <p>Regards,<br>
    <strong>CyberArk Team</strong></p>
</body>
</html>
"@

    return $html
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function Invoke-CACSecondaryAccountOnboarding
