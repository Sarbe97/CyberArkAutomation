function Refresh-BookmarkList {
    $script:lstBookmarks.Items.Clear()
    $server = Get-SelectedServer
    if ($null -ne $server -and $null -ne $server.Bookmarks) {
        foreach ($b in $server.Bookmarks) {
            $script:lstBookmarks.Items.Add($b.Name)
        }
    }
}

function Get-SelectedBookmark {
    $server = Get-SelectedServer
    if ($null -eq $server) { return $null }

    $selectedName = $script:lstBookmarks.SelectedItem
    if ($null -eq $selectedName) { return $null }

    return $server.Bookmarks | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
}

function Show-BookmarkNamePrompt {
    param([string]$DefaultName)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Name Bookmark"
    $dlg.Size = New-Object System.Drawing.Size(350, 160)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Enter a name for this bookmark:"
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(300, 20)
    $dlg.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $DefaultName
    $txt.Location = New-Object System.Drawing.Point(20, 40)
    $txt.Size = New-Object System.Drawing.Size(290, 23)
    $dlg.Controls.Add($txt)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(110, 80)
    $btnOK.Size = New-Object System.Drawing.Size(90, 30)
    $btnOK.DialogResult = "OK"
    $dlg.AcceptButton = $btnOK
    $dlg.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(210, 80)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.DialogResult = "Cancel"
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.Add($btnCancel)

    $dlg.Add_Shown({ $txt.Focus() })

    $result = $dlg.ShowDialog()
    $name = $txt.Text
    $dlg.Dispose()

    if ($result -eq "OK") {
        return $name.Trim()
    }
    return $null
}

# UI HELPER FUNCTIONS

function Update-StatusBar {
    param([string]$Message, [string]$Type = "Info")
    $color = switch ($Type) {
        "OK" { [System.Drawing.Color]::FromArgb(46, 125, 50) }
        "Error" { [System.Drawing.Color]::FromArgb(198, 40, 40) }
        "Warning" { [System.Drawing.Color]::FromArgb(230, 126, 34) }
        default { [System.Drawing.Color]::FromArgb(55, 71, 79) }
    }
    $script:lblStatus.ForeColor = $color
    $script:lblStatus.Text = $Message
}

$script:ServerStatus = @{}

function Start-PingCheck {
    param([string]$ServerName, [string]$Address)
    if ($ServerName -eq "Local" -or $Address -notlike "\\*") {
        $script:ServerStatus[$ServerName] = "Online"
        $script:lstServers.Invalidate()
        return
    }
    
    # Extract hostname
    $hostName = $Address.TrimStart('\').Split('\')[0]
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $script:ServerStatus[$ServerName] = "Offline"
        $script:lstServers.Invalidate()
        return
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    Register-ObjectEvent -InputObject $ping -EventName "PingCompleted" -Action {
        $reply = $event.SourceEventArgs.Reply
        $srvName = $event.MessageData
        if ($reply -and $reply.Status -eq "Success") {
            $script:ServerStatus[$srvName] = "Online"
        }
        else {
            $script:ServerStatus[$srvName] = "Offline"
        }
        if ($script:lstServers) {
            $script:lstServers.Invalidate()
        }
        Unregister-Event -SourceIdentifier $event.SubscriptionId -ErrorAction SilentlyContinue
    } -MessageData $ServerName | Out-Null
    
    try {
        $ping.SendAsync($hostName, 1000, $null)
    }
    catch {
        $script:ServerStatus[$ServerName] = "Offline"
        if ($script:lstServers) {
            $script:lstServers.Invalidate()
        }
    }
}

function Get-ServerDisplayLabel {
    param([PSCustomObject]$Server)
    # Only UNC paths have a meaningful hostname/IP to show
    if ($Server.SharePath -notlike '\\*') { return $Server.Name }
    $hostPart = $Server.SharePath.TrimStart('\').Split('\')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($hostPart)) { return $Server.Name }
    return "$($Server.Name)  ($hostPart)"
}

function Refresh-ServerList {
    param([string]$Filter = "")
    $script:Servers = Load-Servers
    $script:lstServers.Items.Clear()
    $filtered = $script:Servers | Where-Object {
        $_.Environment -eq $script:ActiveEnv -and
        ([string]::IsNullOrWhiteSpace($Filter) -or $_.Name -like "*$Filter*")
    } | Sort-Object Name
    foreach ($srv in $filtered) {
        $label = Get-ServerDisplayLabel $srv
        $script:lstServers.Items.Add($label)
        $script:ServerStatus[$srv.Name] = "Checking"
        Start-PingCheck -ServerName $srv.Name -Address $srv.SharePath
    }
    $userStr = if ($script:Credentials[$script:ActiveEnv]) { $script:Credentials[$script:ActiveEnv].UserName } else { "None" }
    Update-StatusBar "Loaded $($script:lstServers.Items.Count) server(s) | User: $userStr" "Info"
}

function Get-SelectedServer {
    $selected = $script:lstServers.SelectedItem
    if ($null -eq $selected) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select a server from the list.",
            "No Selection", "OK", "Information")
        return $null
    }
    # Display label may be "Name  (hostname)" — extract the name part before the first two spaces
    $serverName = ($selected -split '  ')[0].Trim()
    return $script:Servers | Where-Object { $_.Name -eq $serverName -and $_.Environment -eq $script:ActiveEnv }
}

