Import-Module psPAS -ErrorAction Stop

function Invoke-CACLogin {
    Add-Type -AssemblyName System.Windows.Forms

    # Load config
    $cfg = Get-CACConfig
    $needsUrl = [string]::IsNullOrWhiteSpace($cfg.PVWAURL)

    # ---------- Build Form ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CyberArk Login"
    $form.Width = 350
    $form.Height = $(if ($needsUrl) { 310 } else { 260 })
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $y = 20

    # LABEL showing existing or missing URL
    $lblCurrentUrl = New-Object System.Windows.Forms.Label
    $lblCurrentUrl.Left = 10
    $lblCurrentUrl.Top = $y
    $lblCurrentUrl.Width = 320
    $lblCurrentUrl.Text = if ($needsUrl) {
        "Current PVWA URL: Not Set"
    }
    else {
        "Current PVWA URL: $($cfg.PVWAURL)"
    }

    $form.Controls.Add($lblCurrentUrl)

    $y += 40

    # PVWA URL TEXTBOX (only when missing)
    if ($needsUrl) {
        $lblUrl = New-Object System.Windows.Forms.Label
        $lblUrl.Text = "Enter PVWA URL:"
        $lblUrl.Left = 10
        $lblUrl.Top = $y

        $txtUrl = New-Object System.Windows.Forms.TextBox
        $txtUrl.Left = 10
        $txtUrl.Top = $y + 20
        $txtUrl.Width = 300

        $form.Controls.Add($lblUrl)
        $form.Controls.Add($txtUrl)

        $y += 70
    }

    # Username
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Left = 10
    $lblUser.Top = $y

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Left = 10
    $txtUser.Top = $y + 20
    $txtUser.Width = 300

    $form.Controls.Add($lblUser)
    $form.Controls.Add($txtUser)

    $y += 70

    # Password
    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Left = 10
    $lblPass.Top = $y

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Left = 10
    $txtPass.Top = $y + 20
    $txtPass.Width = 300
    $txtPass.PasswordChar = '*'

    $form.Controls.Add($lblPass)
    $form.Controls.Add($txtPass)

    # Login Button
    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text = "Login"
    $btnLogin.Left = 10
    $btnLogin.Top = $y + 60
    $btnLogin.Width = 100

    # ---------- LOGIN CLICK ----------
    $btnLogin.Add_Click({
            try {
                # FIRST RUN – USER MUST ENTER URL
                if ($needsUrl) {
                    if ([string]::IsNullOrWhiteSpace($txtUrl.Text)) {
                        [System.Windows.Forms.MessageBox]::Show("PVWA URL cannot be empty.") | Out-Null
                        return
                    }

                    # Save for future runs
                    Set-CACConfig -PVWAURL $txtUrl.Text
                    $cfg = Get-CACConfig
                }

                if ([string]::IsNullOrWhiteSpace($cfg.PVWAURL)) {
                    throw "PVWA URL is missing in config.json"
                }

                # Build credentials
                $secure = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential ($txtUser.Text, $secure)

                # ---------- MOCK LOGIN ----------
                if ($cfg.PVWAURL -eq "http://localhost:8080") {
                    Write-Host "Using Mock PVWA login at $($cfg.PVWAURL)..."

                    # Directly set a dummy token
                    $global:CACSessionToken = "MOCK_TOKEN_12345"

                    Write-Host "Mock login successful! Token: $global:CACSessionToken" -ForegroundColor Green
                    [System.Windows.Forms.MessageBox]::Show("Login successful (Mock)!") | Out-Null
                    $form.Close()
                }
                else {
                    # ---------- REAL LOGIN ----------
                    $global:CACSession = New-PASSession `
                        -Credential $cred `
                        -BaseURI $cfg.PVWAURL

                    [System.Windows.Forms.MessageBox]::Show("Login successful!") | Out-Null
                    $form.Close()
                }
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Login failed: $($_.Exception.Message)") | Out-Null
            }
        })

    $form.Controls.Add($btnLogin)
    $form.ShowDialog()
}

Export-ModuleMember -Function Invoke-CACLogin
