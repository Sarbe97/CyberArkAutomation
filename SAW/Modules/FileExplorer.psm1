#========================================================================
# FileExplorer.psm1 - UNC File System Browser
# All UNC access is credential-based via temporary PSDrive (no persistent mapping)
# Includes: Get-UNCDirectoryListing, Get-UNCFileContent, Show-PathBrowserDialog
#========================================================================

$script:ViewableExtensions = @('.log','.txt','.csv','.config','.ini','.json','.xml',
                                '.ps1','.psm1','.psd1','.bat','.cmd','.evtx')
$script:QuickPathsFile     = $null

# ---------- Quick Path persistence ------------------------------------------

function Initialize-FileExplorer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDirectory)

    $script:QuickPathsFile = Join-Path $ConfigDirectory 'QuickPaths.json'

    if (-not (Test-Path $script:QuickPathsFile)) {
        _CreateDefaultQuickPaths
    }
}

function _CreateDefaultQuickPaths {
    $defaults = [ordered]@{
        PVWA = @(
            [ordered]@{ Name = 'PVWA Logs';        RelativePath = 'CyberArk\Password Vault Web Access\Logs' }
            [ordered]@{ Name = 'IIS Logs';         RelativePath = 'inetpub\logs\LogFiles' }
            [ordered]@{ Name = 'Configuration';    RelativePath = 'CyberArk\Password Vault Web Access\Configuration' }
            [ordered]@{ Name = 'Installation';     RelativePath = 'CyberArk\Password Vault Web Access' }
        )
        CPM  = @(
            [ordered]@{ Name = 'CPM Logs';         RelativePath = 'CyberArk\Password Manager\Logs' }
            [ordered]@{ Name = 'CPM Configuration'; RelativePath = 'CyberArk\Password Manager' }
        )
        PSM  = @(
            [ordered]@{ Name = 'PSM Logs';         RelativePath = 'CyberArk\PSM\Logs' }
            [ordered]@{ Name = 'PSM Recordings';   RelativePath = 'CyberArk\PSM\Recordings' }
            [ordered]@{ Name = 'PSM Configuration'; RelativePath = 'CyberArk\PSM' }
        )
        PTA  = @(
            [ordered]@{ Name = 'PTA Logs';         RelativePath = 'opt\tomcat\logs' }
            [ordered]@{ Name = 'PTA Configuration'; RelativePath = 'opt\tomcat\conf' }
        )
        IIS  = @(
            [ordered]@{ Name = 'IIS Logs';         RelativePath = 'inetpub\logs\LogFiles' }
            [ordered]@{ Name = 'Web Root';         RelativePath = 'inetpub\wwwroot' }
        )
        SQL  = @(
            [ordered]@{ Name = 'SQL Logs';         RelativePath = 'Program Files\Microsoft SQL Server' }
        )
        UserDefined = @()
    }
    $defaults | ConvertTo-Json -Depth 5 | Set-Content -Path $script:QuickPathsFile -Encoding UTF8
}

function Get-QuickPaths {
    [CmdletBinding()]
    param([string]$Category)

    try {
        $data = Get-Content $script:QuickPathsFile -Raw | ConvertFrom-Json

        if ($Category -and (Get-Member -InputObject $data -Name $Category -MemberType NoteProperty)) {
            $paths = @($data.$Category)
            # Also include UserDefined paths for this category
            if (Get-Member -InputObject $data -Name 'UserDefined' -MemberType NoteProperty) {
                $userPaths = @($data.UserDefined) | Where-Object { $_.Category -eq $Category -or -not $_.Category }
                $paths += $userPaths
            }
            return $paths
        }
        elseif (-not $Category) {
            return $data
        }
        return @()
    }
    catch {
        Write-NexusLog "Failed to load QuickPaths.json: $($_.Exception.Message)" -Level WARN -Component 'FileExplorer'
        return @()
    }
}

