# Auth.psm1 - Login and logout to CyberArk PVWA REST API with approved verbs

function Get-PvwaUrlFromConfigOrPrompt {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ConfigFolderPath
    )

    # Default to Config folder relative to the calling script
    if (-not $ConfigFolderPath) {
        $ConfigFolderPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Config"
    }

    $configPath = Join-Path -Path $ConfigFolderPath -ChildPath "config.json"
    $lastPvwaUrl = if (Test-Path $configPath) { (Get-Content $configPath -Raw | ConvertFrom-Json).PvwaUrl }

    if ($lastPvwaUrl) {
        Write-Host "Previous PVWA URL: $lastPvwaUrl"
        $pvwaUrl = Read-Host "Enter PVWA URL (or press Enter to use previous)"
        if ([string]::IsNullOrWhiteSpace($pvwaUrl)) { $pvwaUrl = $lastPvwaUrl }
    }
    else {
        $pvwaUrl = Read-Host "Enter PVWA URL (e.g. https://pvwa.myorg.com)"
    }

    # Save PVWA URL back to config for next time
    if (-not (Test-Path $ConfigFolderPath)) {
        New-Item -ItemType Directory -Path $ConfigFolderPath -Force | Out-Null
    }
    $configObj = @{ PvwaUrl = $pvwaUrl }
    $configObj | ConvertTo-Json | Set-Content $configPath

    return $pvwaUrl
}

function Connect-CyberArk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl
    )

    $cred = Get-Credential -Message "Enter CyberArk credentials"

    $body = @{
        username = $cred.UserName
        password = $cred.GetNetworkCredential().Password
    } | ConvertTo-Json

    $loginUri = "$PvwaUrl/PasswordVault/API/Auth/CyberArk/Logon/"

    Write-Verbose "Logging in to $loginUri ..."
    try {
        $response = Invoke-RestMethod -Uri $loginUri -Method Post -ContentType "application/json" -Body $body -ErrorAction Stop

        if ($null -ne $response -and $response -is [string] -and $response.Length -gt 0) {
            Write-Verbose "Login successful."
            return @{
                Token = $response
                PvwaUrl = $PvwaUrl
            }
        }
        else {
            throw "Login failed: No token received."
        }
    }
    catch {
        throw "Login failed: $_"
    }
}

function Disconnect-CyberArk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PvwaUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $logoutUri = "$PvwaUrl/PasswordVault/API/Auth/Logoff"
    Write-Verbose "Logging out..."
    try {
        Invoke-RestMethod -Uri $logoutUri -Method Post -Headers @{ Authorization = $Token }
        Write-Verbose "Logged out successfully."
    }
    catch {
        Write-Warning "Logout failed: $_"
    }
}

Export-ModuleMember -Function Get-PvwaUrlFromConfigOrPrompt, Connect-CyberArk, Disconnect-CyberArk
