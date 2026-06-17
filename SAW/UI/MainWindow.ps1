#========================================================================
# UI\MainWindow.ps1 — Main Application Window
# Full WPF UI: server browser, file explorer, log viewer, global search
# Dot-sourced from SAW.ps1 after all modules are imported
#========================================================================

function Show-MainWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    # ── Load Settings ──────────────────────────────────────────────────
    $settingsFile = Join-Path $script:ConfigDir 'Settings.json'
    $settings     = if (Test-Path $settingsFile) {
        Get-Content $settingsFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ DefaultUsername = 'NA\S123456'; MaxRecentItems = 50; LogViewerMaxLines = 5000 }
    }

    # ── Window state ───────────────────────────────────────────────────
    $script:MW_Cred           = $Credential
    $script:MW_CurrentServer  = $null
    $script:MW_CurrentPath    = $null
    $script:MW_OpenTabs       = [System.Collections.Generic.Dictionary[string,object]]::new()
    $script:MW_SearchTimer    = $null
    $maxLinesRaw      = if ($settings.LogViewerMaxLines) { $settings.LogViewerMaxLines } else { 5000 }
    $script:MW_LogMaxLines    = [int]$maxLinesRaw

    # ── Main XAML ──────────────────────────────────────────────────────
    $mainXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Server Access Workbench — CyberArk Operations Console"
    Height="900" Width="1480"
    MinHeight="650" MinWidth="1000"
    WindowStartupLocation="CenterScreen"
    Background="#0D1117"
    FontFamily="Segoe UI">

    <Window.Resources>
        <!-- ── Colours ── -->
        <SolidColorBrush x:Key="BgDeep"     Color="#0D1117"/>
        <SolidColorBrush x:Key="BgSurface"  Color="#161B22"/>
        <SolidColorBrush x:Key="BgPanel"    Color="#1C2128"/>
        <SolidColorBrush x:Key="BgHover"    Color="#21262D"/>
        <SolidColorBrush x:Key="Border"     Color="#30363D"/>
        <SolidColorBrush x:Key="Accent"     Color="#1F6FEB"/>
        <SolidColorBrush x:Key="AccentGrn"  Color="#238636"/>
        <SolidColorBrush x:Key="AccentAmb"  Color="#D29922"/>
        <SolidColorBrush x:Key="AccentRed"  Color="#DA3633"/>
        <SolidColorBrush x:Key="TextPri"    Color="#E6EDF3"/>
        <SolidColorBrush x:Key="TextSec"    Color="#8B949E"/>
        <SolidColorBrush x:Key="TextMuted"  Color="#484F58"/>
        <SolidColorBrush x:Key="Highlight"  Color="#F0883E"/>

        <!-- ── Base TextBlock ── -->
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextPri}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>

        <!-- ── Scroll bars ── -->
        <Style TargetType="ScrollBar">
            <Setter Property="Background"   Value="#161B22"/>
            <Setter Property="Foreground"   Value="#30363D"/>
            <Setter Property="BorderBrush"  Value="Transparent"/>
            <Setter Property="Width"        Value="8"/>
        </Style>

        <!-- ── TextBox ── -->
        <Style TargetType="TextBox">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="CaretBrush"      Value="#E6EDF3"/>
            <Setter Property="SelectionBrush"  Value="#1F6FEB"/>
        </Style>

        <!-- ── Standard Button ── -->
        <Style TargetType="Button">
            <Setter Property="Background"      Value="#21262D"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="10,5"/>
            <Setter Property="FontSize"        Value="11"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#30363D"/>
                            </Trigger>
                            <Trigger Property="IsPressed"   Value="True">
                                <Setter Property="Background" Value="#0D1117"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── Accent Button (Blue) ── -->
        <Style x:Key="BtnAccent" TargetType="Button">
            <Setter Property="Background"      Value="#1F6FEB"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="12,5"/>
            <Setter Property="FontSize"        Value="11"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#388BFD"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#1158C7"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── Accent Button (Green) ── -->
        <Style x:Key="BtnGreen" TargetType="Button">
            <Setter Property="Background"      Value="#238636"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="12,5"/>
            <Setter Property="FontSize"        Value="11"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#2EA043"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── Danger Button (Red) ── -->
        <Style x:Key="BtnDanger" TargetType="Button">
            <Setter Property="Background"      Value="#DA3633"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="10,5"/>
            <Setter Property="FontSize"        Value="11"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#B91C1C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── ListBox / ListBoxItem ── -->
        <Style TargetType="ListBox">
            <Setter Property="Background"      Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="0"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="Background"      Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4"
                                Padding="{TemplateBinding Padding}" Margin="2,1">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#21262D"/>
                            </Trigger>
                            <Trigger Property="IsSelected"   Value="True">
                                <Setter Property="Background" Value="#1F6FEB30"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ── DataGrid ── -->
        <Style TargetType="DataGrid">
            <Setter Property="Background"           Value="#0D1117"/>
            <Setter Property="Foreground"           Value="#E6EDF3"/>
            <Setter Property="BorderBrush"          Value="#30363D"/>
            <Setter Property="BorderThickness"      Value="1"/>
            <Setter Property="GridLinesVisibility"  Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#21262D"/>
            <Setter Property="AlternatingRowBackground"  Value="#161B22"/>
            <Setter Property="RowBackground"             Value="#0D1117"/>
            <Setter Property="FontSize"             Value="12"/>
            <Setter Property="AutoGenerateColumns"  Value="False"/>
            <Setter Property="CanUserReorderColumns" Value="True"/>
            <Setter Property="CanUserResizeColumns" Value="True"/>
            <Setter Property="SelectionMode"        Value="Single"/>
            <Setter Property="HeadersVisibility"    Value="Column"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#8B949E"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="FontSize"        Value="11"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#21262D"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#1F6FEB25"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="6,3"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
        </Style>

        <!-- ── TabControl ── -->
        <Style TargetType="TabControl">
            <Setter Property="Background"      Value="#0D1117"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="0,1,0,0"/>
            <Setter Property="Padding"         Value="0"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#8B949E"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1,1,1,0"/>
            <Setter Property="Padding"         Value="12,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#0D1117"/>
                    <Setter Property="Foreground" Value="#E6EDF3"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#21262D"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- ── ComboBox ── -->
        <Style TargetType="ComboBox">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="FontSize"        Value="12"/>
        </Style>

        <!-- ── CheckBox ── -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="FontSize"        Value="11"/>
        </Style>

        <!-- ── ProgressBar ── -->
        <Style TargetType="ProgressBar">
            <Setter Property="Background"   Value="#21262D"/>
            <Setter Property="Foreground"   Value="#1F6FEB"/>
            <Setter Property="BorderBrush"  Value="#30363D"/>
            <Setter Property="Height"       Value="4"/>
        </Style>

        <!-- ── Expander ── -->
        <Style TargetType="Expander">
            <Setter Property="Background"       Value="Transparent"/>
            <Setter Property="BorderThickness"  Value="0"/>
            <Setter Property="Foreground"       Value="#E6EDF3"/>
            <Setter Property="IsExpanded"       Value="True"/>
        </Style>
    </Window.Resources>

    <DockPanel>
        <!-- ═══ MENU BAR ═══ -->
        <Menu DockPanel.Dock="Top" Background="#161B22" Foreground="#E6EDF3" FontSize="12" Padding="4,2">
            <MenuItem Header="_File" Foreground="#E6EDF3">
                <MenuItem x:Name="mnuImportServers"   Header="&#x1F4C2; Import Servers..."/>
                <MenuItem x:Name="mnuExportServers"   Header="&#x1F4BE; Export Servers..."/>
                <Separator Background="#30363D"/>
                <MenuItem x:Name="mnuOpenLog"         Header="&#x1F4C4; Open App Log"/>
                <Separator Background="#30363D"/>
                <MenuItem x:Name="mnuExit"            Header="Exit"/>
            </MenuItem>
            <MenuItem Header="_Servers" Foreground="#E6EDF3">
                <MenuItem x:Name="mnuAddServer"       Header="&#x2795; Add Server"/>
                <MenuItem x:Name="mnuEditServer"      Header="&#x270E; Edit Selected Server"/>
                <MenuItem x:Name="mnuDeleteServer"    Header="&#x1F5D1; Delete Selected Server"/>
                <Separator Background="#30363D"/>
                <MenuItem x:Name="mnuTestConnection"  Header="&#x1F9EA; Test Connection"/>
            </MenuItem>
            <MenuItem Header="_Search" Foreground="#E6EDF3">
                <MenuItem x:Name="mnuSearchAll"       Header="Search All Servers"/>
                <MenuItem x:Name="mnuSearchCategory"  Header="Search Current Category"/>
                <MenuItem x:Name="mnuSearchCurrent"   Header="Search Current Server"/>
                <Separator Background="#30363D"/>
                <MenuItem x:Name="mnuExportResults"   Header="Export Search Results to CSV"/>
            </MenuItem>
            <MenuItem Header="_Tools" Foreground="#E6EDF3">
                <MenuItem x:Name="mnuBrowsePath"      Header="&#x1F4C1; Browse Network Path..."/>
                <MenuItem x:Name="mnuClearHistory"    Header="Clear Recent History"/>
            </MenuItem>
            <MenuItem Header="_Help" Foreground="#E6EDF3">
                <MenuItem x:Name="mnuAbout"           Header="About SAW"/>
            </MenuItem>
        </Menu>

        <!-- ═══ STATUS BAR ═══ -->
        <StatusBar DockPanel.Dock="Bottom" Background="#161B22" Height="26" Padding="8,0">
            <StatusBarItem>
                <TextBlock x:Name="sbServer" Text="No server selected" Foreground="#8B949E" FontSize="11"/>
            </StatusBarItem>
            <Separator Background="#30363D"/>
            <StatusBarItem>
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="sbConnDot" Width="8" Height="8" Fill="#484F58" Margin="0,0,5,0"/>
                    <TextBlock x:Name="sbConn" Text="Disconnected" Foreground="#8B949E" FontSize="11"/>
                </StackPanel>
            </StatusBarItem>
            <Separator Background="#30363D"/>
            <StatusBarItem>
                <TextBlock x:Name="sbUser" Text="—" Foreground="#8B949E" FontSize="11"/>
            </StatusBarItem>
            <StatusBarItem HorizontalAlignment="Right">
                <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="sbSearchStatus" Text="" Foreground="#F0883E" FontSize="11" Margin="0,0,12,0"/>
                    <ProgressBar x:Name="sbProgress" Width="120" Visibility="Collapsed" Margin="0,0,8,0"/>
                </StackPanel>
            </StatusBarItem>
        </StatusBar>

        <!-- ═══ MAIN CONTENT ═══ -->
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="3*" MinHeight="300"/>
                <RowDefinition Height="5"/>
                <RowDefinition Height="2*" MinHeight="160"/>
            </Grid.RowDefinitions>

            <!-- ── Top: 3-panel row ── -->
            <Grid Grid.Row="0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="270" MinWidth="200"/>
                    <ColumnDefinition Width="5"/>
                    <ColumnDefinition Width="*" MinWidth="300"/>
                    <ColumnDefinition Width="5"/>
                    <ColumnDefinition Width="320" MinWidth="250"/>
                </Grid.ColumnDefinitions>

                <!-- ══ LEFT PANEL — Server List ══ -->
                <Border Grid.Column="0" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,0,1,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Panel header -->
                        <Border Grid.Row="0" Background="#1C2128" Padding="12,10" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="4"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="SERVERS" Foreground="#8B949E"
                                           FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                <Button x:Name="btnAddServer" Grid.Column="1" Content="+" Width="26" Height="22"
                                        FontSize="14" FontWeight="Bold" ToolTip="Add Server"/>
                                <Button x:Name="btnRefreshServers" Grid.Column="3" Content="↻" Width="26" Height="22"
                                        FontSize="13" ToolTip="Refresh server list"/>
                            </Grid>
                        </Border>

                        <!-- Server search -->
                        <Border Grid.Row="1" Padding="8,6" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <Grid>
                                <TextBox x:Name="txtServerFilter" FontSize="12" Padding="24,5,8,5"/>
                                <TextBlock Text="&#x1F50D;" Foreground="#484F58" FontSize="12"
                                           Margin="8,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                            </Grid>
                        </Border>

                        <!-- Server tree (categories → servers) -->
                        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"
                                      HorizontalScrollBarVisibility="Disabled">
                            <StackPanel x:Name="pnlServerTree" Margin="4,4"/>
                        </ScrollViewer>

                        <!-- Favorites strip -->
                        <Border Grid.Row="3" Background="#1C2128" BorderBrush="#30363D" BorderThickness="0,1,0,0">
                            <Expander Header="⭐ FAVORITES" Foreground="#8B949E"
                                      FontSize="10" FontWeight="SemiBold" Padding="8,4">
                                <ListBox x:Name="lstFavoriteServers" MaxHeight="120" FontSize="11"
                                         ScrollViewer.VerticalScrollBarVisibility="Auto"/>
                            </Expander>
                        </Border>
                    </Grid>
                </Border>

                <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"
                              Background="#21262D" ResizeBehavior="PreviousAndNext"/>

                <!-- ══ CENTER PANEL — File Browser ══ -->
                <Border Grid.Column="2" Background="#0D1117">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <!-- Center header / path bar -->
                        <Border Grid.Row="0" Background="#161B22" Padding="12,8" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <Button x:Name="btnNavUp" Grid.Column="0" Content="↑" Width="28" Margin="0,0,4,0" ToolTip="Go up"/>
                                <Button x:Name="btnNavBack" Grid.Column="1" Content="←" Width="28" Margin="0,0,8,0" ToolTip="Back"/>
                                <TextBox x:Name="txtCurrentPath" Grid.Column="2" FontFamily="Consolas"
                                         FontSize="11" Padding="8,5" IsReadOnly="False"/>
                                <Button x:Name="btnGoPath" Grid.Column="3" Content="Go" Margin="4,0,0,0"
                                        Style="{StaticResource BtnAccent}" Width="40"/>
                                <Button x:Name="btnBrowsePath" Grid.Column="4" Content="&#x1F4C2; Browse"
                                        Margin="4,0,0,0" ToolTip="Browse network path"/>
                                <Button x:Name="btnSaveFavPath" Grid.Column="5" Content="⭐"
                                        Margin="4,0,0,0" Width="28" ToolTip="Save path as favorite"/>
                            </Grid>
                        </Border>

                        <!-- Quick Paths bar -->
                        <Border Grid.Row="1" Background="#1C2128" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <TextBlock Grid.Row="0" Text="QUICK PATHS" Foreground="#8B949E"
                                           FontSize="9" FontWeight="SemiBold" Margin="12,6,12,2"/>
                                <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Auto"
                                              VerticalScrollBarVisibility="Disabled" Margin="8,0,8,6">
                                    <WrapPanel x:Name="pnlQuickPaths" Orientation="Horizontal"/>
                                </ScrollViewer>
                            </Grid>
                        </Border>

                        <!-- File list toolbar -->
                        <Border Grid.Row="2" Background="#161B22" Padding="8,5" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="lblFileCount" Grid.Column="0" Text="Select a server and path"
                                           Foreground="#8B949E" FontSize="11" VerticalAlignment="Center"/>
                                <Button x:Name="btnRefreshFiles" Grid.Column="1" Content="↻ Refresh"
                                        FontSize="11" Margin="0,0,4,0"/>
                                <Button x:Name="btnCopyPath" Grid.Column="2" Content="&#x1F4CB; Copy Path"
                                        FontSize="11" Margin="0,0,4,0"/>
                                <Button x:Name="btnOpenFile" Grid.Column="3" Content="Open ↓"
                                        FontSize="11" Style="{StaticResource BtnAccent}"/>
                            </Grid>
                        </Border>

                        <!-- File list DataGrid -->
                        <DataGrid x:Name="dgFiles" Grid.Row="3" IsReadOnly="True"
                                  CanUserSortColumns="True" SelectionMode="Single">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Name"     Binding="{Binding Name}"     Width="2*"/>
                                <DataGridTextColumn Header="Type"     Binding="{Binding Extension}" Width="60"/>
                                <DataGridTextColumn Header="Size"     Binding="{Binding Size}"     Width="80"/>
                                <DataGridTextColumn Header="Modified" Binding="{Binding LastModifiedStr}" Width="140"/>
                            </DataGrid.Columns>
                            <DataGrid.RowStyle>
                                <Style TargetType="DataGridRow">
                                    <Setter Property="ToolTip" Value="{Binding FullUNCPath}"/>
                                    <Style.Triggers>
                                        <DataTrigger Binding="{Binding IsDirectory}" Value="True">
                                            <Setter Property="Foreground" Value="#1F6FEB"/>
                                        </DataTrigger>
                                    </Style.Triggers>
                                </Style>
                            </DataGrid.RowStyle>
                        </DataGrid>
                    </Grid>
                </Border>

                <GridSplitter Grid.Column="3" Width="5" HorizontalAlignment="Stretch"
                              Background="#21262D" ResizeBehavior="PreviousAndNext"/>

                <!-- ══ RIGHT PANEL — Global Search ══ -->
                <Border Grid.Column="4" Background="#161B22" BorderBrush="#30363D" BorderThickness="1,0,0,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Header -->
                        <Border Grid.Row="0" Background="#1C2128" Padding="12,10" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                            <TextBlock Text="&#x1F50E; GLOBAL SEARCH" Foreground="#8B949E"
                                       FontSize="11" FontWeight="SemiBold"/>
                        </Border>

                        <!-- Search input -->
                        <StackPanel Grid.Row="1" Margin="8,8,8,0">
                            <Grid Margin="0,0,0,6">
                                <TextBox x:Name="txtSearch" FontSize="12" Padding="8,7"/>
                                <TextBlock Text="Search text..." Foreground="#484F58" FontSize="12"
                                           Margin="10,7" IsHitTestVisible="False"
                                           x:Name="lblSearchPlaceholder"/>
                            </Grid>
                            <Grid Margin="0,0,0,6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <ComboBox x:Name="cmbSearchScope" Grid.Column="0" FontSize="11">
                                    <ComboBoxItem Content="All Servers"      IsSelected="True"/>
                                    <ComboBoxItem Content="Current Category"/>
                                    <ComboBoxItem Content="Current Server"/>
                                    <ComboBoxItem Content="PVWA Servers"/>
                                    <ComboBoxItem Content="CPM Servers"/>
                                    <ComboBoxItem Content="PSM Servers"/>
                                    <ComboBoxItem Content="PTA Servers"/>
                                </ComboBox>
                                <Button x:Name="btnSearch"    Grid.Column="2" Content="Search"
                                        Style="{StaticResource BtnAccent}" FontSize="11"/>
                                <Button x:Name="btnStopSearch" Grid.Column="4" Content="■ Stop"
                                        Style="{StaticResource BtnDanger}" FontSize="11" Visibility="Collapsed"/>
                            </Grid>
                        </StackPanel>

                        <!-- Search filters (collapsible) -->
                        <Expander Grid.Row="2" Header="Advanced Filters" Margin="8,0" IsExpanded="False"
                                  Foreground="#8B949E" FontSize="11">
                            <StackPanel Margin="0,6,0,4">
                                <Grid Margin="0,0,0,4">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="8"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0">
                                        <TextBlock Text="File Pattern" Foreground="#6E7681" FontSize="10" Margin="0,0,0,2"/>
                                        <TextBox x:Name="txtFilePattern" Text="*" FontSize="11"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="2">
                                        <TextBlock Text="Max File Size" Foreground="#6E7681" FontSize="10" Margin="0,0,0,2"/>
                                        <ComboBox x:Name="cmbMaxFileSize" FontSize="11">
                                            <ComboBoxItem Content="No limit" IsSelected="True"/>
                                            <ComboBoxItem Content="1 MB"/>
                                            <ComboBoxItem Content="10 MB"/>
                                            <ComboBoxItem Content="50 MB"/>
                                            <ComboBoxItem Content="100 MB"/>
                                        </ComboBox>
                                    </StackPanel>
                                </Grid>
                                <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                                    <CheckBox x:Name="chkCaseSensitive"  Content="Case-sensitive"  Margin="0,0,12,0"/>
                                    <CheckBox x:Name="chkSearchFileNames" Content="Search filenames"/>
                                </StackPanel>
                            </StackPanel>
                        </Expander>

                        <!-- Search results -->
                        <DataGrid x:Name="dgSearchResults" Grid.Row="3" Margin="4,4,4,0"
                                  IsReadOnly="True" CanUserSortColumns="True">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Server"  Binding="{Binding ServerName}" Width="70"/>
                                <DataGridTextColumn Header="File"    Binding="{Binding FileName}"   Width="100"/>
                                <DataGridTextColumn Header="Line"    Binding="{Binding LineNumber}"  Width="50"/>
                                <DataGridTextColumn Header="Preview" Binding="{Binding LineText}"   Width="*"/>
                            </DataGrid.Columns>
                            <DataGrid.RowStyle>
                                <Style TargetType="DataGridRow">
                                    <Setter Property="ToolTip" Value="{Binding FilePath}"/>
                                    <Style.Triggers>
                                        <DataTrigger Binding="{Binding ResultType}" Value="Error">
                                            <Setter Property="Foreground" Value="#DA3633"/>
                                        </DataTrigger>
                                    </Style.Triggers>
                                </Style>
                            </DataGrid.RowStyle>
                        </DataGrid>

                        <!-- Search result toolbar -->
                        <Border Grid.Row="4" Background="#1C2128" Padding="8,5" BorderBrush="#30363D" BorderThickness="0,1,0,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="lblResultCount" Grid.Column="0" Text="0 results"
                                           Foreground="#8B949E" FontSize="11" VerticalAlignment="Center"/>
                                <Button x:Name="btnExportResults" Grid.Column="1" Content="&#x1F4BE; Export"
                                        FontSize="11" Margin="0,0,4,0"/>
                                <Button x:Name="btnCopyResults" Grid.Column="2" Content="&#x1F4CB; Copy"
                                        FontSize="11"/>
                            </Grid>
                        </Border>

                        <!-- Recent Activity -->
                        <Border Grid.Row="5" BorderBrush="#30363D" BorderThickness="0,1,0,0">
                            <Expander Header="RECENT ACTIVITY" Foreground="#8B949E" FontSize="10"
                                      FontWeight="SemiBold" Padding="8,6" IsExpanded="True">
                                <ListBox x:Name="lstRecentActivity" MaxHeight="100" FontSize="11"
                                         ScrollViewer.VerticalScrollBarVisibility="Auto"/>
                            </Expander>
                        </Border>
                    </Grid>
                </Border>
            </Grid>

            <!-- ── Horizontal splitter ── -->
            <GridSplitter Grid.Row="1" Height="5" HorizontalAlignment="Stretch"
                          Background="#21262D" ResizeBehavior="PreviousAndNext"/>

            <!-- ══ BOTTOM PANEL — Integrated Log Viewer ══ -->
            <Border Grid.Row="2" Background="#0D1117" BorderBrush="#30363D" BorderThickness="0,1,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Log viewer toolbar -->
                    <Border Grid.Row="0" Background="#161B22" Padding="8,5" BorderBrush="#30363D" BorderThickness="0,0,0,1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="LOG VIEWER" Foreground="#8B949E"
                                       FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center" Margin="4,0,12,0"/>
                            <TextBox x:Name="txtLogSearch" Grid.Column="1" FontSize="11"
                                     Padding="6,4" MaxWidth="200" HorizontalAlignment="Left"
                                     ToolTip="Search within current file"/>
                            <Button x:Name="btnLogSearchGo"  Grid.Column="2" Content="Find" FontSize="11" Margin="4,0"/>
                            <Button x:Name="btnLogPrevMatch" Grid.Column="3" Content="↑" Width="26" Margin="0,0,2,0" ToolTip="Previous match"/>
                            <Button x:Name="btnLogNextMatch" Grid.Column="4" Content="↓" Width="26" Margin="0,0,8,0" ToolTip="Next match"/>
                            <Button x:Name="btnWordWrap"   Grid.Column="5" Content="Wrap" FontSize="11" Margin="0,0,4,0" ToolTip="Toggle word wrap"/>
                            <Button x:Name="btnLogTail"    Grid.Column="6" Content="⤓ Tail" FontSize="11" Margin="0,0,4,0" ToolTip="Jump to end"/>
                            <Button x:Name="btnLogRefresh" Grid.Column="7" Content="↻ Refresh" FontSize="11" Margin="0,0,4,0"/>
                            <Button x:Name="btnLogCopy"    Grid.Column="8" Content="&#x1F4CB; Copy" FontSize="11"/>
                        </Grid>
                    </Border>

                    <!-- Log viewer tabs -->
                    <TabControl x:Name="tabLogViewer" Grid.Row="1">
                        <TabItem Header="— No file open —" x:Name="tabWelcome">
                            <Border Background="#0D1117">
                                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                    <TextBlock Text="&#x1F4C4;" FontSize="48" HorizontalAlignment="Center"
                                               Foreground="#21262D" Margin="0,0,0,16"/>
                                    <TextBlock Text="Double-click a file in the browser above to open it here."
                                               Foreground="#484F58" FontSize="13" HorizontalAlignment="Center"/>
                                    <TextBlock Text="Click a search result to jump directly to the matching line."
                                               Foreground="#484F58" FontSize="12" HorizontalAlignment="Center" Margin="0,6,0,0"/>
                                </StackPanel>
                            </Border>
                        </TabItem>
                    </TabControl>
                </Grid>
            </Border>
        </Grid>
    </DockPanel>
