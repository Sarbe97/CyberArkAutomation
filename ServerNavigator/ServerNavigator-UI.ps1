function Show-LogViewer {
    param(
        [PSCustomObject]$Server,
        [PSCredential]$Credential
    )

    if ($null -eq $Server -or [string]::IsNullOrWhiteSpace($Server.Path)) {
        [System.Windows.Forms.MessageBox]::Show("Log path is not configured for this server.", "Error", "OK", "Warning")
        return
    }

    Update-StatusBar "Connecting to $($Server.Path)..." "Info"
    $connection = Connect-ServerPath -UncPath $Server.Path -Credential $Credential

    if (-not $connection.Success) {
        Update-StatusBar "Connection failed" "Error"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not connect to the server log path.`n`n$($connection.Message)",
            "Connection Failed", "OK", "Error")
        return
    }

    if (-not (Test-Path $Server.Path)) {
        Update-StatusBar "Log path not found" "Error"
        [System.Windows.Forms.MessageBox]::Show(
            "Connected to the server, but the log path does not exist:`n`n$($Server.Path)",
            "Path Not Found", "OK", "Error")
        return
    }

    Update-StatusBar "Logs connection established" "OK"

    # State variables
    $script:ActiveLogLines = @()
    $script:TailFilePath = $null
    $script:TailLastPosition = 0
    $script:LogFilterText = ""

    # Form setup
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Log Viewer - $($Server.Name) ($($Server.Path))"
    $dlg.Size = New-Object System.Drawing.Size(1000, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 250)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    
    # Enable resizing but keep a minimum size
    $dlg.MinimumSize = New-Object System.Drawing.Size(800, 500)

    # â”€â”€ SPLIT CONTAINER â”€â”€
    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Size = New-Object System.Drawing.Size(980, 600)
    $splitContainer.Dock = "Fill"
    $splitContainer.Panel1MinSize = 150
    $splitContainer.Panel2MinSize = 400
    $splitContainer.SplitterDistance = 240
    $dlg.Controls.Add($splitContainer)

    # â”€â”€ LEFT PANEL (FILE LIST) â”€â”€
    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = "Fill"
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $splitContainer.Panel1.Controls.Add($leftPanel)

    $lblFiles = New-Object System.Windows.Forms.Label
    $lblFiles.Text = "Log Files (Recent first):"
    $lblFiles.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $lblFiles.Dock = "Top"
    $lblFiles.Height = 25
    $leftPanel.Controls.Add($lblFiles)

    $lstFiles = New-Object System.Windows.Forms.ListBox
    $lstFiles.Dock = "Fill"
    $lstFiles.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lstFiles.BorderStyle = "FixedSingle"
    $leftPanel.Controls.Add($lstFiles)

    $btnRefreshList = New-Object System.Windows.Forms.Button
    $btnRefreshList.Text = "Refresh File List"
    $btnRefreshList.Dock = "Bottom"
    $btnRefreshList.Height = 32
    $btnRefreshList.FlatStyle = "Flat"
    $btnRefreshList.Cursor = "Hand"
    $btnRefreshList.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $leftPanel.Controls.Add($btnRefreshList)

    $btnSearchAll = New-Object System.Windows.Forms.Button
    $btnSearchAll.Text = "Search All Files"
    $btnSearchAll.Dock = "Bottom"
    $btnSearchAll.Height = 32
    $btnSearchAll.FlatStyle = "Flat"
    $btnSearchAll.Cursor = "Hand"
    $btnSearchAll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $leftPanel.Controls.Add($btnSearchAll)

    # â”€â”€ RIGHT PANEL (CONTENT VIEWER) â”€â”€
    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Dock = "Fill"
    $rightPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $splitContainer.Panel2.Controls.Add($rightPanel)

    # Toolbar Panel
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = "Top"
    $toolbar.Height = 40
    $rightPanel.Controls.Add($toolbar)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Filter:"
    $lblFilter.Location = New-Object System.Drawing.Point(0, 8)
    $lblFilter.Size = New-Object System.Drawing.Size(45, 20)
    $toolbar.Controls.Add($lblFilter)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(45, 5)
    $txtFilter.Size = New-Object System.Drawing.Size(220, 23)
    $toolbar.Controls.Add($txtFilter)

    $chkLive = New-Object System.Windows.Forms.CheckBox
    $chkLive.Text = "Live Tail"
    $chkLive.Checked = $true
    $chkLive.Location = New-Object System.Drawing.Point(280, 7)
    $chkLive.Size = New-Object System.Drawing.Size(80, 20)
    $toolbar.Controls.Add($chkLive)

    $chkWrap = New-Object System.Windows.Forms.CheckBox
    $chkWrap.Text = "Word Wrap"
    $chkWrap.Checked = $false
    $chkWrap.Location = New-Object System.Drawing.Point(370, 7)
    $chkWrap.Size = New-Object System.Drawing.Size(95, 20)
    $toolbar.Controls.Add($chkWrap)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Clear"
    $btnClear.Location = New-Object System.Drawing.Point(475, 4)
    $btnClear.Size = New-Object System.Drawing.Size(70, 26)
    $btnClear.FlatStyle = "Flat"
    $toolbar.Controls.Add($btnClear)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy Logs"
    $btnCopy.Location = New-Object System.Drawing.Point(555, 4)
    $btnCopy.Size = New-Object System.Drawing.Size(90, 26)
    $btnCopy.FlatStyle = "Flat"
    $toolbar.Controls.Add($btnCopy)

    $btnExplorer = New-Object System.Windows.Forms.Button
    $btnExplorer.Text = "Open in Explorer"
    $btnExplorer.Location = New-Object System.Drawing.Point(655, 4)
    $btnExplorer.Size = New-Object System.Drawing.Size(120, 26)
    $btnExplorer.FlatStyle = "Flat"
    $toolbar.Controls.Add($btnExplorer)

    # Container Panel for custom padding and border around the text box
    $txtContainer = New-Object System.Windows.Forms.Panel
    $txtContainer.Dock = "Fill"
    $txtContainer.BorderStyle = "FixedSingle"
    $txtContainer.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtContainer.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12) # Padding on all sides
    $rightPanel.Controls.Add($txtContainer)
    $txtContainer.BringToFront()

    # Content TextBox (Dark Mode theme)
    $txtContent = New-Object System.Windows.Forms.TextBox
    $txtContent.Multiline = $true
    $txtContent.ReadOnly = $true
    $txtContent.Dock = "Fill"
    $txtContent.ScrollBars = "Both"
    $txtContent.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $txtContent.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtContent.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $txtContent.BorderStyle = "None" # Borderless to prevent vertical clipping of text
    $txtContent.WordWrap = $false
    $txtContainer.Controls.Add($txtContent)

    # â”€â”€ TIMER FOR LIVE TAIL â”€â”€
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000

    # Timer Tick Handler
    $timer.Add_Tick({
            if ([string]::IsNullOrEmpty($script:TailFilePath) -or -not (Test-Path $script:TailFilePath)) { return }
            try {
                $fileInfo = New-Object System.IO.FileInfo($script:TailFilePath)
                $len = $fileInfo.Length

                if ($len -lt $script:TailLastPosition) {
                    # Rotated or cleared file
                    $script:TailLastPosition = 0
                    $script:ActiveLogLines = @()
                    $txtContent.Text = ""
                }

                if ($len -gt $script:TailLastPosition) {
                    $fs = [System.IO.FileStream]::new($script:TailFilePath, 'Open', 'Read', 'ReadWrite')
                    $fs.Seek($script:TailLastPosition, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $reader = [System.IO.StreamReader]::new($fs)
                    $newText = $reader.ReadToEnd()
                    $script:TailLastPosition = $fs.Position
                    $reader.Close()
                    $fs.Close()

                    if (-not [string]::IsNullOrEmpty($newText)) {
                        $newLines = $newText -split "`r?`n" | Where-Object { $_ -ne "" }
                        foreach ($line in $newLines) {
                            $script:ActiveLogLines += $line
                            # Check filter
                            if ([string]::IsNullOrEmpty($script:LogFilterText) -or $line -like "*$script:LogFilterText*") {
                                $txtContent.AppendText($line + "`r`n")
                            }
                        }
                        # Cap in-memory history at 2000 lines
                        if ($script:ActiveLogLines.Count -gt 2000) {
                            $script:ActiveLogLines = $script:ActiveLogLines[-2000..-1]
                        }
                    }
                }
            }
            catch {
                # Temp read error
            }
        })

    # Helper: Refresh file list
    $refreshFiles = {
        $lstFiles.Items.Clear()
        try {
            $files = Get-ChildItem -Path $Server.Path -File | Sort-Object LastWriteTime -Descending
            foreach ($file in $files) {
                $lstFiles.Items.Add($file.Name)
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Error reading log folder: $($_.Exception.Message)", "Error", "OK", "Error")
        }
    }

    # Helper: Read file tail
    $loadFileTail = {
        param([string]$fileName)
        $timer.Stop()
        $txtContent.Text = "Loading $fileName..."
        
        $filePath = Join-Path $Server.Path $fileName
        $script:TailFilePath = $filePath
        $script:ActiveLogLines = @()
        
        try {
            $fs = [System.IO.FileStream]::new($filePath, 'Open', 'Read', 'ReadWrite')
            $script:TailLastPosition = $fs.Length

            # If file is larger than 100KB, read only the end
            if ($fs.Length -gt 100KB) {
                $fs.Seek(-100KB, [System.IO.SeekOrigin]::End) | Out-Null
            }
            
            $reader = [System.IO.StreamReader]::new($fs)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()

            $lines = $content -split "`r?`n"
            # Discard the first line if it's partial due to seeking
            if ($fs.Length -gt 100KB -and $lines.Count -gt 1) {
                $lines = $lines[1..($lines.Count - 1)]
            }
            # Cap at the last 500 lines for initial view
            if ($lines.Count -gt 500) {
                $script:ActiveLogLines = $lines[-500..-1]
            }
            else {
                $script:ActiveLogLines = $lines
            }

            # Apply current filter and show
            $filtered = if ([string]::IsNullOrEmpty($script:LogFilterText)) {
                $script:ActiveLogLines
            }
            else {
                $script:ActiveLogLines | Where-Object { $_ -like "*$script:LogFilterText*" }
            }
            
            $txtContent.Text = ($filtered -join "`r`n") + "`r`n"
            $txtContent.SelectionStart = 0
            $txtContent.ScrollToCaret()

            # Start timer if live tail is active
            if ($chkLive.Checked) {
                $timer.Start()
            }
        }
        catch {
            $txtContent.Text = "Error loading file: $($_.Exception.Message)"
        }
    }

    # â”€â”€ EVENT HANDLERS â”€â”€
    $btnRefreshList.Add_Click($refreshFiles)
    
    $lstFiles.Add_SelectedIndexChanged({
            if ($lstFiles.SelectedItem) {
                $loadFileTail.Invoke($lstFiles.SelectedItem)
            }
        })

    $chkLive.Add_CheckedChanged({
            if ($chkLive.Checked) {
                if ($script:TailFilePath) { $timer.Start() }
            }
            else {
                $timer.Stop()
            }
        })

    $chkWrap.Add_CheckedChanged({
            $txtContent.WordWrap = $chkWrap.Checked
        })

    $btnClear.Add_Click({
            $txtContent.Clear()
            $script:ActiveLogLines = @()
        })

    $btnExplorer.Add_Click({
            explorer.exe $Server.Path
        })

    $btnCopy.Add_Click({
            if (-not [string]::IsNullOrEmpty($txtContent.Text)) {
                [System.Windows.Forms.Clipboard]::SetText($txtContent.Text)
                Update-StatusBar "Copied log content to clipboard" "OK"
            }
        })

    $showSearchPrompt = {
        param([string]$title)
        $promptForm = New-Object System.Windows.Forms.Form
        $promptForm.Text = $title
        $promptForm.Size = New-Object System.Drawing.Size(350, 160)
        $promptForm.StartPosition = "CenterParent"
        $promptForm.FormBorderStyle = "FixedDialog"
        $promptForm.MaximizeBox = $false
        $promptForm.MinimizeBox = $false
        $promptForm.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
        $promptForm.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Enter search keyword:"
        $lbl.Location = New-Object System.Drawing.Point(20, 15)
        $lbl.Size = New-Object System.Drawing.Size(300, 20)
        $promptForm.Controls.Add($lbl)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(20, 40)
        $txt.Size = New-Object System.Drawing.Size(290, 23)
        $promptForm.Controls.Add($txt)

        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "Search"
        $btnOK.Location = New-Object System.Drawing.Point(110, 80)
        $btnOK.Size = New-Object System.Drawing.Size(90, 30)
        $btnOK.DialogResult = "OK"
        $promptForm.AcceptButton = $btnOK
        $promptForm.Controls.Add($btnOK)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"
        $btnCancel.Location = New-Object System.Drawing.Point(210, 80)
        $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
        $btnCancel.DialogResult = "Cancel"
        $promptForm.CancelButton = $btnCancel
        $promptForm.Controls.Add($btnCancel)

        $promptForm.Add_Shown({ $txt.Focus() })

        $res = $promptForm.ShowDialog()
        $val = $txt.Text
        $promptForm.Dispose()
        if ($res -eq "OK") { return $val.Trim() }
        return $null
    }

    $btnSearchAll.Add_Click({
            $query = $showSearchPrompt.Invoke("Search All Log Files")
            if ([string]::IsNullOrWhiteSpace($query)) { return }

            $timer.Stop()
            $txtContent.Text = "Searching all log files for '$query'..."
            $lstFiles.SelectedIndex = -1
        
            try {
                $files = Get-ChildItem -Path $Server.Path -File | Sort-Object LastWriteTime -Descending
                $results = [System.Collections.Generic.List[string]]::new()
                $results.Add("=== MULTI-FILE SEARCH RESULTS FOR: '$query' ===")
                $results.Add("Search performed on: $(Get-Date)")
                $results.Add("")

                $totalMatches = 0
                foreach ($file in $files) {
                    if ($file.Length -gt 20MB) { continue }
                
                    try {
                        $fs = [System.IO.FileStream]::new($file.FullName, 'Open', 'Read', 'ReadWrite')
                        $reader = [System.IO.StreamReader]::new($fs)
                    
                        $lineNum = 0
                        $fileMatches = 0
                        $fileLines = [System.Collections.Generic.List[string]]::new()

                        while (($line = $reader.ReadLine()) -ne $null) {
                            $lineNum++
                            if ($line -like "*$query*") {
                                $fileMatches++
                                $totalMatches++
                                $fileLines.Add("  [Line $lineNum] $line")
                            }
                        }
                    
                        $reader.Close()
                        $fs.Close()

                        if ($fileMatches -gt 0) {
                            $results.Add("Found in: $($file.Name) ($fileMatches matches)")
                            $results.AddRange($fileLines)
                            $results.Add("")
                        }
                    }
                    catch {
                        # Skip locked files
                    }
                }

                $results.Add("==================================================")
                $results.Add("Total Matches Found: $totalMatches")
                $results.Add("==================================================")

                $txtContent.Text = $results -join "`r`n"
                $txtContent.SelectionStart = 0
                $txtContent.ScrollToCaret()
            }
            catch {
                $txtContent.Text = "Search failed: $($_.Exception.Message)"
            }
        })

    $txtFilter.Add_TextChanged({
            $script:LogFilterText = $txtFilter.Text
            # Re-apply filter on existing lines
            if ($script:TailFilePath) {
                $filtered = if ([string]::IsNullOrEmpty($script:LogFilterText)) {
                    $script:ActiveLogLines
                }
                else {
                    $script:ActiveLogLines | Where-Object { $_ -like "*$script:LogFilterText*" }
                }
                $txtContent.Text = ($filtered -join "`r`n") + "`r`n"
                $txtContent.SelectionStart = 0
                $txtContent.ScrollToCaret()
            }
        })

    # Cleanup timer on close
    $dlg.Add_FormClosing({
            $timer.Stop()
            $timer.Dispose()
        })

    # Initial load
    $refreshFiles.Invoke()
    
    # Auto-select the first log file if any exist
    if ($lstFiles.Items.Count -gt 0) {
        $lstFiles.SelectedIndex = 0
    }

    # Show form
    $dlg.ShowDialog()
    $dlg.Dispose()
}

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

function Refresh-ServerList {
    param([string]$Filter = "")
    $script:Servers = Load-Servers
    $script:lstServers.Items.Clear()
    foreach ($srv in $script:Servers) {
        if ($srv.Environment -eq $script:ActiveEnv) {
            if ([string]::IsNullOrWhiteSpace($Filter) -or
                $srv.Name -like "*$Filter*") {
                $script:lstServers.Items.Add($srv.Name)
                $script:ServerStatus[$srv.Name] = "Checking"
                Start-PingCheck -ServerName $srv.Name -Address $srv.SharePath
            }
        }
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
    return $script:Servers | Where-Object { $_.Name -eq $selected -and $_.Environment -eq $script:ActiveEnv }
}

# SERVER MANAGEMENT DIALOGS

function Show-ServerDialog {
    param(
        [string]$Title = "Add Server",
        [string]$ServerName = "",
        [string]$SharePath = "",
        [string]$Environment = ""
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(480, 320)
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

    # Share Path
    $lblShare = New-Object System.Windows.Forms.Label
    $lblShare.Text = "Share Path:"
    $lblShare.Location = New-Object System.Drawing.Point(20, 60)
    $lblShare.Size = New-Object System.Drawing.Size(100, 23)
    $dlg.Controls.Add($lblShare)

    $txtShare = New-Object System.Windows.Forms.TextBox
    $txtShare.Text = $SharePath
    $txtShare.Location = New-Object System.Drawing.Point(130, 58)
    $txtShare.Size = New-Object System.Drawing.Size(310, 23)
    $dlg.Controls.Add($txtShare)

    # Environment
    $lblEnv = New-Object System.Windows.Forms.Label
    $lblEnv.Text = "Environment:"
    $lblEnv.Location = New-Object System.Drawing.Point(20, 100)
    $lblEnv.Size = New-Object System.Drawing.Size(100, 23)
    $dlg.Controls.Add($lblEnv)

    $cmbDialogEnv = New-Object System.Windows.Forms.ComboBox
    $cmbDialogEnv.DropDownStyle = "DropDownList"
    $cmbDialogEnv.Items.Add("DEV") | Out-Null
    $cmbDialogEnv.Items.Add("PROD") | Out-Null
    $cmbDialogEnv.Location = New-Object System.Drawing.Point(130, 98)
    $cmbDialogEnv.Size = New-Object System.Drawing.Size(310, 23)
    if ([string]::IsNullOrWhiteSpace($Environment)) {
        $cmbDialogEnv.SelectedItem = $script:ActiveEnv
    }
    else {
        $cmbDialogEnv.SelectedItem = $Environment
    }
    $dlg.Controls.Add($cmbDialogEnv)

    # Hint
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Use UNC paths, e.g. \\SERVER\D$"
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Location = New-Object System.Drawing.Point(130, 135)
    $lblHint.Size = New-Object System.Drawing.Size(310, 20)
    $dlg.Controls.Add($lblHint)

    # Buttons
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Save"
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.Location = New-Object System.Drawing.Point(240, 190)
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = "Flat"
    $btnOK.DialogResult = "OK"
    $dlg.AcceptButton = $btnOK
    $dlg.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Location = New-Object System.Drawing.Point(340, 190)
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
        })

    $result = $dlg.ShowDialog()
    $dlg.Dispose()

    if ($result -eq "OK") {
        return @{
            Name        = $txtName.Text.Trim()
            SharePath   = $txtShare.Text.Trim()
            Environment = $cmbDialogEnv.SelectedItem
        }
    }
    return $null
}

# MAIN FORM

# Prompt for credentials first
$script:Credentials[$script:ActiveEnv] = Get-SessionCredential -Environment $script:ActiveEnv -ExitOnCancel $true

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
                $cred = Get-SessionCredential -Environment $newEnv -ExitOnCancel $false
                if ($null -eq $cred) {
                    # Revert selection
                    $script:InEnvSwitch = $true
                    $cmbEnv.SelectedItem = $script:ActiveEnv
                    $script:InEnvSwitch = $false
                    return
                }
                $script:Credentials[$newEnv] = $cred
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
    
        $itemText = $sender.Items[$e.Index]
        $status = $script:ServerStatus[$itemText]
    
        $color = switch ($status) {
            "Online" { [System.Drawing.Color]::FromArgb(46, 125, 50) }   # Green
            "Offline" { [System.Drawing.Color]::FromArgb(198, 40, 40) }  # Red
            default { [System.Drawing.Color]::FromArgb(120, 120, 120) } # Gray (checking)
        }
    
        $brush = New-Object System.Drawing.SolidBrush($color)
        $textBrush = New-Object System.Drawing.SolidBrush($e.ForeColor)
    
        # Draw status circle (X offset = 6, diameter = 8, Y centered)
        $circleY = $e.Bounds.Y + [int](($e.Bounds.Height - 8) / 2)
        $e.Graphics.FillEllipse($brush, $e.Bounds.X + 6, $circleY, 8, 8)
    
        # Draw text (X offset = 22)
        $font = $e.Font
        if ($null -eq $font) { $font = $sender.Font }
        $e.Graphics.DrawString($itemText, $font, $textBrush, $e.Bounds.X + 22, $e.Bounds.Y + 2)
    
        $brush.Dispose()
        $textBrush.Dispose()
        $e.DrawFocusRectangle()
    })

