# ============================================================================
# LoginForm.ps1
# DESCRIPTION: Windows Forms login dialog for standard authentication
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-CACLoginForm {
    <#
    .SYNOPSIS
        Shows a Windows Forms login dialog for standard CyberArk authentication.
    .OUTPUTS
        PSCustomObject with Url, Username, Password or $null if cancelled.
    #>
    [CmdletBinding()]
    param(
        [string]$PVWAURL = ""
    )

    # Create form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CyberArk Login"
    $form.Size = New-Object System.Drawing.Size(400, 250)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    # PVWA URL Label
    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = "PVWA URL:"
    $lblUrl.Location = New-Object System.Drawing.Point(20, 20)
    $lblUrl.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblUrl)

    # PVWA URL TextBox
    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(110, 18)
    $txtUrl.Size = New-Object System.Drawing.Size(250, 20)
    $txtUrl.Text = $PVWAURL
    $form.Controls.Add($txtUrl)

    # Username Label
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Location = New-Object System.Drawing.Point(20, 60)
    $lblUser.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblUser)

    # Username TextBox
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(110, 58)
    $txtUser.Size = New-Object System.Drawing.Size(250, 20)
    $form.Controls.Add($txtUser)

    # Password Label
    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Location = New-Object System.Drawing.Point(20, 100)
    $lblPass.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblPass)

    # Password TextBox
    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(110, 98)
    $txtPass.Size = New-Object System.Drawing.Size(250, 20)
    $txtPass.UseSystemPasswordChar = $true
    $form.Controls.Add($txtPass)

    # Login Button
    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text = "Login"
    $btnLogin.Location = New-Object System.Drawing.Point(110, 150)
    $btnLogin.Size = New-Object System.Drawing.Size(100, 30)
    $btnLogin.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $btnLogin
    $form.Controls.Add($btnLogin)

    # Cancel Button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(220, 150)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $btnCancel
    $form.Controls.Add($btnCancel)

    # Show form
    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $loginResult = [PSCustomObject]@{
            Url      = $txtUrl.Text.Trim()
            Username = $txtUser.Text.Trim()
            Password = $txtPass.Text
        }
        $form.Dispose()
        return $loginResult
    }
    else {
        $form.Dispose()
        return $null
    }
}