function Save-UserDefinedPath {
    <#
    .SYNOPSIS  Saves a browsed UNC path as a named user-defined quick path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FullPath,
        [string]$Category   = '',
        [string]$ServerName = ''
    )

    try {
        $data = Get-Content $script:QuickPathsFile -Raw | ConvertFrom-Json

        # Ensure UserDefined exists
        if (-not (Get-Member -InputObject $data -Name 'UserDefined' -MemberType NoteProperty)) {
            $data | Add-Member -MemberType NoteProperty -Name 'UserDefined' -Value @()
        }

        $existing = @($data.UserDefined) | Where-Object { $_.FullPath -eq $FullPath }
        if ($existing) {
            Write-NexusLog "Quick path already exists for: $FullPath" -Level WARN -Component 'FileExplorer'
            return $false
        }

        $newEntry = [PSCustomObject]@{
            Name       = $Name
            FullPath   = $FullPath
            Category   = $Category
            ServerName = $ServerName
            Added      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $data.UserDefined = @($data.UserDefined) + @($newEntry)
        $data | ConvertTo-Json -Depth 5 | Set-Content -Path $script:QuickPathsFile -Encoding UTF8

        Write-NexusLog "User path saved: '$Name' --- $FullPath" -Level INFO -Component 'FileExplorer'
        return $true
    }
    catch {
        Write-NexusLog "Failed to save user path: $($_.Exception.Message)" -Level ERROR -Component 'FileExplorer'
        return $false
    }
}

function Remove-UserDefinedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FullPath)

    try {
        $data = Get-Content $script:QuickPathsFile -Raw | ConvertFrom-Json
        if (Get-Member -InputObject $data -Name 'UserDefined' -MemberType NoteProperty) {
            $data.UserDefined = @($data.UserDefined) | Where-Object { $_.FullPath -ne $FullPath }
            $data | ConvertTo-Json -Depth 5 | Set-Content -Path $script:QuickPathsFile -Encoding UTF8
        }
    }
    catch {
        Write-NexusLog "Failed to remove user path: $($_.Exception.Message)" -Level ERROR -Component 'FileExplorer'
    }
}

# ---------- UNC Access helpers ----------------------------------------------