</Window>
'@

    [xml]$xml = $mainXaml
    $w        = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xml))

    # ── Control references ────────────────────────────────────────────
    $pnlServerTree    = $w.FindName('pnlServerTree')
    $txtServerFilter  = $w.FindName('txtServerFilter')
    $lstFavServers    = $w.FindName('lstFavoriteServers')
    $dgFiles          = $w.FindName('dgFiles')
    $txtCurrentPath   = $w.FindName('txtCurrentPath')
    $btnGoPath        = $w.FindName('btnGoPath')
    $btnNavUp         = $w.FindName('btnNavUp')
    $btnNavBack       = $w.FindName('btnNavBack')
    $btnBrowsePath    = $w.FindName('btnBrowsePath')
    $btnSaveFavPath   = $w.FindName('btnSaveFavPath')
    $pnlQuickPaths    = $w.FindName('pnlQuickPaths')
    $lblFileCount     = $w.FindName('lblFileCount')
    $btnRefreshFiles  = $w.FindName('btnRefreshFiles')
    $btnCopyPath      = $w.FindName('btnCopyPath')
    $btnOpenFile      = $w.FindName('btnOpenFile')
    $txtSearch        = $w.FindName('txtSearch')
    $lblSrchPlaceholder = $w.FindName('lblSearchPlaceholder')
    $cmbSearchScope   = $w.FindName('cmbSearchScope')
    $btnSearch        = $w.FindName('btnSearch')
    $btnStopSearch    = $w.FindName('btnStopSearch')
    $dgSearchResults  = $w.FindName('dgSearchResults')
    $lblResultCount   = $w.FindName('lblResultCount')
    $btnExportResults = $w.FindName('btnExportResults')
    $btnCopyResults   = $w.FindName('btnCopyResults')
    $lstRecentActivity = $w.FindName('lstRecentActivity')
    $tabLogViewer     = $w.FindName('tabLogViewer')
    $btnWordWrap      = $w.FindName('btnWordWrap')
    $btnLogRefresh    = $w.FindName('btnLogRefresh')
    $btnLogTail       = $w.FindName('btnLogTail')
    $btnLogCopy       = $w.FindName('btnLogCopy')
    $btnLogSearchGo   = $w.FindName('btnLogSearchGo')
    $btnLogPrevMatch  = $w.FindName('btnLogPrevMatch')
    $btnLogNextMatch  = $w.FindName('btnLogNextMatch')
    $txtLogSearch     = $w.FindName('txtLogSearch')
    $sbServer         = $w.FindName('sbServer')
    $sbConn           = $w.FindName('sbConn')
    $sbConnDot        = $w.FindName('sbConnDot')
    $sbUser           = $w.FindName('sbUser')
    $sbSearchStatus   = $w.FindName('sbSearchStatus')
    $sbProgress       = $w.FindName('sbProgress')
    $txtFilePattern   = $w.FindName('txtFilePattern')
    $chkCaseSensitive = $w.FindName('chkCaseSensitive')
    $chkSearchFileNames = $w.FindName('chkSearchFileNames')
    $cmbMaxFileSize   = $w.FindName('cmbMaxFileSize')
    $btnAddServer     = $w.FindName('btnAddServer')
    $btnRefreshServers = $w.FindName('btnRefreshServers')

    # Menu items
    $mnuAddServer    = $w.FindName('mnuAddServer')
    $mnuEditServer   = $w.FindName('mnuEditServer')
    $mnuDeleteServer = $w.FindName('mnuDeleteServer')
    $mnuTestConn     = $w.FindName('mnuTestConnection')
    $mnuImport       = $w.FindName('mnuImportServers')
    $mnuExport       = $w.FindName('mnuExportServers')
    $mnuSearchAll    = $w.FindName('mnuSearchAll')
    $mnuBrowsePath   = $w.FindName('mnuBrowsePath')
    $mnuExportResults = $w.FindName('mnuExportResults')
    $mnuClearHistory = $w.FindName('mnuClearHistory')
    $mnuAbout        = $w.FindName('mnuAbout')
    $mnuOpenLog      = $w.FindName('mnuOpenLog')
    $mnuExit         = $w.FindName('mnuExit')

    # ── Inner state ───────────────────────────────────────────────────
    $script:MW_Window         = $w
    $script:MW_NavHistory     = [System.Collections.Generic.Stack[string]]::new()
    $script:MW_SearchResults  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:MW_LogMatchLines  = [System.Collections.Generic.List[int]]::new()
    $script:MW_LogMatchIndex  = -1
    $script:MW_WordWrap       = $false
    $script:MW_SearchTimer    = $null

    # ── Status bar helpers ─────────────────────────────────────────────
    $setStatus = {
        param([string]$Text, [string]$Color = '#8B949E')
        $sbServer.Text     = $Text
        $sbConn.Text       = 'Connected'
        $sbConnDot.Fill    = '#238636'
        $sbUser.Text       = "Authenticated as: $($script:MW_Cred.UserName)"
    }

    $setProgress = {
        param([bool]$Show, [string]$Text = '')
        $sbProgress.Visibility    = if ($Show) { 'Visible' } else { 'Collapsed' }
        $sbProgress.IsIndeterminate = $Show
        $sbSearchStatus.Text      = $Text
    }

    # ── Server tree builder ────────────────────────────────────────────
    function _BuildServerTree {
        param([string]$Filter = '')

        $pnlServerTree.Children.Clear()
        $categories = Get-ServerCategories

        foreach ($cat in $categories) {
            $servers = Get-Servers -Category $cat
            if ($Filter) {
                $servers = @($servers | Where-Object { $_.Name -like "*$Filter*" -or $_.Description -like "*$Filter*" })
            }
            if ($servers.Count -eq 0) { continue }

            # Category Expander
            $exp = [System.Windows.Controls.Expander]::new()
            $exp.IsExpanded = $true

            # Category header
            $hdrPanel = [System.Windows.Controls.StackPanel]::new()
            $hdrPanel.Orientation = 'Horizontal'

            $catDot = [System.Windows.Shapes.Ellipse]::new()
            $catDot.Width  = 8; $catDot.Height = 8; $catDot.Margin = [System.Windows.Thickness]::new(0,0,6,0)
            $catDot.VerticalAlignment = 'Center'
            $catColor = switch ($cat) {
                'PVWA'    { '#1F6FEB' } 'CPM' { '#238636' } 'PSM' { '#9B59B6' }
                'PTA'     { '#E67E22' } 'IIS' { '#E91E63' } 'SQL' { '#00BCD4' }
                default   { '#8B949E' }
            }
            $catDot.Fill = $catColor

            $catLabel = [System.Windows.Controls.TextBlock]::new()
            $catLabel.Text       = "$cat  ($($servers.Count))"
            $catLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#8B949E')
            $catLabel.FontSize   = 10
            $catLabel.FontWeight = 'SemiBold'
            $catLabel.VerticalAlignment = 'Center'

            $null = $hdrPanel.Children.Add($catDot)
            $null = $hdrPanel.Children.Add($catLabel)
            $exp.Header = $hdrPanel

            # Server list inside expander
            $srvList = [System.Windows.Controls.ListBox]::new()
            $srvList.Margin = [System.Windows.Thickness]::new(8,0,0,4)

            foreach ($srv in $servers) {
                $item = [System.Windows.Controls.ListBoxItem]::new()

                $itemPanel = [System.Windows.Controls.StackPanel]::new()
                $itemPanel.Orientation = 'Horizontal'

                $favStar = [System.Windows.Controls.TextBlock]::new()
                $favStar.Text     = if (Test-IsFavoriteServer -ServerName $srv.Name) { '[*] ' } else { '    ' }
                $favStar.FontSize = 10
                $favStar.VerticalAlignment = 'Center'

                $srvName = [System.Windows.Controls.TextBlock]::new()
                $srvName.Text     = $srv.Name
                $srvName.FontSize = 12
                $srvName.VerticalAlignment = 'Center'

                $null = $itemPanel.Children.Add($favStar)
                $null = $itemPanel.Children.Add($srvName)

                $item.Content  = $itemPanel
                $item.Tag      = $srv
                $item.ToolTip  = "$($srv.RootShare)`n$($srv.Description)"

                $null = $srvList.Items.Add($item)
            }

            $srvList.Add_SelectionChanged({
                param($sender, $e)
                $selItem = $sender.SelectedItem
                if ($selItem -and $selItem.Tag) {
                    _SelectServer -Server $selItem.Tag
                }
            })

            $exp.Content = $srvList
            $null = $pnlServerTree.Children.Add($exp)
        }
    }

    # ── Select a server ───────────────────────────────────────────────
    function _SelectServer {
        param([hashtable]$Server)

        $script:MW_CurrentServer = $Server
        $script:MW_CurrentPath   = $Server.RootShare
        $txtCurrentPath.Text     = $Server.RootShare

        & $setStatus "Server: $($Server.Name) - $($Server.RootShare)"
        $sbUser.Text = "Authenticated as: $($script:MW_Cred.UserName)"

        Add-RecentServer  -ServerName $Server.Name
        Add-RecentLocation -Location $Server.RootShare

        _LoadQuickPaths   -Category $Server.Category
        _LoadFileList     -Path $Server.RootShare

        Write-NexusLog "Server selected: $($Server.Name)" -Level INFO -Component 'MainWindow'
    }

    # ── Quick paths panel ─────────────────────────────────────────────
    function _LoadQuickPaths {
        param([string]$Category)

        $pnlQuickPaths.Children.Clear()

        $paths = Get-QuickPaths -Category $Category
        foreach ($qp in $paths) {
            $btn = [System.Windows.Controls.Button]::new()
            $btn.Content = $qp.Name
            $btn.FontSize = 11
            $btn.Margin   = [System.Windows.Thickness]::new(0,0,4,4)
            $btn.Padding  = [System.Windows.Thickness]::new(10,4,10,4)
            $btn.Tag      = $qp

            $btn.Add_Click({
                param($sender)
                $qpItem = $sender.Tag
                $fullPath = if ($qpItem.FullPath) {
                    $qpItem.FullPath
                } elseif ($script:MW_CurrentServer) {
                    Join-Path $script:MW_CurrentServer.RootShare $qpItem.RelativePath
                } else {
                    return
                }
                $script:MW_NavHistory.Push($script:MW_CurrentPath)
                $script:MW_CurrentPath   = $fullPath
                $txtCurrentPath.Text     = $fullPath
                _LoadFileList -Path $fullPath
            })

            $null = $pnlQuickPaths.Children.Add($btn)
        }

        # Add browse button
        $bBtn = [System.Windows.Controls.Button]::new()
        $bBtn.Content = 'Browse...'
        $bBtn.FontSize = 11
        $bBtn.Margin  = [System.Windows.Thickness]::new(0,0,4,4)
        $bBtn.Padding = [System.Windows.Thickness]::new(10,4,10,4)
        $bBtn.Add_Click({ _OpenPathBrowser })
        $null = $pnlQuickPaths.Children.Add($bBtn)
    }

    # ── File list loader (background thread) ──────────────────────────
    function _LoadFileList {
        param([string]$Path)

        if (-not $Path) { return }

        $lblFileCount.Text = 'Loading...'
        $dgFiles.Items.Clear()
        & $setProgress $true 'Loading directory...'

        $cred    = $script:MW_Cred
        $dispatcher = $w.Dispatcher

        $thread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
            try {
                $items = Get-UNCDirectoryListing -UNCPath $Path -Credential $cred

                $dispatcher.Invoke([System.Action]{
                    $dgFiles.Items.Clear()
                    foreach ($item in $items) {
                        $null = $dgFiles.Items.Add([PSCustomObject]@{
                            Name             = if ($item.IsDirectory) { "[DIR] $($item.Name)" } else { "[F]   $($item.Name)" }
                            Extension        = $item.Extension
                            Size             = $item.Size
                            LastModifiedStr  = $item.LastModified.ToString('yyyy-MM-dd HH:mm')
                            FullUNCPath      = $item.FullUNCPath
                            IsDirectory      = $item.IsDirectory
                            IsViewable       = $item.IsViewable
                            RawName          = $item.Name
                        })
                    }
                    $lblFileCount.Text = "$($items.Count) item(s)"
                    & $setProgress $false
                })
            }
            catch {
                $err = $_.Exception.Message
                $dispatcher.Invoke([System.Action]{
                    $lblFileCount.Text = "Error: $err"
                    & $setProgress $false
                    [System.Windows.MessageBox]::Show("Cannot access path:`n$Path`n`n$err", 'Access Error', 'OK', 'Warning') | Out-Null
                })
            }
        })
        $thread.IsBackground = $true
        $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
        $thread.Start()
    }

    # ── Open file in log viewer ───────────────────────────────────────
    function _OpenLogFile {
        param([string]$FilePath, [int]$JumpToLine = 0, [string]$HighlightText = '')

        $fileName   = Split-Path $FilePath -Leaf
        $cred       = $script:MW_Cred
        $dispatcher = $w.Dispatcher
        $maxLines   = $script:MW_LogMaxLines

        Add-RecentFile -FilePath $FilePath
        Write-NexusLog "Opening file: $FilePath" -Level INFO -Component 'LogViewer'

        & $setProgress $true "Loading $fileName..."

        $thread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
            try {
                $content = Get-LogFileContent -UNCFilePath $FilePath -Credential $cred `
                                               -MaxLines $maxLines -StartLine 1 `
                                               -HighlightText $HighlightText

                $dispatcher.Invoke([System.Action]{
                    _AddLogTab -FilePath $FilePath -FileName $fileName `
                               -Content $content -JumpToLine $JumpToLine `
                               -HighlightText $HighlightText
                    & $setProgress $false
                })
            }
            catch {
                $err = $_.Exception.Message
                $dispatcher.Invoke([System.Action]{
                    & $setProgress $false
                    [System.Windows.MessageBox]::Show("Cannot open file:`n$FilePath`n`n$err", 'File Error', 'OK', 'Error') | Out-Null
                })
            }
        })
        $thread.IsBackground = $true
        $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
        $thread.Start()
    }

    # ── Add log viewer tab ────────────────────────────────────────────
    function _AddLogTab {
        param(
            [string]$FilePath, [string]$FileName,
            $Content, [int]$JumpToLine = 0, [string]$HighlightText = ''
        )

        # If tab already exists, switch to it
        foreach ($tab in $tabLogViewer.Items) {
            if ($tab -is [System.Windows.Controls.TabItem] -and $tab.Tag -eq $FilePath) {
                $tabLogViewer.SelectedItem = $tab
                return
            }
        }

        # Create new tab
        $newTab     = [System.Windows.Controls.TabItem]::new()
        $newTab.Tag = $FilePath

        # Tab header with close button
        $hdrGrid = [System.Windows.Controls.Grid]::new()
        $hdrGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        $col2 = [System.Windows.Controls.ColumnDefinition]::new()
        $col2.Width = [System.Windows.GridLength]::new(20)
        $hdrGrid.ColumnDefinitions.Add($col2)

        $hdrText           = [System.Windows.Controls.TextBlock]::new()
        $hdrText.Text      = $FileName
        $hdrText.FontSize  = 11
        $hdrText.Margin    = [System.Windows.Thickness]::new(0,0,4,0)
        $hdrText.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($hdrText, 0)

        $closeBtn           = [System.Windows.Controls.Button]::new()
        $closeBtn.Content   = 'X'
        $closeBtn.FontSize  = 10
        $closeBtn.Width     = 18
        $closeBtn.Height    = 18
        $closeBtn.Padding   = [System.Windows.Thickness]::new(0)
        $closeBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $closeBtn.Background = [System.Windows.Media.Brushes]::Transparent
        $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#8B949E')
        $closeBtn.VerticalAlignment = 'Center'
        $closeBtn.Tag       = $newTab
        $closeBtn.Add_Click({
            param($sender)
            $tabToRemove = $sender.Tag
            $tabLogViewer.Items.Remove($tabToRemove)
        })
        [System.Windows.Controls.Grid]::SetColumn($closeBtn, 1)

        $null = $hdrGrid.Children.Add($hdrText)
        $null = $hdrGrid.Children.Add($closeBtn)
        $newTab.Header = $hdrGrid

        # Tab content: toolbar + log text
        $tabGrid = [System.Windows.Controls.Grid]::new()
        $tabGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
        $r2 = [System.Windows.Controls.RowDefinition]::new()
        $r2.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $tabGrid.RowDefinitions.Add($r2)

        # File info bar
        $infoBar = [System.Windows.Controls.Border]::new()
        $infoBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#161B22')
        $infoBar.Padding    = [System.Windows.Thickness]::new(10,4)

        $infoText           = [System.Windows.Controls.TextBlock]::new()
        $infoText.Text      = "$FilePath  |  $($Content.FileSize)  |  $($Content.TotalLines) lines  |  Modified: $($Content.LastModified.ToString('yyyy-MM-dd HH:mm'))"
        $infoText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#6E7681')
        $infoText.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $infoText.FontSize  = 10
        $infoText.TextTrimming = 'CharacterEllipsis'

        $infoBar.Child = $infoText
        [System.Windows.Controls.Grid]::SetRow($infoBar, 0)

        # Log text area (DataGrid for line numbers)
        $logGrid = [System.Windows.Controls.DataGrid]::new()
        $logGrid.AutoGenerateColumns = $false
        $logGrid.HeadersVisibility   = 'None'
        $logGrid.GridLinesVisibility = 'None'
        $logGrid.BorderThickness     = [System.Windows.Thickness]::new(0)
        $logGrid.Background          = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0D1117')
        $logGrid.RowBackground       = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0D1117')
        $logGrid.AlternatingRowBackground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0D1117')
        $logGrid.FontFamily          = [System.Windows.Media.FontFamily]::new('Consolas')
        $logGrid.FontSize            = 11
        $logGrid.IsReadOnly          = $true
        $logGrid.SelectionUnit       = 'Cell'
        $logGrid.CanUserResizeColumns = $true
        $logGrid.CanUserSortColumns  = $false

        # Line number column
        $lineNumCol          = [System.Windows.Controls.DataGridTextColumn]::new()
        $lineNumCol.Header   = '#'
        $lineNumCol.Binding  = [System.Windows.Data.Binding]::new('LineNumber')
        $lineNumCol.Width    = [System.Windows.Controls.DataGridLength]::new(55)
        $lineNumCol.IsReadOnly = $true
        $lineNumStyleSetter  = [System.Windows.Setter]::new()
        $lineNumStyleSetter.Property = [System.Windows.Controls.Control]::ForegroundProperty
        $lineNumStyleSetter.Value    = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#484F58')
        $lineNumStyle = [System.Windows.Style]::new([System.Windows.Controls.DataGridCell])
        $lineNumStyle.Setters.Add($lineNumStyleSetter)
        $lineNumCol.ElementStyle = $lineNumStyle

        # Content column
        $contentCol         = [System.Windows.Controls.DataGridTextColumn]::new()
        $contentCol.Header  = 'Content'
        $contentCol.Binding = [System.Windows.Data.Binding]::new('Text')
        $contentCol.Width   = [System.Windows.Controls.DataGridLength]::new(1, [System.Windows.Controls.DataGridLengthUnitType]::Star)

        $null = $logGrid.Columns.Add($lineNumCol)
        $null = $logGrid.Columns.Add($contentCol)

        # Populate rows
        foreach ($line in $Content.Lines) {
            $row = [PSCustomObject]@{
                LineNumber = $line.LineNumber
                Text       = $line.Text
                IsMatch    = $line.IsMatch
            }
            $null = $logGrid.Items.Add($row)
        }

        # Load more row if truncated
        if ($Content.IsTruncated) {
            $null = $logGrid.Items.Add([PSCustomObject]@{
                LineNumber = '...'
                Text       = "[File truncated at $($Content.EndLine) of $($Content.TotalLines) lines. Click Tail to load end]"
                IsMatch    = $false
            })
        }

        $logGrid.Tag = @{ FilePath = $FilePath; Content = $Content; HighlightText = $HighlightText }

        [System.Windows.Controls.Grid]::SetRow($logGrid, 1)

        $null = $tabGrid.Children.Add($infoBar)
        $null = $tabGrid.Children.Add($logGrid)

        $newTab.Content = $tabGrid
        $null = $tabLogViewer.Items.Add($newTab)
        $tabLogViewer.SelectedItem = $newTab

        # Jump to line
        if ($JumpToLine -gt 0 -and $logGrid.Items.Count -gt 0) {
            $idx = [Math]::Max(0, [Math]::Min($JumpToLine - $Content.StartLine, $logGrid.Items.Count - 1))
            $logGrid.ScrollIntoView($logGrid.Items[$idx])
            $logGrid.SelectedIndex = $idx
        }
    }

    # ── Path browser ──────────────────────────────────────────────────
    function _OpenPathBrowser {
        $cat = if ($script:MW_CurrentServer) { $script:MW_CurrentServer.Category } else { '' }
        $srvName = if ($script:MW_CurrentServer) { $script:MW_CurrentServer.Name } else { '' }
        $share   = if ($script:MW_CurrentServer) { $script:MW_CurrentServer.RootShare } else { '' }

        $result = Show-PathBrowserDialog -Credential $script:MW_Cred `
                                         -InitialPath $script:MW_CurrentPath `
                                         -InitialShare $share `
                                         -ServerName $srvName `
                                         -Category $cat
        if ($result) {
            $script:MW_NavHistory.Push($script:MW_CurrentPath)
            $script:MW_CurrentPath = $result.SelectedPath
            $txtCurrentPath.Text   = $result.SelectedPath
            _LoadFileList -Path $result.SelectedPath
            Add-RecentLocation -Location $result.SelectedPath

            if ($result.Saved) {
                _LoadQuickPaths -Category $cat
                [System.Windows.MessageBox]::Show(
                    "Quick Path '$($result.SavedName)' saved successfully!",
                    'Saved', 'OK', 'Information') | Out-Null
            }
        }
    }

    # ── Server editor dialog ──────────────────────────────────────────
    function _ShowServerEditor {
        param([hashtable]$ExistingServer = $null)

        $isEdit  = $null -ne $ExistingServer
        $title   = if ($isEdit) { 'Edit Server' } else { 'Add Server' }

        $edXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Height="420" Width="480"
    WindowStartupLocation="CenterOwner"
    Background="#0D1117" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,6"/>
            <Setter Property="FontSize"        Value="12"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background"      Value="#161B22"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="FontSize"        Value="12"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background"      Value="#21262D"/>
            <Setter Property="Foreground"      Value="#E6EDF3"/>
            <Setter Property="BorderBrush"     Value="#30363D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="12,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SaveBtn" TargetType="Button">
            <Setter Property="Background"      Value="#238636"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="14,6"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="lblTitle" Grid.Row="0" FontSize="16" FontWeight="Bold"
                   Foreground="#E6EDF3" Margin="0,0,0,20"/>
        <StackPanel Grid.Row="1">
            <TextBlock Text="Display Name" Foreground="#6E7681" FontSize="11" Margin="0,0,0,4"/>
            <TextBox x:Name="txtName" Margin="0,0,0,12"/>
            <TextBlock Text="Server FQDN / Hostname" Foreground="#6E7681" FontSize="11" Margin="0,0,0,4"/>
            <TextBox x:Name="txtServerName" Margin="0,0,0,12"/>
            <TextBlock Text="Root Share (UNC)" Foreground="#6E7681" FontSize="11" Margin="0,0,0,4"/>
            <TextBox x:Name="txtRootShare" Margin="0,0,0,12" FontFamily="Consolas"/>
            <TextBlock Text="Category" Foreground="#6E7681" FontSize="11" Margin="0,0,0,4"/>
            <ComboBox x:Name="cmbCategory" Margin="0,0,0,12">
                <ComboBoxItem Content="PVWA"/>
                <ComboBoxItem Content="CPM"/>
                <ComboBoxItem Content="PSM"/>
                <ComboBoxItem Content="PTA"/>
                <ComboBoxItem Content="IIS"/>
                <ComboBoxItem Content="SQL"/>
                <ComboBoxItem Content="Utility"/>
                <ComboBoxItem Content="Other" IsSelected="True"/>
            </ComboBox>
            <TextBlock Text="Description (optional)" Foreground="#6E7681" FontSize="11" Margin="0,0,0,4"/>
            <TextBox x:Name="txtDescription"/>
        </StackPanel>
        <Grid Grid.Row="2" Margin="0,20,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="btnEdCancel" Grid.Column="0" Content="Cancel"/>
            <Button x:Name="btnEdSave"   Grid.Column="2" Content="Save Server"
                    Style="{StaticResource SaveBtn}"/>
        </Grid>
    </Grid>
</Window>
'@

        [xml]$edXml  = $edXaml
        $edDlg       = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($edXml))

        $edDlg.Title = $title
        $edDlg.FindName('lblTitle').Text = $title

        $eName  = $edDlg.FindName('txtName')
        $eSrv   = $edDlg.FindName('txtServerName')
        $eShare = $edDlg.FindName('txtRootShare')
        $eCat   = $edDlg.FindName('cmbCategory')
        $eDesc  = $edDlg.FindName('txtDescription')
        $eSave  = $edDlg.FindName('btnEdSave')
        $eCancel = $edDlg.FindName('btnEdCancel')

        if ($isEdit) {
            $eName.Text  = $ExistingServer.Name
            $eSrv.Text   = $ExistingServer.ServerName
            $eShare.Text = $ExistingServer.RootShare
            $eDesc.Text  = $ExistingServer.Description
            foreach ($ci in $eCat.Items) {
                if ($ci.Content -eq $ExistingServer.Category) { $eCat.SelectedItem = $ci; break }
            }
        }

        # Auto-fill share from server name
        $eSrv.Add_TextChanged({
            if ($eShare.Text -eq '' -or $eShare.Text -eq "\\$($eSrv.Text)\D`$") {
                $eShare.Text = "\\$($eSrv.Text)\D`$"
            }
        })

        $eSave.Add_Click({
            if ([string]::IsNullOrWhiteSpace($eName.Text) -or [string]::IsNullOrWhiteSpace($eSrv.Text) -or [string]::IsNullOrWhiteSpace($eShare.Text)) {
                [System.Windows.MessageBox]::Show('Name, Server Name, and Root Share are required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $edDlg.Tag = @{
                Name        = $eName.Text.Trim()
                ServerName  = $eSrv.Text.Trim()
                RootShare   = $eShare.Text.Trim()
                Category    = ($eCat.SelectedItem).Content
                Description = $eDesc.Text.Trim()
            }
            $edDlg.DialogResult = $true
        })

        $eCancel.Add_Click({ $edDlg.DialogResult = $false })

        if ($edDlg.ShowDialog() -eq $true) {
            return $edDlg.Tag
        }
        return $null
    }

    # ── Favorites update ──────────────────────────────────────────────
    function _RefreshFavoriteServers {
        $lstFavServers.Items.Clear()
        foreach ($fav in Get-FavoriteServers) {
            $item = [System.Windows.Controls.ListBoxItem]::new()
            $item.Content = "[*]  $fav"
            $item.Tag     = $fav
            $item.FontSize = 11
            $null = $lstFavServers.Items.Add($item)
        }
    }

    function _RefreshRecentActivity {
        $lstRecentActivity.Items.Clear()
        $recentSearches = @(Get-RecentSearches | Select-Object -First 5)
        $recentFiles    = @(Get-RecentFiles    | Select-Object -First 5)
        $recentServers  = @(Get-RecentServers  | Select-Object -First 5)

        foreach ($s in $recentSearches) {
            $item = [System.Windows.Controls.ListBoxItem]::new()
            $item.Content = "[>]  $s"
            $item.FontSize = 10
            $null = $lstRecentActivity.Items.Add($item)
        }
        foreach ($f in $recentFiles) {
            $item = [System.Windows.Controls.ListBoxItem]::new()
            $item.Content = "[F]  $(Split-Path $f -Leaf)"
            $item.ToolTip = $f
            $item.Tag     = $f
            $item.FontSize = 10
            $null = $lstRecentActivity.Items.Add($item)
        }
    }

    # ── Search engine integration ─────────────────────────────────────
    function _StartSearch {
        $searchText = $txtSearch.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($searchText)) { return }

        # Determine scope
        $scopeText = ($cmbSearchScope.SelectedItem).Content
        $servers   = switch ($scopeText) {
            'All Servers'       { Get-Servers }
            'Current Server'    { if ($script:MW_CurrentServer) { @($script:MW_CurrentServer) } else { Get-Servers } }
            'Current Category'  { if ($script:MW_CurrentServer) { Get-Servers -Category $script:MW_CurrentServer.Category } else { Get-Servers } }
            'PVWA Servers'      { Get-Servers -Category 'PVWA' }
            'CPM Servers'       { Get-Servers -Category 'CPM' }
            'PSM Servers'       { Get-Servers -Category 'PSM' }
            'PTA Servers'       { Get-Servers -Category 'PTA' }
            default             { Get-Servers }
        }

        if (-not $servers -or $servers.Count -eq 0) {
            [System.Windows.MessageBox]::Show('No servers in scope. Add servers first.', 'Search', 'OK', 'Information') | Out-Null
            return
        }

        $maxSizeMap = @{ 'No limit' = 0; '1 MB' = 1MB; '10 MB' = 10MB; '50 MB' = 50MB; '100 MB' = 100MB }
        $maxSize    = $maxSizeMap[($cmbMaxFileSize.SelectedItem).Content]
        $pattern    = if ($txtFilePattern.Text.Trim()) { $txtFilePattern.Text.Trim() } else { '*' }

        $script:MW_SearchResults.Clear()
        $dgSearchResults.Items.Clear()
        $lblResultCount.Text = 'Searching...'
        $btnSearch.Visibility    = 'Collapsed'
        $btnStopSearch.Visibility = 'Visible'
        & $setProgress $true "Searching '$searchText'..."

        Add-RecentSearch -SearchText $searchText

        $searchParams = @{
            SearchText      = $searchText
            Credential      = $script:MW_Cred
            Servers         = @($servers)
            FilePattern     = $pattern
            CaseSensitive   = $chkCaseSensitive.IsChecked
            SearchFileNames = $chkSearchFileNames.IsChecked
            MaxFileSizeBytes = $maxSize
        }

        Start-GlobalSearch @searchParams

        # Poll results using a DispatcherTimer
        $pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $pollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:MW_SearchTimer = $pollTimer

        $pollTimer.Add_Tick({
            $results = Get-SearchResults -MaxItems 100
            foreach ($r in $results) {
                $script:MW_SearchResults.Add($r)
                $null = $dgSearchResults.Items.Add($r)
            }

            $status = Get-SearchStatus
            $lblResultCount.Text = "$($script:MW_SearchResults.Count) result(s)"
            & $setProgress $true "$($status.Completed)/$($status.Total) servers searched"
            $sbSearchStatus.Text = "Searching: $($status.Completed)/$($status.Total)"

            if (-not $status.IsRunning) {
                $pollTimer.Stop()
                $btnSearch.Visibility     = 'Visible'
                $btnStopSearch.Visibility = 'Collapsed'
                & $setProgress $false
                $sbSearchStatus.Text = "Search complete - $($script:MW_SearchResults.Count) results"
                Write-NexusLog "Search complete: $($script:MW_SearchResults.Count) results for '$searchText'" -Level INFO -Component 'MainWindow'
            }
        })

        $pollTimer.Start()
        Write-NexusLog "Search started: '$searchText' scope=$scopeText servers=$($servers.Count)" -Level INFO -Component 'MainWindow'
    }

    # ── Wire up all events ────────────────────────────────────────────

    # Server filter
    $txtServerFilter.Add_TextChanged({ _BuildServerTree -Filter $txtServerFilter.Text })

    # Favorite servers list click
    $lstFavServers.Add_MouseDoubleClick({
        $sel = $lstFavServers.SelectedItem
        if ($sel -and $sel.Tag) {
            $srv = Get-ServerByName -Name $sel.Tag
            if ($srv) { _SelectServer -Server $srv }
        }
    })

    # Navigation buttons
    $btnNavUp.Add_Click({
        if ($script:MW_CurrentPath) {
            $parent = Split-Path $script:MW_CurrentPath -Parent
            if ($parent -and $parent -ne $script:MW_CurrentPath) {
                $script:MW_NavHistory.Push($script:MW_CurrentPath)
                $script:MW_CurrentPath = $parent
                $txtCurrentPath.Text   = $parent
                _LoadFileList -Path $parent
            }
        }
    })

    $btnNavBack.Add_Click({
        if ($script:MW_NavHistory.Count -gt 0) {
            $prev = $script:MW_NavHistory.Pop()
            $script:MW_CurrentPath = $prev
            $txtCurrentPath.Text   = $prev
            _LoadFileList -Path $prev
        }
    })

    $btnGoPath.Add_Click({
        $path = $txtCurrentPath.Text.Trim()
        if ($path) {
            $script:MW_NavHistory.Push($script:MW_CurrentPath)
            $script:MW_CurrentPath = $path
            _LoadFileList -Path $path
        }
    })

    $txtCurrentPath.Add_KeyDown({
        param($s,$e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            $btnGoPath.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
    })

    $btnBrowsePath.Add_Click({ _OpenPathBrowser })
    $mnuBrowsePath.Add_Click({ _OpenPathBrowser })

    $btnSaveFavPath.Add_Click({
        $path = $txtCurrentPath.Text.Trim()
        if ($path) {
            $name = [Microsoft.VisualBasic.Interaction]::InputBox("Enter a name for this favorite path:`n`n$path", 'Save Favorite Path', (Split-Path $path -Leaf))
            if ($name) {
                Add-FavoriteFolder -Name $name -Path $path
                [System.Windows.MessageBox]::Show("Path saved as favorite: '$name'", 'Saved', 'OK', 'Information') | Out-Null
            }
        }
    })

    # File list double-click → open
    $dgFiles.Add_MouseDoubleClick({
        $sel = $dgFiles.SelectedItem
        if ($sel) {
            if ($sel.IsDirectory) {
                $script:MW_NavHistory.Push($script:MW_CurrentPath)
                $script:MW_CurrentPath = $sel.FullUNCPath
                $txtCurrentPath.Text   = $sel.FullUNCPath
                _LoadFileList -Path $sel.FullUNCPath
            } elseif ($sel.IsViewable) {
                _OpenLogFile -FilePath $sel.FullUNCPath
            }
        }
    })

    $btnRefreshFiles.Add_Click({ _LoadFileList -Path $script:MW_CurrentPath })
    $btnOpenFile.Add_Click({
        $sel = $dgFiles.SelectedItem
        if ($sel -and $sel.IsViewable) { _OpenLogFile -FilePath $sel.FullUNCPath }
    })

    $btnCopyPath.Add_Click({
        if ($script:MW_CurrentPath) {
            [System.Windows.Clipboard]::SetText($script:MW_CurrentPath)
        }
    })

    # Search
    $txtSearch.Add_TextChanged({
        $lblSrchPlaceholder.Visibility = if ($txtSearch.Text -eq '') { 'Visible' } else { 'Collapsed' }
    })

    $txtSearch.Add_KeyDown({
        param($s,$e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) { _StartSearch }
    })

    $btnSearch.Add_Click({ _StartSearch })
    $mnuSearchAll.Add_Click({ $cmbSearchScope.SelectedIndex = 0; _StartSearch })
    $mnuSearchCurrent = $w.FindName('mnuSearchCurrent')
    $mnuSearchCurrent.Add_Click({ $cmbSearchScope.SelectedIndex = 2; _StartSearch })
    $mnuSearchCategory = $w.FindName('mnuSearchCategory')
    $mnuSearchCategory.Add_Click({ $cmbSearchScope.SelectedIndex = 1; _StartSearch })

    $btnStopSearch.Add_Click({
        Stop-GlobalSearch
        if ($script:MW_SearchTimer) { $script:MW_SearchTimer.Stop() }
        $btnSearch.Visibility     = 'Visible'
        $btnStopSearch.Visibility = 'Collapsed'
        & $setProgress $false
        $sbSearchStatus.Text = 'Search cancelled'
    })

    # Double-click search result → open file at line
    $dgSearchResults.Add_MouseDoubleClick({
        $sel = $dgSearchResults.SelectedItem
        if ($sel -and $sel.LineNumber -gt 0) {
            _OpenLogFile -FilePath $sel.FilePath -JumpToLine $sel.LineNumber -HighlightText $txtSearch.Text.Trim()
        }
    })

    # Export search results
    $btnExportResults.Add_Click({
        $mnuExportResults.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    })

    $mnuExportResults.Add_Click({
        if ($script:MW_SearchResults.Count -eq 0) {
            [System.Windows.MessageBox]::Show('No results to export.', 'Export', 'OK', 'Information') | Out-Null
            return
        }
        $dlg = [Microsoft.Win32.SaveFileDialog]::new()
        $dlg.Filter   = 'CSV Files (*.csv)|*.csv'
        $dlg.FileName = "SAW_SearchResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        if ($dlg.ShowDialog()) {
            $script:MW_SearchResults | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.MessageBox]::Show("Results exported to:`n$($dlg.FileName)", 'Export Complete', 'OK', 'Information') | Out-Null
        }
    })

    $btnCopyResults.Add_Click({
        $sel = $dgSearchResults.SelectedItem
        if ($sel) {
            [System.Windows.Clipboard]::SetText("$($sel.ServerName) | $($sel.FilePath) | Line $($sel.LineNumber) | $($sel.LineText)")
        }
    })

    # Log viewer toolbar
    $btnWordWrap.Add_Click({
        $script:MW_WordWrap = -not $script:MW_WordWrap
        $wrapLabel = if ($script:MW_WordWrap) { 'Wrap [ON]' } else { 'Wrap' }
        $btnWordWrap.Content = $wrapLabel
    })

    $btnLogRefresh.Add_Click({
        $selTab = $tabLogViewer.SelectedItem
        if ($selTab -and $selTab.Tag -is [string] -and $selTab.Tag -ne '') {
            _OpenLogFile -FilePath $selTab.Tag
        }
    })

    $btnLogCopy.Add_Click({
        $selTab = $tabLogViewer.SelectedItem
        if ($selTab -and $selTab.Content -is [System.Windows.Controls.Grid]) {
            $grid = @($selTab.Content.Children | Where-Object { $_ -is [System.Windows.Controls.DataGrid] }) | Select-Object -First 1
            if ($grid -and $grid.SelectedItem) {
                [System.Windows.Clipboard]::SetText($grid.SelectedItem.Text)
            }
        }
    })

    $btnLogTail.Add_Click({
        $selTab = $tabLogViewer.SelectedItem
        if ($selTab -and $selTab.Tag -is [string]) {
            $filePath = $selTab.Tag
            $cred     = $script:MW_Cred
            $dispatcher = $w.Dispatcher

            $thread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
                try {
                    $tail = Get-LogTail -UNCFilePath $filePath -Credential $cred -Lines 500
                    $dispatcher.Invoke([System.Action]{
                        _AddLogTab -FilePath $filePath -FileName "$(Split-Path $filePath -Leaf) [tail]" `
                                   -Content $tail -JumpToLine $tail.EndLine
                    })
                } catch { }
            })
            $thread.IsBackground = $true
            $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
            $thread.Start()
        }
    })

    # Recent activity double-click
    $lstRecentActivity.Add_MouseDoubleClick({
        $sel = $lstRecentActivity.SelectedItem
        if ($sel -and $sel.Tag) {
            _OpenLogFile -FilePath $sel.Tag
        }
    })

    # Server management buttons/menus
    $btnAddServer.Add_Click({ $mnuAddServer.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent)) })
    $btnRefreshServers.Add_Click({ _BuildServerTree })

    $mnuAddServer.Add_Click({
        $newSrv = _ShowServerEditor
        if ($newSrv) {
            try {
                $null = Add-Server @newSrv
                _BuildServerTree
        [System.Windows.MessageBox]::Show(
            "Server '$($newSrv.Name)' added.",
            'Success', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
            }
        }
    })

    $mnuEditServer.Add_Click({
        if (-not $script:MW_CurrentServer) {
            [System.Windows.MessageBox]::Show('Please select a server first.', 'Edit Server', 'OK', 'Warning') | Out-Null
            return
        }
        $updated = _ShowServerEditor -ExistingServer $script:MW_CurrentServer
        if ($updated) {
            try {
                Update-Server -OriginalName $script:MW_CurrentServer.Name -Updated $updated
                $script:MW_CurrentServer = Get-ServerByName -Name $updated.Name
                _BuildServerTree
                [System.Windows.MessageBox]::Show("Server updated.", 'Success', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
            }
        }
    })

    $mnuDeleteServer.Add_Click({
        if (-not $script:MW_CurrentServer) {
            [System.Windows.MessageBox]::Show('Please select a server first.', 'Delete Server', 'OK', 'Warning') | Out-Null
            return
        }
        $confirm = [System.Windows.MessageBox]::Show(
            "Delete server '$($script:MW_CurrentServer.Name)'?`n`nThis cannot be undone.",
            'Confirm Delete', 'YesNo', 'Warning')
        if ($confirm -eq 'Yes') {
            try {
                Remove-Server -Name $script:MW_CurrentServer.Name
                $script:MW_CurrentServer = $null
                _BuildServerTree
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
            }
        }
    })

    $mnuTestConn.Add_Click({
        if (-not $script:MW_CurrentServer) {
            [System.Windows.MessageBox]::Show('Please select a server first.', 'Test Connection', 'OK', 'Warning') | Out-Null
            return
        }
        & $setProgress $true "Testing connection to $($script:MW_CurrentServer.Name)..."
        $srv  = $script:MW_CurrentServer
        $cred = $script:MW_Cred
        $disp = $w.Dispatcher

        $thread = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
            $ok = Test-ServerConnection -Server $srv -Credential $cred
            $disp.Invoke([System.Action]{
                & $setProgress $false
                if ($ok) {
                    [System.Windows.MessageBox]::Show("[OK] Connected to $($srv.RootShare)", 'Connection OK', 'OK', 'Information') | Out-Null
                } else {
                    [System.Windows.MessageBox]::Show("[FAIL] Cannot reach $($srv.RootShare)", 'Connection Failed', 'OK', 'Error') | Out-Null
                }
            })
        })
        $thread.IsBackground = $true
        $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
        $thread.Start()
    })

    $mnuImport.Add_Click({
        $dlg = [Microsoft.Win32.OpenFileDialog]::new()
        $dlg.Filter = 'JSON Files (*.json)|*.json'
        if ($dlg.ShowDialog()) {
            try {
                Import-ServerConfig -FilePath $dlg.FileName
                _BuildServerTree
                [System.Windows.MessageBox]::Show("Servers imported successfully.", 'Import', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Import Error', 'OK', 'Error') | Out-Null
            }
        }
    })

    $mnuExport.Add_Click({
        $dlg = [Microsoft.Win32.SaveFileDialog]::new()
        $dlg.Filter   = 'JSON Files (*.json)|*.json'
        $dlg.FileName = "Servers_$(Get-Date -Format 'yyyyMMdd').json"
        if ($dlg.ShowDialog()) {
            Export-ServerConfig -FilePath $dlg.FileName
            [System.Windows.MessageBox]::Show("Servers exported.", 'Export', 'OK', 'Information') | Out-Null
        }
    })

    $mnuClearHistory.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show('Clear all recent history?', 'Clear History', 'YesNo', 'Warning')
        if ($confirm -eq 'Yes') {
            _RefreshRecentActivity
        }
    })

    $mnuAbout.Add_Click({
        [System.Windows.MessageBox]::Show(
            "Server Access Workbench (SAW)`n`nCyberArk Operations Console`nVersion 1.0.0`n`nAuthenticated: $($Credential.UserName)`n`nCredentials: In-memory only - never stored",
            'About SAW', 'OK', 'Information') | Out-Null
    })

    $mnuOpenLog.Add_Click({
        $logFile = Join-Path $script:LogDir "SAW_$(Get-Date -Format 'yyyyMMdd').log"
        if (Test-Path $logFile) {
            Start-Process notepad.exe $logFile
        } else {
            [System.Windows.MessageBox]::Show('Log file not found.', 'App Log', 'OK', 'Information') | Out-Null
        }
    })

    $mnuExit.Add_Click({ $w.Close() })

    # Clean up on close
    $w.Add_Closing({
        Stop-GlobalSearch -Quiet
        if ($script:MW_SearchTimer) { $script:MW_SearchTimer.Stop() }
        Write-NexusLog 'Application window closing' -Level INFO -Component 'MainWindow'
    })

    # ── Initialize UI data ────────────────────────────────────────────
    $sbUser.Text = "Authenticated as: $($Credential.UserName)"
    Initialize-FileExplorer -ConfigDirectory $script:ConfigDir
    _BuildServerTree
    _RefreshFavoriteServers
    _RefreshRecentActivity

    Write-NexusLog 'Main window loaded' -Level INFO -Component 'MainWindow'

    # ── Show window ───────────────────────────────────────────────────
    $w.ShowDialog() | Out-Null
}
