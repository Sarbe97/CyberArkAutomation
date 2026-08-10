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
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigFile = Join-Path $script:ScriptDir "servers.json"
$script:Credentials = @{ "DEV" = $null; "PROD" = $null }
$script:ActiveEnv = "PROD"
$script:Servers = @()
$script:SavedUsers = @{}

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
                    if ($env -eq "Settings") {
                        if ($null -ne $data.Settings) {
                            foreach ($prop in $data.Settings.PSObject.Properties) {
                                $script:SavedUsers[$prop.Name] = $prop.Value
                            }
                        }
                        continue
                    }
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
        $settingsObj = [PSCustomObject]@{}
        if ($script:SavedUsers) {
            foreach ($key in $script:SavedUsers.Keys) {
                $settingsObj | Add-Member -MemberType NoteProperty -Name $key -Value $script:SavedUsers[$key]
            }
        }
        $grouped = [PSCustomObject]@{
            Settings = $settingsObj
        }
        
        $envs = @($Servers | Select-Object -ExpandProperty Environment -Unique | Where-Object { ![string]::IsNullOrEmpty($_) })
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
        [array]$AvailableEnvironments = @("PROD"),
        [string]$InitialEnvironment = "PROD",
        [bool]$ExitOnCancel = $false
    )
    $loginForm = New-Object System.Windows.Forms.Form
    $loginForm.Text = "Server Navigator - Login ($Environment)"
    $loginForm.Size = New-Object System.Drawing.Size(400, 290)
    $loginForm.StartPosition = "CenterScreen"
    $loginForm.FormBorderStyle = "FixedDialog"
    $loginForm.MaximizeBox = $false
    $loginForm.MinimizeBox = $false
    $loginForm.TopMost = $true
    $loginForm.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $loginForm.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    $lblEnv = New-Object System.Windows.Forms.Label
    $lblEnv.Text = "Environment:"
    $lblEnv.Location = New-Object System.Drawing.Point(20, 15)
    $lblEnv.Size = New-Object System.Drawing.Size(80, 23)
    $loginForm.Controls.Add($lblEnv)

    $cmbEnvLogin = New-Object System.Windows.Forms.ComboBox
    $cmbEnvLogin.DropDownStyle = "DropDown"
    foreach ($e in $AvailableEnvironments) { $cmbEnvLogin.Items.Add($e) | Out-Null }
    if ($cmbEnvLogin.Items.Contains($InitialEnvironment)) {
        $cmbEnvLogin.SelectedItem = $InitialEnvironment
    } else {
        $cmbEnvLogin.SelectedIndex = 0
    }
    $cmbEnvLogin.Location = New-Object System.Drawing.Point(110, 13)
    $cmbEnvLogin.Size = New-Object System.Drawing.Size(120, 23)
    $loginForm.Controls.Add($cmbEnvLogin)

    $lblHeader = New-Object System.Windows.Forms.Label
    $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblHeader.ForeColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $lblHeader.Location = New-Object System.Drawing.Point(20, 45)
    $lblHeader.Size = New-Object System.Drawing.Size(350, 20)
    $loginForm.Controls.Add($lblHeader)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Location = New-Object System.Drawing.Point(20, 75)
    $lblUser.Size = New-Object System.Drawing.Size(80, 23)
    $loginForm.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(110, 73)
    $txtUser.Size = New-Object System.Drawing.Size(250, 23)
    $loginForm.Controls.Add($txtUser)

    $updateCredentialsAction = {
        $env = $cmbEnvLogin.Text
        if ([string]::IsNullOrWhiteSpace($env)) { return }
        $loginForm.Text = "Server Navigator - Login ($env)"
        $lblHeader.Text = "Enter credentials for $env access"
        $expectedDomain = if ($env -eq "PROD") { "NA" } else { "nadev" }
        $savedUser = $script:SavedUsers["${env}_User"]
        if (-not [string]::IsNullOrWhiteSpace($savedUser)) {
            $txtUser.Text = $savedUser
        } else {
            $txtUser.Text = "$expectedDomain\$env:USERNAME"
        }
    }
    $cmbEnvLogin.Add_TextChanged($updateCredentialsAction)
    
    # Trigger initially
    & $updateCredentialsAction

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Location = New-Object System.Drawing.Point(20, 105)
    $lblPass.Size = New-Object System.Drawing.Size(80, 23)
    $loginForm.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(110, 103)
    $txtPass.Size = New-Object System.Drawing.Size(250, 23)
    $txtPass.UseSystemPasswordChar = $true
    $loginForm.Controls.Add($txtPass)

    # Validation status label (below password field)
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = ""
    $lblStatus.Location = New-Object System.Drawing.Point(110, 132)
    $lblStatus.Size = New-Object System.Drawing.Size(250, 20)
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $loginForm.Controls.Add($lblStatus)

    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text = "Login"
    $btnLogin.Size = New-Object System.Drawing.Size(100, 34)
    $btnLogin.Location = New-Object System.Drawing.Point(150, 175)
    $btnLogin.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $btnLogin.ForeColor = [System.Drawing.Color]::White
    $btnLogin.FlatStyle = "Flat"
    $loginForm.AcceptButton = $btnLogin
    $loginForm.Controls.Add($btnLogin)

    $btnLogin.Add_Click({
        $user = $txtUser.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($user)) {
            [System.Windows.Forms.MessageBox]::Show("Username cannot be empty.", "Validation Error", "OK", "Warning")
            return
        }
        if ([string]::IsNullOrWhiteSpace($txtPass.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Password cannot be empty.", "Validation Error", "OK", "Warning")
            return
        }
        
        $selEnv = $cmbEnvLogin.Text
        $domain = if ($selEnv -eq "PROD") { "NA" } else { "nadev" }
        
        if ($user -notlike "*\*") {
            $user = "$domain\$user"
            $txtUser.Text = $user
        } 
        elseif ($user -notmatch "^(?i)$domain\\") {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "You entered a domain that doesn't match the expected domain for $selEnv ($domain\).`n`nAre you sure you want to continue?",
                "Domain Mismatch", "YesNo", "Warning")
            if ($confirm -ne "Yes") {
                return
            }
        }

        # --- Credential Validation against Active Directory ---
        $btnLogin.Enabled = $false
        $btnLogin.Text = "Validating..."
        $lblStatus.Text = "Verifying credentials..."
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
        $loginForm.Refresh()

        $parts = $user -split '\\', 2
        $authDomain = $parts[0]
        $authUser = $parts[1]

        try {
            $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain, $authDomain)
            $valid = $context.ValidateCredentials($authUser, $txtPass.Text)
            $context.Dispose()

            if ($valid) {
                $lblStatus.Text = [char]0x2713 + " Credentials verified"
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
                $loginForm.Refresh()
                $loginForm.DialogResult = "OK"
            }
            else {
                $lblStatus.Text = "Invalid username or password"
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
                $btnLogin.Text = "Login"
                $btnLogin.Enabled = $true
                $txtPass.Focus()
                return
            }
        }
        catch {
            # AD unreachable — offer fallback
            $lblStatus.Text = "Could not reach domain controller"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
            $btnLogin.Text = "Login"
            $btnLogin.Enabled = $true

            $fallback = [System.Windows.Forms.MessageBox]::Show(
                "Could not validate credentials against the domain ($authDomain).`n`n$($_.Exception.Message)`n`nDo you want to continue without verification?",
                "Domain Unreachable", "YesNo", "Warning")
            if ($fallback -eq "Yes") {
                $lblStatus.Text = "Proceeding without verification"
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
                $loginForm.Refresh()
                $loginForm.DialogResult = "OK"
            }
            return
        }
    })

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = "Exit"
    $btnExit.Size = New-Object System.Drawing.Size(100, 34)
    $btnExit.Location = New-Object System.Drawing.Point(260, 175)
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
        
        $selEnv = $cmbEnvLogin.SelectedItem
        
        # Save username for next time
        if ($script:SavedUsers["${selEnv}_User"] -ne $txtUser.Text) {
            $script:SavedUsers["${selEnv}_User"] = $txtUser.Text
            if ($script:Servers) {
                Save-Servers $script:Servers
            } else {
                # Load them if not loaded yet so we don't wipe them
                $tmpServers = Load-Servers
                Save-Servers $tmpServers
            }
        }
        
        $loginForm.Dispose()
        return [PSCustomObject]@{ Credential = $cred; Environment = $selEnv }
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
        return [PSCustomObject]@{ Success = $true; Message = "Local path" }
    }

    # Extract the root share (e.g., \\SERVER\D$) from the full path
    $parts = $UncPath.TrimStart('\').Split('\')
    if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        return [PSCustomObject]@{ Success = $false; Message = "Invalid UNC path: $UncPath" }
    }
    
    # If only the server name is provided, connect to the IPC$ administrative share
    $rootShare = if ($parts.Count -eq 1) {
        "\\$($parts[0])\IPC`$"
    } else {
        "\\$($parts[0])\$($parts[1])"
    }

    try {
        # Remove any existing connection to avoid conflicts
        net use $rootShare /delete /y 2>$null | Out-Null

        # Connect with credentials
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $result = net use $rootShare /user:$username $password 2>&1

        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Success = $false; Message = "Connection failed: $result" }
        }

        return [PSCustomObject]@{ Success = $true; Message = "Connected" }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message }
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
        $isServerRoot = ($UncPath -like "\\*" -and $UncPath.TrimStart('\').Split('\').Count -eq 1)
        if ($isServerRoot -or (Test-Path $UncPath)) {
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

# Pre-load to populate SavedUsers before credential prompt
$script:Servers = Load-Servers
if (-not $script:SavedUsers.ContainsKey("LogExtensions")) {
    $script:SavedUsers["LogExtensions"] = @(".log")
    Save-Servers $script:Servers
}

. "$PSScriptRoot\LogViewer.ps1"
. "$PSScriptRoot\ServerNavigator-UI.ps1"
