#Requires -Version 5.1
<#
.SYNOPSIS
    Server Navigator - Quick access to server shares and log folders.
.DESCRIPTION
    A lightweight PowerShell GUI tool that reduces the repetitive effort of
    accessing server shares and log folders from a VDI environment.
.NOTES
    - No external dependencies required
    - Credentials stored in memory only
    - Configuration stored in servers.json
#>

# INITIALIZATION

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigFile = Join-Path $script:ScriptDir "servers.json"
$script:Credentials = @{ "DEV" = $null; "PROD" = $null }
$script:ActiveEnv = "DEV"

# CONFIGURATION FUNCTIONS

function Load-Servers {
    if (Test-Path $script:ConfigFile) {
        try {
            $content = Get-Content $script:ConfigFile -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($content)) { return @() }
            $data = $content | ConvertFrom-Json
            if ($null -eq $data) { return @() }
            
            $flatServers = [System.Collections.ArrayList]::new()
            
            if ($data -is [System.Array] -or ($data -isnot [System.Management.Automation.PSCustomObject])) {
                # Legacy format: Array of objects
                $servers = if ($data -is [System.Array]) { $data } else { @($data) }
                foreach ($s in $servers) {
                    if ($null -eq $s.Environment) { $s | Add-Member -MemberType NoteProperty -Name Environment -Value "DEV" -Force }
                    if ($null -eq $s.Bookmarks) { $s | Add-Member -MemberType NoteProperty -Name Bookmarks -Value @() -Force }
                    $flatServers.Add($s) | Out-Null
                }
            }
            else {
                # New format: { "DEV": [...], "PROD": [...] }
                foreach ($env in $data.PSObject.Properties.Name) {
                    $envServers = $data.$env
                    if ($null -eq $envServers) { continue }
                    if ($envServers -isnot [System.Array]) { $envServers = @($envServers) }
                    foreach ($s in $envServers) {
                        $s | Add-Member -MemberType NoteProperty -Name Environment -Value $env -Force
                        if ($null -eq $s.Bookmarks) { $s | Add-Member -MemberType NoteProperty -Name Bookmarks -Value @() -Force }
                        $flatServers.Add($s) | Out-Null
                    }
                }
            }
            return $flatServers.ToArray()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Error loading servers.json: $($_.Exception.Message)",
                "Load Error", "OK", "Error")
            return @()
        }
    }
    else {
        # Create default config
        "{ `"DEV`": [], `"PROD`": [] }" | Set-Content $script:ConfigFile -Encoding UTF8
        return @()
    }
}

function Save-Servers {
    param([array]$Servers)
    try {
        $grouped = [PSCustomObject]@{}
        $envs = @($Servers | Select-Object -ExpandProperty Environment -Unique)
        foreach ($e in @("DEV", "PROD")) { if ($envs -notcontains $e) { $envs += $e } }
        
        foreach ($env in $envs) {
            $envServers = $Servers | Where-Object { $_.Environment -eq $env }
            if ($envServers) {
                $cleanServers = @()
                foreach ($s in $envServers) {
                    $cleanObj = [PSCustomObject]@{
                        Name      = $s.Name
                        SharePath = $s.SharePath
                        Bookmarks = $s.Bookmarks
                    }
                    $cleanServers += $cleanObj
                }
                $grouped | Add-Member -MemberType NoteProperty -Name $env -Value $cleanServers
            }
            else {
                $grouped | Add-Member -MemberType NoteProperty -Name $env -Value @()
            }
        }
        $grouped | ConvertTo-Json -Depth 4 | Set-Content $script:ConfigFile -Encoding UTF8
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error saving servers.json: $($_.Exception.Message)",
            "Save Error", "OK", "Error")
    }
}

# CREDENTIAL FUNCTIONS

