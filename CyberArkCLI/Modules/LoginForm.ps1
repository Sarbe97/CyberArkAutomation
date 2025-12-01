# LoginForm.psm1
Add-Type -AssemblyName System.Windows.Forms

function Show-CACLoginForm {
    param(
        [string]$PVWAURL
    )

    $needsUrl = [string]::IsNullOrWhiteSpace($PVWAURL)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CyberArk Login"
    $form.Width = 350
    $form.Height = $(if ($needsUrl) { 310 } else { 260 })
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $y = 20

    # Current URL
    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Left = 10
    $lblUrl.Top = $y
    $lblUrl.Width = 320
    $lblUrl.Text = if ($needsUrl) { "Current PVWA URL: Not Set" } else { "Current PVWA URL: $PVWAURL" }
    $form.Controls.Add($lblUrl)

    $y += 40

    if ($needsUrl) {
        $lblUrlEdit = New-Object System.Windows.Forms.Label
        $lblUrlEdit.Text = "Enter PVWA URL:"
        $lblUrlEdit.Left = 10
        $lblUrlEdit.Top = $y

        $txtUrl = New-Object System.Windows.Forms.TextBox
        $txtUrl.Left = 10
        $txtUrl.Top = $y + 20
        $txtUrl.Width = 300

        $form.Controls.Add($lblUrlEdit)
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

    # Login button
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Login"
    $btn.Left = 10
    $btn.Top = $y + 60
    $btn.Width = 100

    $btn.Add_Click({
            $form.Tag = @{
                Url      = if ($needsUrl) { $txtUrl.Text } else { $PVWAURL }
                Username = $txtUser.Text
                Password = $txtPass.Text
            }
            $form.Close()
        })

    $form.Controls.Add($btn)

    $form.ShowDialog() | Out-Null
    return $form.Tag
}