$script:lstServers.Add_SelectedIndexChanged({
        if ($script:lstServers.SelectedItem) {
            $userStr = if ($script:Credentials[$script:ActiveEnv]) { $script:Credentials[$script:ActiveEnv].UserName } else { "None" }
            Update-StatusBar "Selected: $($script:lstServers.SelectedItem) | User: $userStr" "Info"
            Refresh-BookmarkList
        }
    })
$script:lstServers.Add_DoubleClick({
        # Double-click opens the server share
        $server = Get-SelectedServer
        if ($server) {
            Open-ServerPath -UncPath $server.SharePath -Credential $script:Credentials[$script:ActiveEnv] -ActionLabel "Share"
        }
    })
$form.Controls.Add($script:lstServers)

# â”€â”€ Action Buttons â”€â”€
$buttonY = 340
$buttonW = 145
$buttonH = 34
$buttonGap = 10
$col1 = 20
$col2 = 175
$col3 = 330

# Row 1 - Primary Actions
$btnOpenShare = New-Object System.Windows.Forms.Button
$btnOpenShare.Text = "Open Share"
$btnOpenShare.Size = New-Object System.Drawing.Size(145, 34)
$btnOpenShare.Location = New-Object System.Drawing.Point(20, 340)
$btnOpenShare.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
$btnOpenShare.ForeColor = [System.Drawing.Color]::White
$btnOpenShare.FlatStyle = "Flat"
$btnOpenShare.Cursor = "Hand"
$btnOpenShare.Add_Click({
        $server = Get-SelectedServer
        if ($server) {
            Open-ServerPath -UncPath $server.SharePath -Credential $script:Credentials[$script:ActiveEnv] -ActionLabel "Share"
        }
    })
