function Test-IsTextFile {
    param(
        [System.IO.FileInfo]$FileInfo
    )
    
    # Get configured text extensions
    $textExts = @('.log')
    if ($null -ne $script:SavedUsers -and $script:SavedUsers.ContainsKey("LogExtensions")) {
        $val = $script:SavedUsers["LogExtensions"]
        $rawExts = @()
        if ($val -is [System.Array]) {
            $rawExts = @($val | ForEach-Object { $_.ToString().ToLower().Trim() })
        } elseif ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) {
            $rawExts = @($val.ToLower() -split ',' | ForEach-Object { $_.Trim() })
        }
        
        $textExts = @()
        foreach ($raw in $rawExts) {
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                if (-not $raw.StartsWith(".")) { $raw = "." + $raw }
                $textExts += $raw
            }
        }
    }
    
    # 1. Quick extension check using whitelist match (including rotated logs like .log.1)
    $matchedWhitelist = $false
    foreach ($pat in $textExts) {
        if ($FileInfo.Name -like "*$pat" -or $FileInfo.Name -like "*$pat.*") {
            $matchedWhitelist = $true
            break
        }
    }
    if (-not $matchedWhitelist) { return $false }
    
    # 2. Blacklist check to reject binary extensions matching the whitelist pattern (e.g. app.log.zip)
    $ext = $FileInfo.Extension.ToLower()
    $binaryExts = @('.exe', '.dll', '.zip', '.tar', '.gz', '.tgz', '.7z', '.rar', '.bin', '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.mp3', '.mp4', '.avi', '.mov', '.xlsx', '.xls', '.docx', '.doc', '.pptx', '.ppt', '.msi', '.cab', '.sys', '.jar', '.war', '.class', '.db', '.sqlite', '.pdb')
    if ($binaryExts -contains $ext) { return $false }
    
    # 3. Content check: check first 512 bytes for null bytes
    if ($FileInfo.Length -eq 0) { return $true } # Empty file is fine
    
    try {
        $bytesToRead = [System.Math]::Min(512, $FileInfo.Length)
        $buffer = New-Object byte[] $bytesToRead
        $stream = [System.IO.FileStream]::new($FileInfo.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytesRead = $stream.Read($buffer, 0, $bytesToRead)
        $stream.Close()
        
        # If there's a null byte in the read buffer, it's likely a binary file
        for ($i = 0; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) {
                return $false
            }
        }
        return $true
    }
    catch {
        # If we can't open/read the file (maybe locked), default to true for logs
        return $true
    }
}

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
    $script:ViewerCurrentPath = $Server.Path

    # Form setup
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Log Viewer - $($Server.Name) ($($Server.Path))"
    $dlg.Size = New-Object System.Drawing.Size(1000, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 250)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    
    # Enable resizing but keep a minimum size
    $dlg.MinimumSize = New-Object System.Drawing.Size(800, 500)

    # ── SPLIT CONTAINER ──
    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Size = New-Object System.Drawing.Size(980, 600)
    $splitContainer.Dock = "Fill"
    $splitContainer.Panel1MinSize = 150
    $splitContainer.Panel2MinSize = 400
    $splitContainer.SplitterDistance = 240
    $dlg.Controls.Add($splitContainer)

    # ── LEFT PANEL (FILE LIST) ──
    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = "Fill"
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $splitContainer.Panel1.Controls.Add($leftPanel)

    $lblFiles = New-Object System.Windows.Forms.Label
    $lblFiles.Text = "Log Folder Tree:"
    $lblFiles.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $lblFiles.Dock = "Top"
    $lblFiles.Height = 25
    $leftPanel.Controls.Add($lblFiles)

    $treeFiles = New-Object System.Windows.Forms.TreeView
    $treeFiles.Dock = "Fill"
    $treeFiles.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $treeFiles.BorderStyle = "FixedSingle"
    $leftPanel.Controls.Add($treeFiles)
    $treeFiles.SendToBack()

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

    # ── RIGHT PANEL (CONTENT VIEWER) ──
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

    # ── TIMER FOR LIVE TAIL ──
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

    # Helper: Load subnodes dynamically for a folder node
    $loadSubNodes = {
        param([System.Windows.Forms.TreeNode]$parentNode)
        $parentNode.Nodes.Clear()
        $dirPath = $parentNode.Tag
        
        try {
            # 1. Add directories
            $subDirs = Get-ChildItem -Path $dirPath -Directory | Sort-Object Name
            foreach ($dir in $subDirs) {
                $node = New-Object System.Windows.Forms.TreeNode
                $node.Text = "[Dir] $($dir.Name)"
                $node.Tag = $dir.FullName
                # Add dummy node to make it expandable
                $dummyNode = New-Object System.Windows.Forms.TreeNode
                $dummyNode.Text = "..."
                $node.Nodes.Add($dummyNode) | Out-Null
                $parentNode.Nodes.Add($node) | Out-Null
            }
            
            # 2. Add whitelisted files
            $files = Get-ChildItem -Path $dirPath -File | Where-Object { Test-IsTextFile $_ } | Sort-Object LastWriteTime -Descending
            foreach ($file in $files) {
                $node = New-Object System.Windows.Forms.TreeNode
                $node.Text = "[File] $($file.Name)"
                $node.Tag = $file.FullName
                $parentNode.Nodes.Add($node) | Out-Null
            }
        }
        catch {
            $errorNode = New-Object System.Windows.Forms.TreeNode
            $errorNode.Text = "[Error reading folder]"
            $parentNode.Nodes.Add($errorNode) | Out-Null
        }
    }

    # Helper: Populates/refreshes the root tree view
    $populateTree = {
        $treeFiles.Nodes.Clear()
        try {
            $rootNode = New-Object System.Windows.Forms.TreeNode
            $rootNode.Text = "[Dir] $($Server.Name)"
            $rootNode.Tag = $Server.Path
            $treeFiles.Nodes.Add($rootNode) | Out-Null
            
            # Populate root level folders and files
            $loadSubNodes.Invoke($rootNode)
            $rootNode.Expand()
            
            # Auto-select the first log file at root level if any exists
            $foundFirst = $false
            foreach ($node in $rootNode.Nodes) {
                if ($node.Text.StartsWith("[File] ")) {
                    $treeFiles.SelectedNode = $node
                    $foundFirst = $true
                    break
                }
            }
            if (-not $foundFirst) {
                $treeFiles.SelectedNode = $null
                $txtContent.Text = ""
                $script:TailFilePath = $null
                $script:ActiveLogLines = @()
                $timer.Stop()
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Error reading log folder: $($_.Exception.Message)", "Error", "OK", "Error")
        }
    }

    # Helper: Read file tail
    $loadFileTail = {
        param([string]$filePath)
        $timer.Stop()
        
        $fileName = Split-Path -Leaf $filePath
        $txtContent.Text = "Loading $fileName..."
        
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

    # Helper: Resolve the active folder path based on current TreeView selection
    $getActiveSearchPath = {
        $selectedNode = $treeFiles.SelectedNode
        if ($null -ne $selectedNode -and $null -ne $selectedNode.Tag) {
            $path = $selectedNode.Tag
            if (Test-Path $path -PathType Container) {
                return $path
            } else {
                return Split-Path -Parent $path
            }
        }
        return $Server.Path
    }

    # ── EVENT HANDLERS ──
    $btnRefreshList.Add_Click($populateTree)
    
    # Expand node dynamically when expanded in TreeView
    $treeFiles.Add_BeforeExpand({
            param($sender, $e)
            $node = $e.Node
            if ($node.Nodes.Count -eq 1 -and $node.Nodes[0].Text -eq "...") {
                $loadSubNodes.Invoke($node)
            }
        })

    # Select node inside TreeView
    $treeFiles.Add_AfterSelect({
            param($sender, $e)
            $node = $e.Node
            $path = $node.Tag
            if ($null -ne $path -and (Test-Path $path -PathType Leaf)) {
                $loadFileTail.Invoke($path)
            } else {
                # If directory/root selected, clear search/tail selection
                $timer.Stop()
                $txtContent.Text = ""
                $script:TailFilePath = $null
                $script:ActiveLogLines = @()
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
            $searchPath = $getActiveSearchPath.Invoke()
            explorer.exe $searchPath
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
            $treeFiles.SelectedNode = $null
        
            try {
                $searchPath = $getActiveSearchPath.Invoke()
                $files = Get-ChildItem -Path $searchPath -File | Where-Object { Test-IsTextFile $_ } | Sort-Object LastWriteTime -Descending
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
    $populateTree.Invoke()

    # Show form
    $dlg.ShowDialog()
    $dlg.Dispose()
}
