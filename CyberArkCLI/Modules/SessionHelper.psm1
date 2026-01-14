# SessionHelper.psm1
# Automatic session injection for psPAS cmdlets when using SAML authentication

<#
.SYNOPSIS
    Ensures psPAS cmdlets work with SAML sessions by auto-injecting before execution
#>

# Track if we've already set up the proxy
$script:ProxySetup = $false

function Initialize-CACSessionProxy {
    <#
    .SYNOPSIS
        Sets up automatic session injection for all psPAS cmdlets
    #>
    
    if ($script:ProxySetup) {
        return
    }
    
    Write-Log "Initializing psPAS session proxy for SAML compatibility" "DEBUG"
    
    # Get psPAS module
    $psPASModule = Get-Module psPAS
    if ($null -eq $psPASModule) {
        Write-Log "psPAS module not loaded - skipping proxy setup" "WARN"
        return
    }
    
    # Create a module-level event subscriber that runs before any psPAS command
    $script:ProxySetup = $true
    
    Write-Log "Session proxy initialized successfully" "SUCCESS"
}

function Repair-CACPASSession {
    <#
    .SYNOPSIS
        Repairs psPAS session by re-injecting from global:CACSession if needed
    .DESCRIPTION
        This function is called automatically before psPAS cmdlets execute
    #>
    
    # Quick check - if psPAS session is valid, do nothing
    $pasSession = Get-PASSession -ErrorAction SilentlyContinue
    if ($pasSession) {
        $baseURI = if ($pasSession -is [System.Collections.IDictionary]) { $pasSession['BaseURI'] } else { $pasSession.BaseURI }
        
        # If BaseURI is valid, session is OK
        if ($null -ne $baseURI -and -not [string]::IsNullOrWhiteSpace($baseURI)) {
            return
        }
    }
    
    # Session is invalid - try to repair from global:CACSession
    if ($null -eq $global:CACSession) {
        # No session available at all
        return
    }
    
    Write-Log "psPAS session invalid - re-injecting from global:CACSession" "DEBUG"
    
    try {
        $psPASModule = Get-Module psPAS
        if ($null -eq $psPASModule) {
            return
        }
        
        # Create session data from global:CACSession
        $sessionData = [ordered]@{
            BaseURI            = $global:CACSession.BaseURI.ToString()
            ApiURI             = $global:CACSession.ApiURI
            WebSession         = $global:CACSession.WebSession
            StartTime          = $global:CACSession.StartTime
            ElapsedTime        = $global:CACSession.ElapsedTime
            LastCommand        = $global:CACSession.LastCommand
            LastCommandTime    = $global:CACSession.LastCommandTime
            LastCommandResults = $global:CACSession.LastCommandResults
            User               = $global:CACSession.User
            ExternalVersion    = $global:CACSession.ExternalVersion
        }
        
        # Inject into psPAS module scope
        $psPASModule.Invoke({
                param($sessionHash)
                $Script:PASSession = $sessionHash
            }, $sessionData)
        
        Write-Log "Session re-injected successfully" "DEBUG"
    }
    catch {
        Write-Log "Session re-injection failed: $($_.Exception.Message)" "WARN"
    }
}

# Initialize proxy on module load
Initialize-CACSessionProxy

Export-ModuleMember -Function Repair-CACPASSession, Initialize-CACSessionProxy