function _FormatFileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function _ParseUNCParts {
    <# Returns @{ Share='\\server\share'; RelPath='some\path' } #>
    param([string]$UNCPath)

    $clean = $UNCPath.TrimStart('\')
    $parts = $clean -split '\\'
    if ($parts.Count -lt 2) { throw "Invalid UNC path: $UNCPath" }

    $share   = '\\' + $parts[0] + '\' + $parts[1]
    $relPath = if ($parts.Count -gt 2) { ($parts[2..($parts.Count - 1)]) -join '\' } else { '' }

    return @{ Share = $share; RelPath = $relPath }
}

function _MountTempDrive {
    param(
        [string]$UNCShare,
        [System.Management.Automation.PSCredential]$Credential
    )
    $name = "SAW$(Get-Random -Maximum 999999)"
    $null = New-PSDrive -Name $name -PSProvider FileSystem `
                        -Root $UNCShare -Credential $Credential -ErrorAction Stop
    return $name
}

function _DismountDrive {
    param([string]$DriveName)
    if ($DriveName -and (Get-PSDrive -Name $DriveName -ErrorAction SilentlyContinue)) {
        Remove-PSDrive -Name $DriveName -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Public functions ------------------------------------------------

function Get-UNCDirectoryListing {
    <#
    .SYNOPSIS  Lists files and folders in a UNC path using supplied credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UNCPath,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [switch]$FilesOnly,
        [switch]$DirsOnly
    )

    $parsed    = _ParseUNCParts -UNCPath $UNCPath
    $driveName = $null
    $results   = [System.Collections.ArrayList]::new()

    try {
        $driveName = _MountTempDrive -UNCShare $parsed.Share -Credential $Credential
        $localRoot = "${driveName}:\"
        $localPath = if ($parsed.RelPath) { Join-Path $localRoot $parsed.RelPath } else { $localRoot }

        if (-not (Test-Path $localPath)) {
            throw "Path not found: $UNCPath"
        }

        $items = Get-ChildItem -Path $localPath -ErrorAction Stop

        foreach ($item in $items) {
            if ($FilesOnly -and $item.PSIsContainer) { continue }
            if ($DirsOnly  -and -not $item.PSIsContainer) { continue }

            $ext = if (-not $item.PSIsContainer) { $item.Extension.ToLower() } else { '' }

            $null = $results.Add([PSCustomObject]@{
                Name         = $item.Name
                FullUNCPath  = Join-Path $UNCPath $item.Name
                Size         = if (-not $item.PSIsContainer) { _FormatFileSize $item.Length } else { '' }
                SizeBytes    = if (-not $item.PSIsContainer) { $item.Length } else { 0 }
                LastModified = $item.LastWriteTime
                IsDirectory  = $item.PSIsContainer
                Extension    = $ext
                IsViewable   = (-not $item.PSIsContainer) -and ($ext -in $script:ViewableExtensions)
            })
        }

        Write-NexusLog "Listed $($results.Count) items at: $UNCPath" -Level DEBUG -Component 'FileExplorer'
    }
    catch {
        Write-NexusLog "Directory listing failed [$UNCPath]: $($_.Exception.Message)" -Level WARN -Component 'FileExplorer'
        throw
    }
    finally {
        _DismountDrive $driveName
    }

    # Directories first, then files, both sorted by name
    return @($results | Sort-Object @{E='IsDirectory';Desc=$true}, 'Name')
}

function Get-UNCFileContent {
    <#
    .SYNOPSIS  Reads a remote log file via UNC with credentials.
    .NOTES     Files over 10 MB are paginated (MaxLines applies).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UNCFilePath,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [int]$MaxLines  = 5000,
        [int]$StartLine = 1,
        [string]$HighlightText = ''
    )

    $parsed    = _ParseUNCParts -UNCFilePath $UNCFilePath
    $driveName = $null

    # Re-parse for file: \\server\share\path\file
    $clean  = $UNCFilePath.TrimStart('\')
    $parts  = $clean -split '\\'
    if ($parts.Count -lt 3) { throw "Expected a file path, got: $UNCFilePath" }

    $share    = '\\' + $parts[0] + '\' + $parts[1]
    $relPath  = ($parts[2..($parts.Count - 1)]) -join '\'

    try {
        $driveName = _MountTempDrive -UNCShare $share -Credential $Credential
        $localPath = "${driveName}:\$relPath"

        if (-not (Test-Path $localPath -PathType Leaf)) {
            throw "File not found: $UNCFilePath"
        }

        $fileInfo   = Get-Item $localPath
        $allContent = Get-Content $localPath -ErrorAction Stop
        $allLines   = @($allContent)
        $totalLines = $allLines.Count

        $sliced = $allLines | Select-Object -Skip ($StartLine - 1) -First $MaxLines

        $numbered = for ($i = 0; $i -lt @($sliced).Count; $i++) {
            $lineNum = $StartLine + $i
            $text    = $sliced[$i]
            $isMatch = $HighlightText -and $text -match [regex]::Escape($HighlightText)
            [PSCustomObject]@{
                LineNumber = $lineNum
                Text       = $text
                IsMatch    = $isMatch
            }
        }

        return [PSCustomObject]@{
            Lines         = @($numbered)
            TotalLines    = $totalLines
            StartLine     = $StartLine
            EndLine       = [Math]::Min($StartLine + $MaxLines - 1, $totalLines)
            IsTruncated   = $totalLines -gt ($StartLine + $MaxLines - 1)
            IsLarge       = $fileInfo.Length -gt 10MB
            FileSizeBytes = $fileInfo.Length
            FileSize      = _FormatFileSize $fileInfo.Length
            FileName      = $fileInfo.Name
            LastModified  = $fileInfo.LastWriteTime
            FilePath      = $UNCFilePath
        }
    }
    catch {
        Write-NexusLog "File read failed [$UNCFilePath]: $($_.Exception.Message)" -Level ERROR -Component 'FileExplorer'
        throw
    }
    finally {
        _DismountDrive $driveName
    }
}

# ---------- Path Browser Dialog ---------------------------------------------

function Show-PathBrowserDialog {
    <#
    .SYNOPSIS  Interactive UNC path browser with Save as Quick Path support.
    .OUTPUTS   [PSCustomObject] @{ SelectedPath; SavedName; Saved } or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [string]$InitialPath    = '',
        [string]$InitialShare   = '',
        [string]$ServerName     = '',
        [string]$Category       = ''
    )

    $xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Browse Network Path"
    Height="600" Width="720"
    WindowStartupLocation="CenterOwner"
    Background="#0D1117"
    FontFamily="Segoe UI">

    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#E2E8F0"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,6"/>
            <Setter Property="FontFamily"      Value="Consolas"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="CaretBrush"      Value="#E2E8F0"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background"      Value="#21262D"/>
            <Setter Property="Foreground"      Value="#E2E8F0"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="10,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="4" Padding="10,6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#30363D"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AccentBtn" TargetType="Button">
            <Setter Property="Background"      Value="#238636"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="12,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="12,6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#2EA043"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#196C2E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground"        Value="#E2E8F0"/>
            <Setter Property="Background"        Value="Transparent"/>
            <Setter Property="BorderThickness"   Value="0"/>
            <Setter Property="Padding"           Value="8,5"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver"  Value="True">
                    <Setter Property="Background" Value="#21262D"/>
                </Trigger>
                <Trigger Property="IsSelected"   Value="True">
                    <Setter Property="Background" Value="#1F6FEB20"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#161B22" Padding="16,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="[Dir]" FontSize="16" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <StackPanel>
                        <TextBlock Text="Browse Network Path" FontSize="14" FontWeight="SemiBold" Foreground="#E2E8F0"/>
                        <TextBlock x:Name="lblHeaderSub" Text="Navigate to a folder or file on a remote server"
                                   FontSize="11" Foreground="#6E7681"/>
                    </StackPanel>
                </StackPanel>
                <TextBlock x:Name="lblNavHistory" Grid.Column="1" Foreground="#6E7681" FontSize="11"
                           VerticalAlignment="Center" FontFamily="Consolas"/>
            </Grid>
        </Border>

        <!-- Address / Navigation bar -->
        <Border Grid.Row="1" Background="#0D1117" Padding="12,8" BorderBrush="#30363D"
                BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnBack" Grid.Column="0" Content="Back" Width="36" Margin="0,0,4,0"/>
                <Button x:Name="btnUp"   Grid.Column="1" Content="^ Up" Width="50" Margin="0,0,8,0"/>
                <TextBox x:Name="txtPath" Grid.Column="2"/>
                <Button x:Name="btnRefresh" Grid.Column="3" Content="[Refresh]" Width="32" Margin="8,0,0,0" ToolTip="Refresh"/>
                <Button x:Name="btnGo" Grid.Column="5" Content="Go" Style="{StaticResource AccentBtn}" Width="50"/>
            </Grid>
        </Border>

        <!-- File / folder list -->
        <Border Grid.Row="2" Margin="12,8,12,4" BorderBrush="#30363D" BorderThickness="1" CornerRadius="4">
            <Grid>
                <ListBox x:Name="lstItems" Background="#0D1117" BorderThickness="0"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                         VirtualizingPanel.IsVirtualizing="True">
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <Grid Margin="0,2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="28"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="90"/>
                                    <ColumnDefinition Width="130"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="{Binding Icon}" FontSize="14" VerticalAlignment="Center"/>
                                <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="#E2E8F0"
                                           VerticalAlignment="Center" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Grid.Column="2" Text="{Binding Size}" Foreground="#6E7681"
                                           VerticalAlignment="Center" FontSize="11" TextAlignment="Right" Margin="0,0,8,0"/>
                                <TextBlock Grid.Column="3" Text="{Binding Modified}" Foreground="#6E7681"
                                           VerticalAlignment="Center" FontSize="11"/>
                            </Grid>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                </ListBox>

                <Border x:Name="pnlStatus" Background="#0D1117" Visibility="Visible">
                    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                        <TextBlock x:Name="lblStatus" Text="Enter a UNC path above and click Go"
                                   Foreground="#6E7681" FontSize="13" HorizontalAlignment="Center"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <!-- Save as Quick Path -->
        <Border Grid.Row="3" Background="#161B22" Padding="12,10" Margin="12,0,12,4"
                BorderBrush="#30363D" BorderThickness="1" CornerRadius="4">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="[*] Save as Quick Path:" Foreground="#F0883E"
                           FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBox x:Name="txtSaveName" Grid.Column="1" Margin="0,0,8,0"/>
                <Button x:Name="btnSavePath" Grid.Column="2" Content="[Save] Save Path"
                        Style="{StaticResource AccentBtn}"/>
            </Grid>
        </Border>

        <!-- Action bar -->
        <Grid Grid.Row="4" Margin="12,0,12,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="lblCurrentPath" Grid.Column="0" Foreground="#6E7681"
                       FontFamily="Consolas" FontSize="10" VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis"/>
            <Button x:Name="btnCancel" Grid.Column="1" Content="Cancel" Width="80"/>
            <Button x:Name="btnSelect" Grid.Column="3" Content="Use This Path ->"
                    Style="{StaticResource AccentBtn}"/>
        </Grid>
    </Grid>
</Window>
'@

    [xml]$xml    = $xaml
    $dialog      = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xml))

    # --- Control refs ---
    $txtPath        = $dialog.FindName('txtPath')
    $btnGo          = $dialog.FindName('btnGo')
    $btnBack        = $dialog.FindName('btnBack')
    $btnUp          = $dialog.FindName('btnUp')
    $btnRefresh     = $dialog.FindName('btnRefresh')
    $lstItems       = $dialog.FindName('lstItems')
    $pnlStatus      = $dialog.FindName('pnlStatus')
    $lblStatus      = $dialog.FindName('lblStatus')
    $txtSaveName    = $dialog.FindName('txtSaveName')
    $btnSavePath    = $dialog.FindName('btnSavePath')
    $btnCancel      = $dialog.FindName('btnCancel')
    $btnSelect      = $dialog.FindName('btnSelect')
    $lblCurrentPath = $dialog.FindName('lblCurrentPath')

    # State
    $script:PBCurrentPath = $InitialPath -or $InitialShare
    $script:PBHistory     = [System.Collections.Generic.Stack[string]]::new()
    $dialog.Tag           = $null

    if ($script:PBCurrentPath) { $txtPath.Text = $script:PBCurrentPath }

    # --- Browse function ---
    $doBrowse = {
        param([string]$path)

        $path = $path.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { return }

        $pnlStatus.Visibility = 'Visible'
        $lblStatus.Text       = '---  Loading...'
        $lstItems.Items.Clear()

        try {
            $items = Get-UNCDirectoryListing -UNCPath $path -Credential $Credential -ErrorAction Stop

            foreach ($item in $items) {
                $null = $lstItems.Items.Add([PSCustomObject]@{
                    Icon     = if ($item.IsDirectory) { '----' } else { '----' }
                    Name     = $item.Name
                    Size     = $item.Size
                    Modified = $item.LastModified.ToString('yyyy-MM-dd HH:mm')
                    FullPath = $item.FullUNCPath
                    IsDir    = $item.IsDirectory
                })
            }

            $script:PBCurrentPath = $path
            $lblCurrentPath.Text  = $path
            $txtPath.Text         = $path

            if ($lstItems.Items.Count -gt 0) {
                $pnlStatus.Visibility = 'Collapsed'
            } else {
                $lblStatus.Text = '(Empty folder)'
            }
        }
        catch {
            $lblStatus.Text = "---  $($_.Exception.Message)"
        }
    }

    # --- Events ---
    $btnGo.Add_Click({
        if ($script:PBCurrentPath) { $script:PBHistory.Push($script:PBCurrentPath) }
        & $doBrowse $txtPath.Text
    })

    $txtPath.Add_KeyDown({
        param($s,$e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            if ($script:PBCurrentPath) { $script:PBHistory.Push($script:PBCurrentPath) }
            & $doBrowse $txtPath.Text
        }
    })

    $btnRefresh.Add_Click({ & $doBrowse $script:PBCurrentPath })

    $btnBack.Add_Click({
        if ($script:PBHistory.Count -gt 0) {
            $prev = $script:PBHistory.Pop()
            $txtPath.Text = $prev
            & $doBrowse $prev
        }
    })

    $btnUp.Add_Click({
        if ($script:PBCurrentPath) {
            $parent = Split-Path $script:PBCurrentPath -Parent
            if ($parent -and $parent -ne $script:PBCurrentPath) {
                $script:PBHistory.Push($script:PBCurrentPath)
                $txtPath.Text = $parent
                & $doBrowse $parent
            }
        }
    })

    $lstItems.Add_MouseDoubleClick({
        $sel = $lstItems.SelectedItem
        if ($sel -and $sel.IsDir) {
            $script:PBHistory.Push($script:PBCurrentPath)
            $txtPath.Text = $sel.FullPath
            & $doBrowse $sel.FullPath
        }
    })

    $lstItems.Add_SelectionChanged({
        $sel = $lstItems.SelectedItem
        if ($sel) { $txtPath.Text = $sel.FullPath }
    })

    $btnSavePath.Add_Click({
        $saveName = $txtSaveName.Text.Trim()
        $savePath = $lblCurrentPath.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($saveName)) {
            [System.Windows.MessageBox]::Show(
                'Please enter a name for this Quick Path.',
                'Save Quick Path', 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($savePath)) {
            [System.Windows.MessageBox]::Show(
                'Please navigate to a folder first.',
                'Save Quick Path', 'OK', 'Warning') | Out-Null
            return
        }

        $ok = Save-UserDefinedPath -Name $saveName -FullPath $savePath `
                                   -Category $Category -ServerName $ServerName
        if ($ok) {
            [System.Windows.MessageBox]::Show(
                "Path saved as '$saveName'.`n`nYou can access it from the Quick Paths panel.",
                'Saved ---', 'OK', 'Information') | Out-Null

            $dialog.Tag = [PSCustomObject]@{
                SelectedPath = $savePath
                SavedName    = $saveName
                Saved        = $true
            }
            $dialog.DialogResult = $true
        } else {
            [System.Windows.MessageBox]::Show(
                'This path is already saved.',
                'Duplicate', 'OK', 'Warning') | Out-Null
        }
    })

    $btnSelect.Add_Click({
        $selPath = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($selPath)) {
            [System.Windows.MessageBox]::Show('Please navigate to a path first.', 'Select Path', 'OK', 'Warning') | Out-Null
            return
        }
        $dialog.Tag = [PSCustomObject]@{
            SelectedPath = $selPath
            SavedName    = $null
            Saved        = $false
        }
        $dialog.DialogResult = $true
    })

    $btnCancel.Add_Click({ $dialog.DialogResult = $false })

    # Initial browse if path provided
    if ($script:PBCurrentPath) { & $doBrowse $script:PBCurrentPath }

    if ($dialog.ShowDialog() -eq $true) { return $dialog.Tag }
    return $null
}

Export-ModuleMember -Function Initialize-FileExplorer, Get-QuickPaths, Save-UserDefinedPath,
    Remove-UserDefinedPath, Get-UNCDirectoryListing, Get-UNCFileContent,
    Show-PathBrowserDialog