function Get-SessionCredential {
    param(
        [string]$Environment = "DEV",
        [bool]$ExitOnCancel = $false
    )
    $loginForm = New-Object System.Windows.Forms.Form
    $loginForm.Text = "Server Navigator - Login ($Environment)"
    $loginForm.Size = New-Object System.Drawing.Size(400, 260)
    $loginForm.StartPosition = "CenterScreen"
    $loginForm.FormBorderStyle = "FixedDialog"
    $loginForm.MaximizeBox = $false
    $loginForm.MinimizeBox = $false
    $loginForm.TopMost = $true
    $loginForm.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $loginForm.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    $lblHeader = New-Object System.Windows.Forms.Label
    $lblHeader.Text = "Enter credentials for $Environment access"
    $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblHeader.ForeColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $lblHeader.Location = New-Object System.Drawing.Point(20, 15)
    $lblHeader.Size = New-Object System.Drawing.Size(350, 25)
    $loginForm.Controls.Add($lblHeader)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Location = New-Object System.Drawing.Point(20, 55)
    $lblUser.Size = New-Object System.Drawing.Size(80, 23)
    $loginForm.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Text = "S123456"
    $txtUser.Location = New-Object System.Drawing.Point(110, 53)
    $txtUser.Size = New-Object System.Drawing.Size(250, 23)
    $loginForm.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Location = New-Object System.Drawing.Point(20, 95)
    $lblPass.Size = New-Object System.Drawing.Size(80, 23)
    $loginForm.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(110, 93)
    $txtPass.Size = New-Object System.Drawing.Size(250, 23)
    $txtPass.UseSystemPasswordChar = $true
    $loginForm.Controls.Add($txtPass)

    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text = "Login"
    $btnLogin.Size = New-Object System.Drawing.Size(100, 34)
    $btnLogin.Location = New-Object System.Drawing.Point(150, 150)
    $btnLogin.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $btnLogin.ForeColor = [System.Drawing.Color]::White
    $btnLogin.FlatStyle = "Flat"
    $btnLogin.DialogResult = "OK"
    $loginForm.AcceptButton = $btnLogin
    $loginForm.Controls.Add($btnLogin)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = "Exit"
    $btnExit.Size = New-Object System.Drawing.Size(100, 34)
    $btnExit.Location = New-Object System.Drawing.Point(260, 150)
    $btnExit.FlatStyle = "Flat"
    $btnExit.DialogResult = "Cancel"
    $loginForm.CancelButton = $btnExit
    $loginForm.Controls.Add($btnExit)

    # Focus password field on load
    $loginForm.Add_Shown({ $txtPass.Focus() })

    $result = $loginForm.ShowDialog()

    if ($result -eq "OK" -and -not [string]::IsNullOrWhiteSpace($txtPass.Text)) {
        $secPass = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($txtUser.Text, $secPass)
        $loginForm.Dispose()
        return $cred
    }

    $loginForm.Dispose()
    if ($ExitOnCancel) {
        [System.Windows.Forms.MessageBox]::Show(
            "Credentials are required to use Server Navigator.",
            "Authentication Required", "OK", "Warning")
        exit
    }
    return $null
}

# CONNECTION FUNCTIONS

function Connect-ServerPath {
    param(
        [string]$UncPath,
        [PSCredential]$Credential
    )

    # Check if this is a local path (does not start with \\)
    if ($UncPath -notlike "\\*") {
        return @{ Success = $true; Message = "Local path" }
    }

    # Extract the root share (e.g., \\SERVER\D$) from the full path
    $parts = $UncPath.TrimStart('\').Split('\')
    if ($parts.Count -lt 2) {
        return @{ Success = $false; Message = "Invalid UNC path: $UncPath" }
    }
    $rootShare = "\\$($parts[0])\$($parts[1])"

    try {
        # Remove any existing connection to avoid conflicts
        net use $rootShare /delete /y 2>$null | Out-Null

        # Connect with credentials
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $result = net use $rootShare /user:$username $password 2>&1

        if ($LASTEXITCODE -ne 0) {
            return @{ Success = $false; Message = "Connection failed: $result" }
        }

        return @{ Success = $true; Message = "Connected" }
    }
    catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

function Open-ServerPath {
    param(
        [string]$UncPath,
        [PSCredential]$Credential,
        [string]$ActionLabel
    )

    if ([string]::IsNullOrWhiteSpace($UncPath)) {
        Update-StatusBar "No path configured for this action" "Warning"
        [System.Windows.Forms.MessageBox]::Show(
            "No path is configured for this action.",
            "Path Not Configured", "OK", "Warning")
        return
    }

    Update-StatusBar "Connecting to $UncPath..." "Info"

    $connection = Connect-ServerPath -UncPath $UncPath -Credential $Credential

    if ($connection.Success) {
        if (Test-Path $UncPath) {
            explorer.exe $UncPath
            Update-StatusBar "$ActionLabel opened: $UncPath" "OK"
        }
        else {
            Update-StatusBar "Path not found: $UncPath" "Warning"
            [System.Windows.Forms.MessageBox]::Show(
                "The path does not exist:`n`n$UncPath",
                "Path Not Found", "OK", "Warning")
        }
    }
    else {
        Update-StatusBar "Connection failed" "Error"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not connect to the server.`n`n$($connection.Message)",
            "Connection Failed", "OK", "Error")
    }
}


. "$PSScriptRoot\ServerNavigator-UI.ps1"
