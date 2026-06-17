#========================================================================
# Auth.psm1 - Authentication Module
# SECURITY: Credentials held in [PSCredential] only. Never persisted.
# Default domain account format: NA\S123456
#========================================================================

function Show-LoginDialog {
    <#
    .SYNOPSIS  Displays the WPF login dialog and returns a PSCredential.
    .OUTPUTS   [System.Management.Automation.PSCredential] or $null if cancelled.
    #>
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [string]$DefaultUsername = 'NA\S123456',
        [string]$ErrorMessage    = ''
    )

    $xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Server Access Workbench"
    Height="400" Width="440"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    Background="#0D1117"
    FontFamily="Segoe UI">

    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="Background"       Value="#161B22"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#30363D"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="10,8"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="CaretBrush"       Value="#E2E8F0"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background"       Value="#161B22"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#30363D"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="10,8"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="CaretBrush"       Value="#E2E8F0"/>
        </Style>
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background"       Value="#238636"/>
            <Setter Property="Foreground"       Value="White"/>
            <Setter Property="BorderThickness"  Value="0"/>
            <Setter Property="Padding"          Value="0"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="FontWeight"       Value="SemiBold"/>
            <Setter Property="Cursor"           Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="0,10">
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
        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background"       Value="#21262D"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#30363D"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="0"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="Cursor"           Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="6" Padding="0,10">
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
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="130"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Header / Brand -->
        <Border Grid.Row="0" Background="#161B22">
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,12">
                <TextBlock Text="***" FontSize="36" HorizontalAlignment="Center"
                           Foreground="#F0883E" Margin="0,0,0,6"/>
                <TextBlock Text="Server Access Workbench" FontSize="17" FontWeight="Bold"
                           Foreground="#E2E8F0" HorizontalAlignment="Center"/>
                <TextBlock Text="CyberArk Operations Console" FontSize="11"
                           Foreground="#6E7681" HorizontalAlignment="Center" Margin="0,4,0,0"/>
            </StackPanel>
        </Border>

        <!-- Form -->
        <StackPanel Grid.Row="1" Margin="32,20,32,20">

            <TextBlock Text="PRIVILEGED ACCOUNT" Foreground="#6E7681" FontSize="11"
                       FontWeight="SemiBold" Margin="0,0,0,5"/>
            <TextBox x:Name="txtUsername" Margin="0,0,0,14"/>

            <TextBlock Text="PASSWORD" Foreground="#6E7681" FontSize="11"
                       FontWeight="SemiBold" Margin="0,0,0,5"/>
            <PasswordBox x:Name="pwdPassword" Margin="0,0,0,6"/>

            <TextBlock x:Name="lblError" Foreground="#F85149" FontSize="11"
                       Margin="0,4,0,12" TextWrapping="Wrap" Visibility="Collapsed"/>

            <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnCancel" Grid.Column="0" Content="Cancel"
                        Style="{StaticResource SecondaryBtn}"/>
                <Button x:Name="btnLogin"  Grid.Column="2" Content="Connect ->"
                        Style="{StaticResource PrimaryBtn}"/>
            </Grid>
        </StackPanel>
    </Grid>
</Window>
'@

    [xml]$xml   = $xaml
    $reader     = [System.Xml.XmlNodeReader]::new($xml)
    $dialog     = [Windows.Markup.XamlReader]::Load($reader)

    $txtUsername = $dialog.FindName('txtUsername')
    $pwdPassword = $dialog.FindName('pwdPassword')
    $lblError    = $dialog.FindName('lblError')
    $btnLogin    = $dialog.FindName('btnLogin')
    $btnCancel   = $dialog.FindName('btnCancel')

    # Pre-fill username
    $txtUsername.Text = $DefaultUsername

    # Show pre-set error if any (e.g. after failed auth)
    if ($ErrorMessage) {
        $lblError.Text       = $ErrorMessage
        $lblError.Visibility = 'Visible'
    }

    $dialog.Add_Loaded({ $pwdPassword.Focus() | Out-Null })

    # Enter key on password field triggers login
    $pwdPassword.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            $btnLogin.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
    })

    $btnLogin.Add_Click({
        $username = $txtUsername.Text.Trim()
        $secPwd   = $pwdPassword.SecurePassword

        if ([string]::IsNullOrWhiteSpace($username)) {
            $lblError.Text       = 'Please enter a username (e.g. NA\S123456).'
            $lblError.Visibility = 'Visible'
            return
        }
        if ($secPwd.Length -eq 0) {
            $lblError.Text       = 'Please enter a password.'
            $lblError.Visibility = 'Visible'
            return
        }

        $dialog.Tag = [System.Management.Automation.PSCredential]::new($username, $secPwd)
        $dialog.DialogResult = $true
    })

    $btnCancel.Add_Click({ $dialog.DialogResult = $false })

    if ($dialog.ShowDialog() -eq $true) {
        return $dialog.Tag
    }
    return $null
}

Export-ModuleMember -Function Show-LoginDialog
