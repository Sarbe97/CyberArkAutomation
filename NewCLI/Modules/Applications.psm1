# ============================================================================
# MODULE: Applications.psm1
# DESCRIPTION: Application Management using CyberArk PIMServices API
# ============================================================================

# ============================================================
# 1. Get All Applications
# ============================================================
function Get-CACAllApplications {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAllApplications()" "DEBUG"

    try {
        Write-Host "Fetching all applications..." -ForegroundColor Cyan

        # Note: Applications often use the legacy PIM API
        $endpoint = "/WebServices/PIMServices.svc/Applications/"
        
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $apps = @()
        if ($response.value) { $apps = @($response.value) }
        elseif ($response -is [array]) { $apps = @($response) }
        
        if ($apps.Count -eq 0) {
            Write-Host "No applications found." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($apps.Count) applications" "INFO"

        # Format output
        $formattedApps = @()
        foreach ($app in $apps) {
            $formattedApps += [PSCustomObject]@{
                AppID             = $app.AppID
                Description       = $app.Description
                Location          = $app.Location
                AccessPermittedTo = $app.AccessPermittedTo
                Disabled          = if ($app.Disabled -eq $true) { "Yes" } else { "No" }
            }
        }

        # Display summary
        Write-Host ""
        Write-Host "===== Applications =====" -ForegroundColor Cyan
        Write-Host "Total Applications: $($formattedApps.Count)"
        Write-Host ""

        $formattedApps | Format-Table AppID, Description, Location, Disabled -AutoSize

        # Ask about export
        $exportChoice = Read-Host "Export to CSV? (Y/N)"
        if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
            $outputDir = Get-CACOutputDir
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $outputFile = "$outputDir/applications_$timestamp.csv"

            $formattedApps | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
            Write-Host "Export File: $outputFile" -ForegroundColor Green
        }

        return $formattedApps
    }
    catch {
        Write-Log "Error in Get-CACAllApplications(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 2. Get Application Details
# ============================================================
function Get-CACApplicationDetails {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACApplicationDetails()" "DEBUG"

    try {
        $appId = Read-Host "Enter Application ID"
        if ([string]::IsNullOrWhiteSpace($appId)) {
            Write-Host "Application ID cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching application details..." -ForegroundColor Cyan

        $endpoint = "/WebServices/PIMServices.svc/Applications/$([System.Web.HttpUtility]::UrlEncode($appId))/"
        $app = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        if (-not $app) {
            Write-Host "Application not found." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Application Details =====" -ForegroundColor Cyan
        Write-Host "App ID:          $($app.AppID)" -ForegroundColor White
        Write-Host "Description:     $($app.Description)" -ForegroundColor White
        Write-Host "Location:        $($app.Location)" -ForegroundColor White
        Write-Host "Disabled:        $($app.Disabled)" -ForegroundColor $(if ($app.Disabled) { "Red" } else { "Green" })
        Write-Host "Access Permitted From: $($app.AccessPermittedFrom)" -ForegroundColor White
        Write-Host "Access Permitted To:   $($app.AccessPermittedTo)" -ForegroundColor White
        Write-Host "Allow Ext Auth Restr:  $($app.AllowExtendedAuthenticationRestrictions)" -ForegroundColor White
        Write-Host "Business Owner:  $($app.BusinessOwnerFName) $($app.BusinessOwnerLName) ($($app.BusinessOwnerEmail))" -ForegroundColor White
        Write-Host "Expiration Date: $(if ($app.ExpirationDate) { Convert-CACTimestamp $app.ExpirationDate } else { 'Never' })" -ForegroundColor White
        Write-Host ""

        return $app
    }
    catch {
        Write-Log "Error in Get-CACApplicationDetails(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 3. Get Application Authentication Methods
# ============================================================
function Get-CACAppAuthMethods {
    [CmdletBinding()]
    param()

    Write-Log "Started Get-CACAppAuthMethods()" "DEBUG"

    try {
        $appId = Read-Host "Enter Application ID"
        if ([string]::IsNullOrWhiteSpace($appId)) {
            Write-Host "Application ID cannot be empty." -ForegroundColor Yellow
            return
        }

        Write-Host "Fetching authentication methods..." -ForegroundColor Cyan

        $endpoint = "/WebServices/PIMServices.svc/Applications/$([System.Web.HttpUtility]::UrlEncode($appId))/Authentications/"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint

        $methods = @()
        if ($response.value) { $methods = @($response.value) }
        elseif ($response -is [array]) { $methods = @($response) }

        if ($methods.Count -eq 0) {
            Write-Host "No authentication methods found for '$appId'." -ForegroundColor Yellow
            return
        }

        Write-Log "Retrieved $($methods.Count) auth methods" "INFO"

        Write-Host ""
        Write-Host "===== Authentication Methods ($appId) =====" -ForegroundColor Cyan
        
        foreach ($method in $methods) {
            Write-Host "Wait..." -ForegroundColor DarkGray
            # Depending on structure, authentication methods might have different fields
            # Typically: AuthType, IsCritical, etc.
            
            # Since structure can vary, we list key properties
            $props = $method | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            
            Write-Host "Method Type: $(if ($method.AuthType) { $method.AuthType } else { 'Unknown' })" -ForegroundColor Green
            
            foreach ($p in $props) {
                if ($p -ne "AuthType") {
                    Write-Host "  $p: $($method.$p)"
                }
            }
            Write-Host "-------------------------" -ForegroundColor DarkGray
        }
        Write-Host ""

        return $methods
    }
    catch {
        Write-Log "Error in Get-CACAppAuthMethods(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# 4. Search Applications
# ============================================================
function Search-CACApplications {
    [CmdletBinding()]
    param()

    Write-Log "Started Search-CACApplications()" "DEBUG"

    try {
        $search = Read-Host "Enter search term (AppID)"
        if ([string]::IsNullOrWhiteSpace($search)) {
            Write-Host "Search term cannot be empty." -ForegroundColor Yellow
            return
        }

        # Since there's no direct search API for Apps in PIM services mostly,
        # we fetch all and filter client-side (efficient enough for reasonable app counts)
        # OR we try to filter by AppID parameter if supported exact match.
        # But for partial search, client-side is safer given typical PIM API limits.

        Write-Host "Searching applications..." -ForegroundColor Cyan

        $endpoint = "/WebServices/PIMServices.svc/Applications/"
        $response = Invoke-CACAPIRequest -Method GET -Endpoint $endpoint
        
        $apps = @()
        if ($response.value) { $apps = @($response.value) }
        elseif ($response -is [array]) { $apps = @($response) }

        $results = $apps | Where-Object { $_.AppID -like "*$search*" -or $_.Description -like "*$search*" }

        if ($results.Count -eq 0) {
            Write-Host "No applications found matching '$search'." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "===== Search Results =====" -ForegroundColor Cyan
        Write-Host "Found $($results.Count) application(s)"
        Write-Host ""

        $results | Format-Table AppID, Description, Location, AccessPermittedTo -AutoSize

        return $results
    }
    catch {
        Write-Log "Error in Search-CACApplications(): $($_.Exception.Message)" "ERROR"
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function `
    Get-CACAllApplications, `
    Get-CACApplicationDetails, `
    Get-CACAppAuthMethods, `
    Search-CACApplications