# SERVER MANAGEMENT DIALOGS

function Show-ServerDialog {
    param(
        [string]$Title = "Add Server",
        [string]$ServerName = "",
        [string]$Hostname = "",
        [switch]$DetectDrives
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$Title ($($script:ActiveEnv))"
    $dlg.Size = New-Object System.Drawing.Size(480, 210)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    # Server Name
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Server Name:"
    $lblName.Location = New-Object System.Drawing.Point(20, 20)
    $lblName.Size = New-Object System.Drawing.Size(100, 23)
    $dlg.Controls.Add($lblName)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Text = $ServerName
    $txtName.Location = New-Object System.Drawing.Point(130, 18)
    $txtName.Size = New-Object System.Drawing.Size(310, 23)
    $dlg.Controls.Add($txtName)

    # Hostname
    $lblHost = New-Object System.Windows.Forms.Label
    $lblHost.Text = "Hostname:"
    $lblHost.Location = New-Object System.Drawing.Point(20, 60)
    $lblHost.Size = New-Object System.Drawing.Size(100, 23)
    $dlg.Controls.Add($lblHost)

    $txtHost = New-Object System.Windows.Forms.TextBox
    $txtHost.Text = $Hostname
    $txtHost.Location = New-Object System.Drawing.Point(130, 58)
    $txtHost.Size = New-Object System.Drawing.Size(310, 23)
    $dlg.Controls.Add($txtHost)

    # Hint
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Enter hostname only, e.g. CYBERARK-PRD01"
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Location = New-Object System.Drawing.Point(130, 90)
    $lblHint.Size = New-Object System.Drawing.Size(310, 20)
    $dlg.Controls.Add($lblHint)

    # Buttons
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Save"
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.Location = New-Object System.Drawing.Point(240, 125)
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = "Flat"
    $btnOK.DialogResult = "OK"
    $dlg.AcceptButton = $btnOK
    $dlg.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Location = New-Object System.Drawing.Point(340, 125)
    $btnCancel.FlatStyle = "Flat"
    $btnCancel.DialogResult = "Cancel"
    $dlg.CancelButton = $btnCancel
    $dlg.Controls.Add($btnCancel)

    # Validation on OK
    $btnOK.Add_Click({
            if ([string]::IsNullOrWhiteSpace($txtName.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Server name is required.", "Validation", "OK", "Warning")
                $_.Cancel = $true
                return
            }
            if ([string]::IsNullOrWhiteSpace($txtHost.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Hostname is required.", "Validation", "OK", "Warning")
                $_.Cancel = $true
                return
            }
            if ($DetectDrives) {
                $btnOK.Text = "Detecting..."
                $btnOK.Enabled = $false
                $btnCancel.Enabled = $false
                $dlg.Refresh()

                $hostValue = $txtHost.Text.Trim().TrimStart('\')
                $uncPath = "\\$hostValue"
                $connection = Connect-ServerPath -UncPath $uncPath -Credential $script:Credentials[$script:ActiveEnv]

                $detectedDrives = @()
                if ($connection.Success) {
                    $driveLetters = @("C", "D", "E", "F", "G")
                    foreach ($letter in $driveLetters) {
                        $testPath = "\\$hostValue\${letter}`$"
                        try {
                            if (Test-Path $testPath -ErrorAction SilentlyContinue) {
                                $detectedDrives += $letter
                            }
                        } catch {}
                    }
                }
                $script:TempDetectedDrives = $detectedDrives
            }

            $dlg.DialogResult = "OK"
        })

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -eq "OK") {
        $hostValue = $txtHost.Text.Trim().TrimStart('\')
        return [PSCustomObject]@{
            Name        = $txtName.Text.Trim()
            Hostname    = $hostValue
            SharePath   = "\\$hostValue"
            Environment = $script:ActiveEnv
        }
    }
    return $null
}

function Show-DriveSelector {
    param(
        [string]$Hostname,
        [PSCredential]$Credential
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Select Drives - $Hostname"
    $dlg.Size = New-Object System.Drawing.Size(400, 380)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Detecting shared drives on $Hostname..."
    $lblInfo.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $lblInfo.Location = New-Object System.Drawing.Point(20, 15)
    $lblInfo.Size = New-Object System.Drawing.Size(350, 25)
    $dlg.Controls.Add($lblInfo)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Select drives to create as bookmarks:"
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $lblHint.Location = New-Object System.Drawing.Point(20, 45)
    $lblHint.Size = New-Object System.Drawing.Size(350, 20)
    $dlg.Controls.Add($lblHint)

    $checkedList = New-Object System.Windows.Forms.CheckedListBox
    $checkedList.Location = New-Object System.Drawing.Point(20, 70)
    $checkedList.Size = New-Object System.Drawing.Size(340, 180)
    $checkedList.Font = New-Object System.Drawing.Font("Consolas", 10.5)
    $checkedList.BorderStyle = "FixedSingle"
    $checkedList.CheckOnClick = $true
    $dlg.Controls.Add($checkedList)

    # Probe drives C through G
    $driveLetters = @("C", "D", "E", "F", "G")
    $detectedDrives = @()

    foreach ($letter in $driveLetters) {
        $uncPath = "\\$Hostname\${letter}`$"
        try {
            if (Test-Path $uncPath -ErrorAction SilentlyContinue) {
                $detectedDrives += $letter
                $idx = $checkedList.Items.Add("${letter}`$ Drive  ($uncPath)")
                $checkedList.SetItemChecked($idx, $true)
            }
        }
        catch {
            # Drive not accessible, skip
        }
    }

    if ($detectedDrives.Count -eq 0) {
        $lblInfo.Text = "No drives detected on $Hostname"
        $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
        $lblHint.Text = "The server may be offline or you may not have permission."
    }
    else {
        $lblInfo.Text = "Found $($detectedDrives.Count) drive(s) on $Hostname"
        $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    }

    # Select All / Deselect All
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select All"
    $btnSelectAll.Location = New-Object System.Drawing.Point(20, 260)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100, 28)
    $btnSelectAll.FlatStyle = "Flat"
    $btnSelectAll.Add_Click({
            for ($i = 0; $i -lt $checkedList.Items.Count; $i++) {
                $checkedList.SetItemChecked($i, $true)
            }
        })
    $dlg.Controls.Add($btnSelectAll)

    $btnDeselectAll = New-Object System.Windows.Forms.Button
    $btnDeselectAll.Text = "Deselect All"
    $btnDeselectAll.Location = New-Object System.Drawing.Point(130, 260)
    $btnDeselectAll.Size = New-Object System.Drawing.Size(100, 28)
    $btnDeselectAll.FlatStyle = "Flat"
    $btnDeselectAll.Add_Click({
            for ($i = 0; $i -lt $checkedList.Items.Count; $i++) {
                $checkedList.SetItemChecked($i, $false)
            }
        })
    $dlg.Controls.Add($btnDeselectAll)

    # OK / Skip buttons
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Create Bookmarks"
    $btnOK.Size = New-Object System.Drawing.Size(140, 32)
    $btnOK.Location = New-Object System.Drawing.Point(100, 300)
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = "Flat"
    $btnOK.DialogResult = "OK"
    $dlg.AcceptButton = $btnOK
    $dlg.Controls.Add($btnOK)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Skip"
    $btnSkip.Size = New-Object System.Drawing.Size(90, 32)
    $btnSkip.Location = New-Object System.Drawing.Point(250, 300)
    $btnSkip.FlatStyle = "Flat"
    $btnSkip.DialogResult = "Cancel"
    $dlg.CancelButton = $btnSkip
    $dlg.Controls.Add($btnSkip)

    $dialogResult = $dlg.ShowDialog()

    $selectedDrives = @()
    if ($dialogResult -eq "OK") {
        for ($i = 0; $i -lt $checkedList.Items.Count; $i++) {
            if ($checkedList.GetItemChecked($i)) {
                $selectedDrives += $detectedDrives[$i]
            }
        }
    }

    $dlg.Dispose()
    return $selectedDrives
}

# MAIN FORM

function Ensure-Credentials {
    if ($null -eq $script:Credentials[$script:ActiveEnv]) {
        $envs = @($script:Servers | Select-Object -ExpandProperty Environment -Unique)
        if ($envs.Count -eq 0) { $envs = @("PROD") }
        if ($envs -notcontains $script:ActiveEnv) { $envs += $script:ActiveEnv }
        
        $credObj = Get-SessionCredential -AvailableEnvironments $envs -InitialEnvironment $script:ActiveEnv -ExitOnCancel $false
        if ($null -ne $credObj) {
            $script:ActiveEnv = $credObj.Environment
            $script:Credentials[$script:ActiveEnv] = $credObj.Credential
            if ($cmbEnv) { 
                $script:InEnvSwitch = $true
                $cmbEnv.SelectedItem = $script:ActiveEnv
                $script:InEnvSwitch = $false
            }
            return $true
        }
        return $false
    }
    return $true
}

$script:Servers = Load-Servers
$initialEnvs = @($script:Servers | Select-Object -ExpandProperty Environment -Unique)
if ($initialEnvs.Count -eq 0) { $initialEnvs = @("PROD") }
$script:ActiveEnv = $initialEnvs[0]

# Prompt for credentials first
$initCredObj = Get-SessionCredential -AvailableEnvironments $initialEnvs -InitialEnvironment $script:ActiveEnv -ExitOnCancel $true
if ($null -ne $initCredObj) {
    $script:ActiveEnv = $initCredObj.Environment
    $script:Credentials[$script:ActiveEnv] = $initCredObj.Credential
}

# Build main window
$form = New-Object System.Windows.Forms.Form
$form.Text = "Server Navigator"
$form.Size = New-Object System.Drawing.Size(800, 530)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

# â”€â”€ Title Label â”€â”€
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Server Navigator"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$lblTitle.Size = New-Object System.Drawing.Size(250, 30)
$form.Controls.Add($lblTitle)

# â”€â”€ Environment Switcher â”€â”€
$lblEnvMain = New-Object System.Windows.Forms.Label
$lblEnvMain.Text = "Env:"
$lblEnvMain.Location = New-Object System.Drawing.Point(300, 16)
$lblEnvMain.Size = New-Object System.Drawing.Size(40, 23)
$form.Controls.Add($lblEnvMain)

$cmbEnv = New-Object System.Windows.Forms.ComboBox
$cmbEnv.DropDownStyle = "DropDownList"
$cmbEnv.Items.Add("DEV") | Out-Null
$cmbEnv.Items.Add("PROD") | Out-Null
$cmbEnv.SelectedItem = $script:ActiveEnv
$cmbEnv.Location = New-Object System.Drawing.Point(345, 14)
$cmbEnv.Size = New-Object System.Drawing.Size(135, 23)

$script:InEnvSwitch = $false
$cmbEnv.Add_SelectedIndexChanged({
        if ($script:InEnvSwitch) { return }
        $newEnv = $cmbEnv.SelectedItem
        if ($newEnv -ne $script:ActiveEnv) {
            if ($null -eq $script:Credentials[$newEnv]) {
                $envs = @($script:Servers | Select-Object -ExpandProperty Environment -Unique)
                if ($envs.Count -eq 0) { $envs = @("PROD") }
                if ($envs -notcontains $newEnv) { $envs += $newEnv }
                
                $credObj = Get-SessionCredential -AvailableEnvironments $envs -InitialEnvironment $newEnv -ExitOnCancel $false
                if ($null -eq $credObj) {
                    # Revert selection
                    $script:InEnvSwitch = $true
                    $cmbEnv.SelectedItem = $script:ActiveEnv
                    $script:InEnvSwitch = $false
                    return
                }
                $newEnv = $credObj.Environment
                $script:Credentials[$newEnv] = $credObj.Credential
                
                # In case they selected a DIFFERENT environment from the dropdown in the credential prompt
                $script:InEnvSwitch = $true
                $cmbEnv.SelectedItem = $newEnv
                $script:InEnvSwitch = $false
            }
            $script:ActiveEnv = $newEnv
            $script:lstServers.SelectedIndex = -1
            $script:lstBookmarks.Items.Clear()
            Refresh-ServerList -Filter $txtSearch.Text
        }
    })
$form.Controls.Add($cmbEnv)

# â”€â”€ Search Box â”€â”€
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Search:"
$lblSearch.Location = New-Object System.Drawing.Point(20, 52)
$lblSearch.Size = New-Object System.Drawing.Size(55, 23)
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(80, 50)
$txtSearch.Size = New-Object System.Drawing.Size(400, 23)
$txtSearch.Add_TextChanged({
        Refresh-ServerList -Filter $txtSearch.Text
    })
$form.Controls.Add($txtSearch)

# â”€â”€ Server List â”€â”€
$script:lstServers = New-Object System.Windows.Forms.ListBox
$script:lstServers.Location = New-Object System.Drawing.Point(20, 85)
$script:lstServers.Size = New-Object System.Drawing.Size(460, 240)
$script:lstServers.Font = New-Object System.Drawing.Font("Consolas", 10.5)
$script:lstServers.BorderStyle = "FixedSingle"
$script:lstServers.DrawMode = "OwnerDrawFixed"
$script:lstServers.ItemHeight = 22

$script:lstServers.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $e.DrawBackground()

        $itemText  = $sender.Items[$e.Index]
        # Status lookup uses the server Name (before the hostname suffix)
        $srvName   = ($itemText -split '  ')[0].Trim()
        $status    = $script:ServerStatus[$srvName]

        $color = switch ($status) {
            "Online"  { [System.Drawing.Color]::FromArgb(46, 125, 50) }   # Green
            "Offline" { [System.Drawing.Color]::FromArgb(198, 40, 40) }  # Red
            default   { [System.Drawing.Color]::FromArgb(120, 120, 120) } # Gray
        }

        $brush     = New-Object System.Drawing.SolidBrush($color)
        $textBrush = New-Object System.Drawing.SolidBrush($e.ForeColor)

        # Draw status circle
        $circleY = $e.Bounds.Y + [int](($e.Bounds.Height - 8) / 2)
        $e.Graphics.FillEllipse($brush, $e.Bounds.X + 6, $circleY, 8, 8)

        # Draw text
        $font = $e.Font
        if ($null -eq $font) { $font = $sender.Font }
        $e.Graphics.DrawString($itemText, $font, $textBrush, $e.Bounds.X + 22, $e.Bounds.Y + 2)

        $brush.Dispose()
        $textBrush.Dispose()
        $e.DrawFocusRectangle()
    })

$script:lstServers.Add_SelectedIndexChanged({
        if ($script:lstServers.SelectedItem) {
            $srvLabel = $script:lstServers.SelectedItem
            $srvName  = ($srvLabel -split '  ')[0].Trim()
            $userStr  = if ($script:Credentials[$script:ActiveEnv]) { $script:Credentials[$script:ActiveEnv].UserName } else { "None" }
            Update-StatusBar "Selected: $srvName | User: $userStr" "Info"
            Refresh-BookmarkList
        }
    })
$form.Controls.Add($script:lstServers)

# ── Move Up / Move Down buttons ──
$btnMoveUp = New-Object System.Windows.Forms.Button
$btnMoveUp.Text = "▲"
$btnMoveUp.Size = New-Object System.Drawing.Size(32, 36)
$btnMoveUp.Location = New-Object System.Drawing.Point(485, 85)
$btnMoveUp.FlatStyle = "Flat"
$btnMoveUp.Cursor = "Hand"
$btnMoveUp.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnMoveUp.Add_Click({
    $idx = $script:lstServers.SelectedIndex
    if ($idx -le 0) { return }
    $servers = [System.Collections.ArrayList]@(Load-Servers)
    # Find the actual indices in the full list for this env
    $envList = @($servers | Where-Object { $_.Environment -eq $script:ActiveEnv })
    $selectedLabel = $script:lstServers.SelectedItem
    $selectedName  = ($selectedLabel -split '  ')[0].Trim()
    $currentSrv    = $envList | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    $prevSrv       = $envList[$idx - 1]
    # Swap in the flat list
    $iCurrent = $servers.IndexOf($currentSrv)
    $iPrev    = $servers.IndexOf($prevSrv)
    if ($iCurrent -ge 0 -and $iPrev -ge 0) {
        $tmp = $servers[$iCurrent]; $servers[$iCurrent] = $servers[$iPrev]; $servers[$iPrev] = $tmp
        Save-Servers $servers.ToArray()
        Refresh-ServerList -Filter $txtSearch.Text
        # Re-select moved item
        $newLabel = Get-ServerDisplayLabel $currentSrv
        $script:lstServers.SelectedItem = $newLabel
    }
})
$form.Controls.Add($btnMoveUp)

$btnMoveDown = New-Object System.Windows.Forms.Button
$btnMoveDown.Text = "▼"
$btnMoveDown.Size = New-Object System.Drawing.Size(32, 36)
$btnMoveDown.Location = New-Object System.Drawing.Point(485, 125)
$btnMoveDown.FlatStyle = "Flat"
$btnMoveDown.Cursor = "Hand"
$btnMoveDown.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnMoveDown.Add_Click({
    $idx = $script:lstServers.SelectedIndex
    if ($idx -lt 0 -or $idx -ge ($script:lstServers.Items.Count - 1)) { return }
    $servers = [System.Collections.ArrayList]@(Load-Servers)
    $envList = @($servers | Where-Object { $_.Environment -eq $script:ActiveEnv })
    $selectedLabel = $script:lstServers.SelectedItem
    $selectedName  = ($selectedLabel -split '  ')[0].Trim()
    $currentSrv    = $envList | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    $nextSrv       = $envList[$idx + 1]
    $iCurrent = $servers.IndexOf($currentSrv)
    $iNext    = $servers.IndexOf($nextSrv)
    if ($iCurrent -ge 0 -and $iNext -ge 0) {
        $tmp = $servers[$iCurrent]; $servers[$iCurrent] = $servers[$iNext]; $servers[$iNext] = $tmp
        Save-Servers $servers.ToArray()
        Refresh-ServerList -Filter $txtSearch.Text
        $newLabel = Get-ServerDisplayLabel $currentSrv
        $script:lstServers.SelectedItem = $newLabel
    }
})
$form.Controls.Add($btnMoveDown)

# â”€â”€ Action Buttons â”€â”€
$buttonY = 340
$buttonW = 145
$buttonH = 34
$buttonGap = 10
$col1 = 20
$col2 = 175
$col3 = 330

# Row 1 - Primary Actions
$btnRDP = New-Object System.Windows.Forms.Button
$btnRDP.Text = "RDP Connect"
$btnRDP.Size = New-Object System.Drawing.Size(145, 34)
$btnRDP.Location = New-Object System.Drawing.Point(20, 340)
$btnRDP.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
$btnRDP.ForeColor = [System.Drawing.Color]::White
$btnRDP.FlatStyle = "Flat"
$btnRDP.Cursor = "Hand"
$btnRDP.Add_Click({
        $server = Get-SelectedServer
        if ($server) {
            if (-not (Ensure-Credentials)) { return }
            $address = $server.SharePath
            if ($address -like "\\*") {
                $hostName = $address.TrimStart('\').Split('\')[0]
                Update-StatusBar "Initiating RDP connection to $hostName..." "Info"
            
                $rdpStarted = $false
                try {
                    $username = $script:Credentials[$script:ActiveEnv].UserName
                    $password = $script:Credentials[$script:ActiveEnv].GetNetworkCredential().Password
                
                    # Securely pass credentials to Windows Credential Vault temporarily
                    $cmdArgs = @("/generic:TERMSRV/$hostName", "/user:$username", "/pass:$password")
                    Start-Process -FilePath "cmdkey.exe" -ArgumentList $cmdArgs -WindowStyle Hidden -Wait

                    # Launch RDP
                    Start-Process mstsc.exe -ArgumentList "/v:$hostName"
                    $rdpStarted = $true
                
                    # Clean up stored credentials from vault after 10 seconds using a WinForms Timer
                    $cleanupTimer = New-Object System.Windows.Forms.Timer
                    $cleanupTimer.Interval = 10000
                    $cleanupTimer.Add_Tick({
                            $this.Stop()
                            $this.Dispose()
                            Start-Process -FilePath "cmdkey.exe" -ArgumentList "/delete:TERMSRV/$hostName" -WindowStyle Hidden -Wait
                        })
                    $cleanupTimer.Start()
                }
                catch {
                    if (-not $rdpStarted) {
                        # Fallback to standard RDP connection
                        Start-Process mstsc.exe -ArgumentList "/v:$hostName"
                    }
                }
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("RDP is only supported for remote servers (UNC paths).", "RDP Support", "OK", "Information")
            }
        }
    })
$form.Controls.Add($btnRDP)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Size = New-Object System.Drawing.Size(145, 34)
$btnRefresh.Location = New-Object System.Drawing.Point(175, 340)
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.Cursor = "Hand"
$btnRefresh.Add_Click({ Refresh-ServerList -Filter $txtSearch.Text })
$form.Controls.Add($btnRefresh)

# Row 2 - Management Actions
$row2Y = $buttonY + $buttonH + $buttonGap

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add Server"
$btnAdd.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$btnAdd.Location = New-Object System.Drawing.Point($col1, $row2Y)
$btnAdd.FlatStyle = "Flat"
$btnAdd.Cursor = "Hand"
$btnAdd.Add_Click({
        if (-not (Ensure-Credentials)) { return }
        $result = Show-ServerDialog -Title "Add Server" -DetectDrives
        if ($result) {
            $servers = [System.Collections.ArrayList]@(Load-Servers)
            $existing = $servers | Where-Object { $_.Name -eq $result.Name -and $_.Environment -eq $result.Environment }
            if ($existing) {
                [System.Windows.Forms.MessageBox]::Show(
                    "A server named '$($result.Name)' already exists.",
                    "Duplicate", "OK", "Warning")
                return
            }

            $bookmarks = @()
            if ($null -ne $script:TempDetectedDrives) {
                foreach ($drive in $script:TempDetectedDrives) {
                    $bookmarks += [PSCustomObject]@{
                        Name = "${drive}`$ Drive"
                        Path = "\\$($result.Hostname)\${drive}`$"
                    }
                }
                $script:TempDetectedDrives = $null
            }

            $newServer = [PSCustomObject]@{
                Name        = $result.Name
                SharePath   = $result.SharePath
                Environment = $result.Environment
                Bookmarks   = $bookmarks
            }
            $servers.Add($newServer) | Out-Null
            Save-Servers $servers.ToArray()
            Refresh-ServerList -Filter $txtSearch.Text
            Update-StatusBar "Server '$($result.Name)' added with $($bookmarks.Count) bookmark(s)" "OK"
        }
    })
$form.Controls.Add($btnAdd)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = "Edit Server"
$btnEdit.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$btnEdit.Location = New-Object System.Drawing.Point($col2, $row2Y)
$btnEdit.FlatStyle = "Flat"
$btnEdit.Cursor = "Hand"
$btnEdit.Add_Click({
        $server = Get-SelectedServer
        if ($server) {
            if (-not (Ensure-Credentials)) { return }
            # Extract hostname from SharePath for the dialog
            $currentHost = $server.SharePath.TrimStart('\')
            $result = Show-ServerDialog -Title "Edit Server" `
                -ServerName $server.Name `
                -Hostname $currentHost
            if ($result) {
                $servers = [System.Collections.ArrayList]@(Load-Servers)
                $idx = -1
                for ($i = 0; $i -lt $servers.Count; $i++) {
                    if ($servers[$i].Name -eq $server.Name -and $servers[$i].Environment -eq $server.Environment) { $idx = $i; break }
                }
                if ($idx -ge 0) {
                    $servers[$idx] = [PSCustomObject]@{
                        Name        = $result.Name
                        SharePath   = $result.SharePath
                        Environment = $result.Environment
                        Bookmarks   = $server.Bookmarks
                    }
                    Save-Servers $servers.ToArray()
                    Refresh-ServerList -Filter $txtSearch.Text
                    Update-StatusBar "Server '$($result.Name)' updated" "OK"
                }
            }
        }
    })
$form.Controls.Add($btnEdit)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete Server"
$btnDelete.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$btnDelete.Location = New-Object System.Drawing.Point($col3, $row2Y)
$btnDelete.FlatStyle = "Flat"
$btnDelete.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
$btnDelete.Cursor = "Hand"
$btnDelete.Add_Click({
        $server = Get-SelectedServer
        if ($server) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Delete server '$($server.Name)'?",
                "Confirm Delete", "YesNo", "Question")
            if ($confirm -eq "Yes") {
                $servers = [System.Collections.ArrayList]@(Load-Servers)
                $toRemove = $servers | Where-Object { $_.Name -eq $server.Name -and $_.Environment -eq $server.Environment }
                if ($toRemove) {
                    $servers.Remove($toRemove) | Out-Null
                    Save-Servers $servers.ToArray()
                    Refresh-ServerList -Filter $txtSearch.Text
                    Update-StatusBar "Server '$($server.Name)' deleted" "OK"
                }
            }
        }
    })
$form.Controls.Add($btnDelete)

# â”€â”€ Bookmarks Panel â”€â”€
$pnlBookmarks = New-Object System.Windows.Forms.GroupBox
$pnlBookmarks.Text = "Directory Bookmarks"
$pnlBookmarks.Location = New-Object System.Drawing.Point(500, 45)
$pnlBookmarks.Size = New-Object System.Drawing.Size(270, 383)
$form.Controls.Add($pnlBookmarks)

$script:lstBookmarks = New-Object System.Windows.Forms.ListBox
$script:lstBookmarks.Location = New-Object System.Drawing.Point(15, 25)
$script:lstBookmarks.Size = New-Object System.Drawing.Size(240, 200)
$script:lstBookmarks.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$script:lstBookmarks.BorderStyle = "FixedSingle"
$script:lstBookmarks.Add_DoubleClick({
        $bkm = Get-SelectedBookmark
        if ($bkm) {
            if (-not (Ensure-Credentials)) { return }
            Open-ServerPath -UncPath $bkm.Path -Credential $script:Credentials[$script:ActiveEnv] -ActionLabel "Bookmark"
        }
    })
$script:lstBookmarks.Add_SelectedIndexChanged({
        $btnAddBkm.Enabled = ($null -ne $script:lstBookmarks.SelectedItem)
    })
$pnlBookmarks.Controls.Add($script:lstBookmarks)

$btnOpenBkmViewer = New-Object System.Windows.Forms.Button
$btnOpenBkmViewer.Text = "View Logs"
$btnOpenBkmViewer.Location = New-Object System.Drawing.Point(15, 235)
$btnOpenBkmViewer.Size = New-Object System.Drawing.Size(115, 32)
$btnOpenBkmViewer.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
$btnOpenBkmViewer.ForeColor = [System.Drawing.Color]::White
$btnOpenBkmViewer.FlatStyle = "Flat"
$btnOpenBkmViewer.Cursor = "Hand"
$btnOpenBkmViewer.Add_Click({
        $bkm = Get-SelectedBookmark
        $server = Get-SelectedServer
        if ($bkm -and $server) {
            if (-not (Ensure-Credentials)) { return }
            $fakeServer = [PSCustomObject]@{
                Name = "$($server.Name) - $($bkm.Name)"
                Path = $bkm.Path
            }
            Show-LogViewer -Server $fakeServer -Credential $script:Credentials[$script:ActiveEnv]
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Please select a bookmark.", "No Selection", "OK", "Information")
        }
    })
$pnlBookmarks.Controls.Add($btnOpenBkmViewer)

$btnOpenBkmExplorer = New-Object System.Windows.Forms.Button
$btnOpenBkmExplorer.Text = "Open Folder"
$btnOpenBkmExplorer.Location = New-Object System.Drawing.Point(140, 235)
$btnOpenBkmExplorer.Size = New-Object System.Drawing.Size(115, 32)
$btnOpenBkmExplorer.FlatStyle = "Flat"
$btnOpenBkmExplorer.Cursor = "Hand"
$btnOpenBkmExplorer.Add_Click({
        $bkm = Get-SelectedBookmark
        if ($bkm) {
            if (-not (Ensure-Credentials)) { return }
            Open-ServerPath -UncPath $bkm.Path -Credential $script:Credentials[$script:ActiveEnv] -ActionLabel "Bookmark"
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Please select a bookmark.", "No Selection", "OK", "Information")
        }
    })
$pnlBookmarks.Controls.Add($btnOpenBkmExplorer)

$btnAddBkm = New-Object System.Windows.Forms.Button
$btnAddBkm.Text = "Browse & Bookmark"
$btnAddBkm.Location = New-Object System.Drawing.Point(15, 280)
$btnAddBkm.Size = New-Object System.Drawing.Size(240, 32)
$btnAddBkm.FlatStyle = "Flat"
$btnAddBkm.Cursor = "Hand"
$btnAddBkm.Enabled = $false
$btnAddBkm.Add_Click({
        $server = Get-SelectedServer
        $bkm = Get-SelectedBookmark
        
        if ($null -eq $server -or $null -eq $bkm) {
            return
        }

        Update-StatusBar "Connecting to $($bkm.Path)..." "Info"
        $connection = Connect-ServerPath -UncPath $bkm.Path -Credential $script:Credentials[$script:ActiveEnv]
        if (-not $connection.Success) {
            [System.Windows.Forms.MessageBox]::Show("Connection failed: $($connection.Message)", "Connection Error", "OK", "Error")
            return
        }

        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $browser.Description = "Select a folder to bookmark inside $($bkm.Path)"
        $browser.SelectedPath = $bkm.Path
        $browser.ShowNewFolderButton = $true

        if ($browser.ShowDialog() -eq "OK") {
            $path = $browser.SelectedPath
            $bookmarkName = Show-BookmarkNamePrompt -DefaultName (Split-Path -Leaf $path)
            if (-not [string]::IsNullOrWhiteSpace($bookmarkName)) {
                $existing = $server.Bookmarks | Where-Object { $_.Name -eq $bookmarkName }
                if ($existing) {
                    [System.Windows.Forms.MessageBox]::Show("A bookmark named '$bookmarkName' already exists.", "Duplicate Bookmark", "OK", "Warning")
                    return
                }

                $newBkm = [PSCustomObject]@{
                    Name = $bookmarkName
                    Path = $path
                }
            
                $bList = [System.Collections.ArrayList]@($server.Bookmarks)
                $bList.Add($newBkm) | Out-Null
                $server.Bookmarks = $bList.ToArray()

                Save-Servers $script:Servers
                Refresh-BookmarkList
                Update-StatusBar "Bookmark '$bookmarkName' added" "OK"
            }
        }
    })
$pnlBookmarks.Controls.Add($btnAddBkm)

$btnDeleteBkm = New-Object System.Windows.Forms.Button
$btnDeleteBkm.Text = "Delete Bookmark"
$btnDeleteBkm.Location = New-Object System.Drawing.Point(15, 325)
$btnDeleteBkm.Size = New-Object System.Drawing.Size(240, 32)
$btnDeleteBkm.FlatStyle = "Flat"
$btnDeleteBkm.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
$btnDeleteBkm.Cursor = "Hand"
$btnDeleteBkm.Add_Click({
        $server = Get-SelectedServer
        if ($null -eq $server) { return }

        $selectedName = $script:lstBookmarks.SelectedItem
        if ($null -eq $selectedName) {
            [System.Windows.Forms.MessageBox]::Show("Please select a bookmark to delete.", "No Selection", "OK", "Information")
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Delete bookmark '$selectedName'?",
            "Confirm Delete", "YesNo", "Question")
    
        if ($confirm -eq "Yes") {
            $bList = [System.Collections.ArrayList]@()
            foreach ($b in $server.Bookmarks) {
                if ($b.Name -ne $selectedName) {
                    $bList.Add($b) | Out-Null
                }
            }
            $server.Bookmarks = $bList.ToArray()

            Save-Servers $script:Servers
            Refresh-BookmarkList
            Update-StatusBar "Bookmark '$selectedName' deleted" "OK"
        }
    })
$pnlBookmarks.Controls.Add($btnDeleteBkm)

# â”€â”€ Status Bar â”€â”€
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(0, 440)
$statusPanel.Size = New-Object System.Drawing.Size(800, 30)
$statusPanel.BackColor = [System.Drawing.Color]::FromArgb(236, 239, 241)
$form.Controls.Add($statusPanel)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Location = New-Object System.Drawing.Point(10, 6)
$script:lblStatus.Size = New-Object System.Drawing.Size(660, 18)
$script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(55, 71, 79)
$statusPanel.Controls.Add($script:lblStatus)

$btnSwitchUser = New-Object System.Windows.Forms.Button
$btnSwitchUser.Text = "Switch User"
$btnSwitchUser.Location = New-Object System.Drawing.Point(680, 3)
$btnSwitchUser.Size = New-Object System.Drawing.Size(100, 24)
$btnSwitchUser.FlatStyle = "Flat"
$btnSwitchUser.Cursor = "Hand"
$btnSwitchUser.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnSwitchUser.Add_Click({
        $cred = Get-SessionCredential -Environment $script:ActiveEnv -ExitOnCancel $false
        if ($null -ne $cred) {
            $script:Credentials[$script:ActiveEnv] = $cred
            Refresh-ServerList -Filter $txtSearch.Text
            Update-StatusBar "Switched user to: $($script:Credentials[$script:ActiveEnv].UserName)" "OK"
        }
    })
$statusPanel.Controls.Add($btnSwitchUser)

# ———— Keyboard Shortcuts ————
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    # F5 — Refresh server list
    if ($e.KeyCode -eq "F5") {
        Refresh-ServerList -Filter $txtSearch.Text
        $e.Handled = $true
    }
    # Delete — Delete selected server (with confirmation)
    if ($e.KeyCode -eq "Delete" -and $script:lstServers.Focused) {
        $server = Get-SelectedServer
        if ($server) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Delete server '$($server.Name)'?",
                "Confirm Delete", "YesNo", "Question")
            if ($confirm -eq "Yes") {
                $servers = [System.Collections.ArrayList]@(Load-Servers)
                $toRemove = $servers | Where-Object { $_.Name -eq $server.Name -and $_.Environment -eq $server.Environment }
                if ($toRemove) {
                    $servers.Remove($toRemove) | Out-Null
                    Save-Servers $servers.ToArray()
                    Refresh-ServerList -Filter $txtSearch.Text
                    Update-StatusBar "Server '$($server.Name)' deleted" "OK"
                }
            }
        }
        $e.Handled = $true
    }
})

# ———— Load and Show ————
$userStr = if ($script:Credentials[$script:ActiveEnv]) { $script:Credentials[$script:ActiveEnv].UserName } else { "None" }
Refresh-ServerList
Update-StatusBar "$([char]0x2713) Authenticated as $userStr | $($script:lstServers.Items.Count) server(s) loaded" "OK"
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
$form.Dispose()
