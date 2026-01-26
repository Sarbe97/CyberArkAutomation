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
        
        Required CSV columns: EmpNbr, Email, SafeName, PlatformId, Address, UserName
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
    Write-Host "Required CSV columns: EmpNbr, Email, SafeName, PlatformId, Address, UserName" -ForegroundColor Yellow
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

    # Group by employee and sort
    $employeeGroups = $itemsToProcess | Group-Object -Property EmpNbr | Sort-Object Name
    $totalEmployees = $employeeGroups.Count
    $totalAccounts = $itemsToProcess.Count

    Write-Host ""
    Write-Host "===== CSV Summary =====" -ForegroundColor Cyan
    Write-Host "Total Accounts: $totalAccounts" -ForegroundColor White
    Write-Host "Total Employees: $totalEmployees" -ForegroundColor White
    Write-Host ""
    Write-Host "Will process each employee one at a time." -ForegroundColor Yellow
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

    # ============================================================
    # Process Each Employee One at a Time
    # ============================================================
    $empIndex = 0
    foreach ($empGroup in $employeeGroups) {
        $empIndex++
        $empNbr = $empGroup.Name
        $empAccounts = $empGroup.Group
        $empEmail = ($empAccounts | Select-Object -First 1).Email
        $accountCount = $empAccounts.Count

        Clear-Host
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "  Employee $empIndex of $totalEmployees" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "EmpNbr: $empNbr" -ForegroundColor White
        Write-Host "Email:  $empEmail" -ForegroundColor White
        Write-Host ""

        # Show this employee's accounts
        Write-Host "Accounts to onboard ($accountCount):" -ForegroundColor Yellow
        $empAccounts | Format-Table SafeName, PlatformId, Address, UserName, Name -AutoSize
        
        # ============================================================
        # Collect Options for This Employee
        # ============================================================
        Write-Host "===== Options for EmpNbr: $empNbr =====" -ForegroundColor Cyan
        
        $doReconcile = Read-Host "Trigger reconcile after onboarding? (Y/N)"
        $doReconcile = ($doReconcile -eq 'Y' -or $doReconcile -eq 'y')
        
        $doSendEmail = Read-Host "Send email notification to $empEmail? (Y/N)"
        $doSendEmail = ($doSendEmail -eq 'Y' -or $doSendEmail -eq 'y')
        
        Write-Host ""
        Write-Host "Options: Y=Proceed, N=Skip this employee, A=Abort (save & exit)" -ForegroundColor Yellow
        $confirm = Read-Host "Proceed with onboarding for EmpNbr $empNbr? (Y/N/A)"
        
        # Handle Abort - save whatever has been processed and exit
        if ($confirm -eq 'A' -or $confirm -eq 'a') {
            Write-Host ""
            Write-Host "Aborting... saving processed results." -ForegroundColor Yellow
            
            # Mark remaining employees (including current) as not processed
            # Current employee
            foreach ($acc in $empAccounts) {
                $resObj = $acc | Select-Object *
                $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "NotProcessed" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Aborted by user" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                $allResults += $resObj
            }
            
            # Remaining employees
            $remainingGroups = $employeeGroups | Select-Object -Skip $empIndex
            foreach ($remGroup in $remainingGroups) {
                foreach ($acc in $remGroup.Group) {
                    $resObj = $acc | Select-Object *
                    $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "NotProcessed" -Force
                    $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Aborted before processing" -Force
                    $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                    $allResults += $resObj
                }
            }
            
            # Export and exit
            $allResults | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Force -Encoding UTF8
            Write-Host ""
            Write-Host "Results saved to: $OutputCsvPath" -ForegroundColor Green
            Write-Host "Processed: $employeesProcessed employees, Aborted at: EmpNbr $empNbr" -ForegroundColor Yellow
            Write-Log "Aborted by user. Processed: $employeesProcessed, Remaining saved as NotProcessed" "WARN"
            return
        }
        
        # Handle Skip
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "Skipped EmpNbr: $empNbr" -ForegroundColor Yellow
            $employeesSkipped++
            
            # Add skipped records to results
            foreach ($acc in $empAccounts) {
                $resObj = $acc | Select-Object *
                $resObj | Add-Member -MemberType NoteProperty -Name "OnboardingStatus" -Value "Skipped" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "Message" -Value "Skipped by user" -Force
                $resObj | Add-Member -MemberType NoteProperty -Name "AccountId" -Value "" -Force
                $allResults += $resObj
            }
            
            Pause
            continue
        }

        # ============================================================
        # Process This Employee's Accounts
        # ============================================================
        Write-Host ""
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
        if ($doSendEmail -and -not [string]::IsNullOrWhiteSpace($empEmail)) {
            Write-Host ""
            Write-Host "Sending email to $empEmail... " -NoNewline
            
            $emailBody = New-CACSecondaryAccountEmailBody -EmpNbr $empNbr -Accounts $empResults
            
            $emailResult = Send-CACEmail `
                -To $empEmail `
                -Subject "CyberArk Secondary Account Onboarding - Results" `
                -Body $emailBody `
                -IsHtml $true

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

        # Employee summary
        Write-Host ""
        Write-Host "===== EmpNbr $empNbr Summary =====" -ForegroundColor Cyan
        Write-Host "  Success: $empSuccessCount" -ForegroundColor Green
        Write-Host "  Failed:  $empFailCount" -ForegroundColor $(if ($empFailCount -gt 0) { "Red" } else { "White" })
        Write-Host ""
        
        if ($empIndex -lt $totalEmployees) {
            Pause
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
        [string]$EmpNbr,
        [array]$Accounts
    )

    $successAccounts = $Accounts | Where-Object { $_.OnboardingStatus -eq "Success" }
    $failedAccounts = $Accounts | Where-Object { $_.OnboardingStatus -ne "Success" }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; font-size: 14px; color: #333; }
        h2 { color: #0066cc; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #0066cc; color: white; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .success { color: #28a745; font-weight: bold; }
        .failed { color: #dc3545; font-weight: bold; }
        .summary { margin: 20px 0; padding: 15px; background-color: #f5f5f5; border-radius: 5px; }
    </style>
</head>
<body>
    <h2>CyberArk Secondary Account Onboarding Results</h2>
    
    <p>Dear User (Employee #: $EmpNbr),</p>
    
    <p>Your secondary account(s) have been processed for onboarding to CyberArk. Please find the details below:</p>
    
    <div class="summary">
        <strong>Summary:</strong><br>
        Total Accounts: $($Accounts.Count)<br>
        <span class="success">Successful: $($successAccounts.Count)</span><br>
        <span class="failed">Failed: $($failedAccounts.Count)</span>
    </div>
    
    <h3>Account Details</h3>
    <table>
        <tr>
            <th>UserName</th>
            <th>Address</th>
            <th>Safe</th>
            <th>Platform</th>
            <th>Status</th>
            <th>Message</th>
        </tr>
"@

    foreach ($acc in $Accounts) {
        $statusClass = if ($acc.OnboardingStatus -eq "Success") { "success" } else { "failed" }
        $html += @"
        <tr>
            <td>$($acc.UserName)</td>
            <td>$($acc.Address)</td>
            <td>$($acc.SafeName)</td>
            <td>$($acc.PlatformId)</td>
            <td class="$statusClass">$($acc.OnboardingStatus)</td>
            <td>$($acc.Message)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <p style="margin-top: 20px;">
        If you have any questions, please contact the CyberArk administration team.
    </p>
    
    <p>
        <em>This is an automated message from CyberArk CLI.</em>
    </p>
</body>
</html>
"@

    return $html
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function Invoke-CACSecondaryAccountOnboarding