$form.Controls.Add($btnOpenShare)

$btnRDP = New-Object System.Windows.Forms.Button
$btnRDP.Text = "RDP Connect"
$btnRDP.Size = New-Object System.Drawing.Size(145, 34)
$btnRDP.Location = New-Object System.Drawing.Point(175, 340)
$btnRDP.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
$btnRDP.ForeColor = [System.Drawing.Color]::White
$btnRDP.FlatStyle = "Flat"
$btnRDP.Cursor = "Hand"
$btnRDP.Add_Click({
        $server = Get-SelectedServer
        if ($server) {
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
                            $cleanupTimer.Stop()
                            $cleanupTimer.Dispose()
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
$btnRefresh.Location = New-Object System.Drawing.Point(330, 340)
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
        $result = Show-ServerDialog -Title "Add Server"
        if ($result) {
            $servers = [System.Collections.ArrayList]@(Load-Servers)
            $existing = $servers | Where-Object { $_.Name -eq $result.Name -and $_.Environment -eq $result.Environment }
            if ($existing) {
                [System.Windows.Forms.MessageBox]::Show(
                    "A server named '$($result.Name)' already exists.",
                    "Duplicate", "OK", "Warning")
                return
            }
            $newServer = [PSCustomObject]@{
                Name        = $result.Name
                SharePath   = $result.SharePath
                Environment = $result.Environment
                Bookmarks   = @()
            }
            $servers.Add($newServer) | Out-Null
            Save-Servers $servers.ToArray()
            Refresh-ServerList -Filter $txtSearch.Text
            Update-StatusBar "Server '$($result.Name)' added" "OK"
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
            $result = Show-ServerDialog -Title "Edit Server" `
                -ServerName $server.Name `
                -SharePath $server.SharePath `
                -Environment $server.Environment
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
        $server = Get-SelectedServer
        if ($bkm -and $server) {
            $fakeServer = [PSCustomObject]@{
                Name = "$($server.Name) - $($bkm.Name)"
                Path = $bkm.Path
            }
            Show-LogViewer -Server $fakeServer -Credential $script:Credentials[$script:ActiveEnv]
        }
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
            Open-ServerPath -UncPath $bkm.Path -Credential $script:Credentials[$script:ActiveEnv] -ActionLabel "Bookmark"
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Please select a bookmark.", "No Selection", "OK", "Information")
        }
    })
$pnlBookmarks.Controls.Add($btnOpenBkmExplorer)

$btnAddBkm = New-Object System.Windows.Forms.Button
$btnAddBkm.Text = "Add Bookmark"
$btnAddBkm.Location = New-Object System.Drawing.Point(15, 280)
$btnAddBkm.Size = New-Object System.Drawing.Size(240, 32)
$btnAddBkm.FlatStyle = "Flat"
$btnAddBkm.Cursor = "Hand"
$btnAddBkm.Add_Click({
        $server = Get-SelectedServer
        if ($null -eq $server) {
            [System.Windows.Forms.MessageBox]::Show("Please select a server first.", "No Selection", "OK", "Warning")
            return
        }

        Update-StatusBar "Connecting to $($server.SharePath)..." "Info"
        $connection = Connect-ServerPath -UncPath $server.SharePath -Credential $script:Credentials[$script:ActiveEnv]
        if (-not $connection.Success) {
            [System.Windows.Forms.MessageBox]::Show("Connection failed: $($connection.Message)", "Connection Error", "OK", "Error")
            return
        }

        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $browser.Description = "Select a folder to bookmark on $($server.Name)"
        $browser.SelectedPath = $server.SharePath
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

                $bkm = [PSCustomObject]@{
                    Name = $bookmarkName
                    Path = $path
                }
            
                $bList = [System.Collections.ArrayList]@($server.Bookmarks)
                $bList.Add($bkm) | Out-Null
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

# â”€â”€ Load and Show â”€â”€
Refresh-ServerList
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
$form.Dispose()


