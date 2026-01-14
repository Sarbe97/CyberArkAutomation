# SessionHelper.psm1
# Helper functions for session management across SAML and standard auth

function Get-CACValidSession {
    <#
    .SYNOPSIS
        Gets a valid session, falling back to global:CACSession if psPAS session is invalid
    #>
    
    # Try psPAS session first
    $pasSession = Get-PASSession -ErrorAction SilentlyContinue
    
    if ($pasSession) {
        # Check if session has valid BaseURI
        $baseURI = $null
        
        if ($pasSession -is [System.Collections.IDictionary]) {
            $baseURI = $pasSession['BaseURI']
        }
        else {
            $baseURI = $pasSession.BaseURI
        }
        
        if ($null -ne $baseURI -and -not [string]::IsNullOrWhiteSpace($baseURI)) {
            return $pasSession
        }
    }
    
    # Fallback to global:CACSession
    if ($null -ne $global:CACSession) {
        Write-Log "Using global:CACSession as fallback" "INFO"
        return $global:CACSession
    }
    
    return $null
}

function Invoke-CACPASCommand {
    <#
    .SYNOPSIS
        Wraps psPAS commands to work with SAML sessions
    .DESCRIPTION
        This function temporarily sets psPAS session if needed before running a psPAS cmdlet
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )
    
    $session = Get-CACValidSession
    
    if ($null -eq $session) {
        throw "Not logged in. Please login first."
    }
    
    # Check if psPAS session is valid
    $pasSession = Get-PASSession -ErrorAction SilentlyContinue
    $pasSessionValid = $false
    
    if ($pasSession) {
        $baseURI = if ($pasSession -is [System.Collections.IDictionary]) { $pasSession['BaseURI'] } else { $pasSession.BaseURI }
        $pasSessionValid = ($null -ne $baseURI -and -not [string]::IsNullOrWhiteSpace($baseURI))
    }
    
    if (-not $pasSessionValid -and $null -ne $global:CACSession) {
        # Inject global session back into psPAS for this command
        Write-Log "Temporarily injecting global:CACSession into psPAS for cmdlet execution" "DEBUG"
        
        try {
            $psPASModule = Get-Module psPAS
            if ($psPASModule) {
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
                
                $psPASModule.Invoke({
                        param($sessionHash)
                        $Script:PASSession = $sessionHash
                    }, $sessionData)
            }
        }
        catch {
            Write-Log "Session re-injection failed: $($_.Exception.Message)" "WARN"
        }
    }
    
    # Execute the command
    & $ScriptBlock
}

Export-ModuleMember -Function Get-CACValidSession, Invoke-CACPASCommand
