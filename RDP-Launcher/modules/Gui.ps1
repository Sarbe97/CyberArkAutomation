param(
    [string[]]$Addresses,
    [string]$SavedUsername,
    [string]$SavedTargetAccount,
    [string[]]$Connectors
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# === FORM ==========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "RDP Launcher"
$form.BackColor = "WhiteSmoke"
$form.Size = New-Object System.Drawing.Size(450, 420)
$form.StartPosition = "CenterScreen"

# Common sizes for controls
$fontStyle = "Verdana"
$fieldFontSize = 12
$labelFontSize = 10
$labelWidth = 140
$labelHeight = 25
$fieldWidth = 200
$fieldHeight = 27
$comboHeight = 34

$startX_Label = 20
$startX_Field = 170

$currentY = 70
$gapY = 45

# === TITLE =========================================================
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "RDP Launcher"
$lblTitle.Font = New-Object System.Drawing.Font($fontStyle, 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = "SteelBlue"
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(130, 20)
$form.Controls.Add($lblTitle)

# === USERNAME ======================================================
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.TextAlign = "MiddleRight"
$lblUser.Text = "Username"
$lblUser.Size = New-Object System.Drawing.Size($labelWidth, $labelHeight)
$lblUser.Font = New-Object System.Drawing.Font($fontStyle, $labelFontSize)
$lblUser.Location = New-Object System.Drawing.Point($startX_Label, $currentY)
$form.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point($startX_Field, $currentY)
$txtUser.Size = New-Object System.Drawing.Size($fieldWidth, $fieldHeight)
$txtUser.Font = New-Object System.Drawing.Font($fontStyle, $fieldFontSize)
$txtUser.Text = $SavedUsername
$form.Controls.Add($txtUser)

$currentY += $gapY

# === TARGET ACCOUNT ===============================================
$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.TextAlign = "MiddleRight"
$lblTarget.Text = "Target Account"
$lblTarget.Size = New-Object System.Drawing.Size($labelWidth, $labelHeight)
$lblTarget.Font = New-Object System.Drawing.Font($fontStyle, $labelFontSize)
$lblTarget.Location = New-Object System.Drawing.Point($startX_Label, $currentY)
$form.Controls.Add($lblTarget)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point($startX_Field, $currentY)
$txtTarget.Size = New-Object System.Drawing.Size($fieldWidth, $fieldHeight)
$txtTarget.Font = New-Object System.Drawing.Font($fontStyle, $fieldFontSize)
$txtTarget.Text = $SavedTargetAccount
$form.Controls.Add($txtTarget)

$currentY += $gapY

# === TARGET ADDRESS ===============================================
$lblAddr = New-Object System.Windows.Forms.Label
$lblAddr.TextAlign = "MiddleRight"
$lblAddr.Text = "Target Address"
$lblAddr.Size = New-Object System.Drawing.Size($labelWidth, $labelHeight)
$lblAddr.Font = New-Object System.Drawing.Font($fontStyle, $labelFontSize)
$lblAddr.Location = New-Object System.Drawing.Point($startX_Label, $currentY)
$form.Controls.Add($lblAddr)

$cbAddr = New-Object System.Windows.Forms.ComboBox
$cbAddr.Location = New-Object System.Drawing.Point($startX_Field, $currentY)
$cbAddr.Size = New-Object System.Drawing.Size($fieldWidth, $comboHeight)
$cbAddr.Font = New-Object System.Drawing.Font($fontStyle, $fieldFontSize)
$cbAddr.DropDownStyle = "DropDown"

if ($Addresses) {
    $cbAddr.Items.AddRange($Addresses)
}

# Auto-fill alias when picking from dropdown
$cbAddr.add_SelectedIndexChanged({
    if ($cbAddr.SelectedItem) {
        $sel = $cbAddr.SelectedItem.ToString()
        $txtAlias.Text = ($sel -split " - " | Select-Object -Last 1)
    }
})

$form.Controls.Add($cbAddr)

$currentY += $gapY

# === ALIAS =========================================================
$lblAlias = New-Object System.Windows.Forms.Label
$lblAlias.TextAlign = "MiddleRight"
$lblAlias.Text = "Alias"
$lblAlias.Size = New-Object System.Drawing.Size($labelWidth, $labelHeight)
$lblAlias.Font = New-Object System.Drawing.Font($fontStyle, $labelFontSize)
$lblAlias.Location = New-Object System.Drawing.Point($startX_Label, $currentY)
$form.Controls.Add($lblAlias)

$txtAlias = New-Object System.Windows.Forms.TextBox
$txtAlias.Location = New-Object System.Drawing.Point($startX_Field, $currentY)
$txtAlias.Size = New-Object System.Drawing.Size($fieldWidth, $fieldHeight)
$txtAlias.Font = New-Object System.Drawing.Font($fontStyle, $fieldFontSize)
$form.Controls.Add($txtAlias)

$currentY += $gapY

# === CONNECTOR =====================================================
$lblConnector = New-Object System.Windows.Forms.Label
$lblConnector.TextAlign = "MiddleRight"
$lblConnector.Text = "Connector:"
$lblConnector.Size = New-Object System.Drawing.Size($labelWidth, $labelHeight)
$lblConnector.Font = New-Object System.Drawing.Font($fontStyle, $labelFontSize)
$lblConnector.Location = New-Object System.Drawing.Point($startX_Label, $currentY)
$form.Controls.Add($lblConnector)

$cbConnector = New-Object System.Windows.Forms.ComboBox
$cbConnector.Location = New-Object System.Drawing.Point($startX_Field, $currentY)
$cbConnector.Size = New-Object System.Drawing.Size($fieldWidth, $comboHeight)
$cbConnector.Font = New-Object System.Drawing.Font($fontStyle, $fieldFontSize)
$cbConnector.DropDownStyle = "DropDownList"

if ($Connectors) {
    $cbConnector.Items.AddRange($Connectors)
    $cbConnector.SelectedIndex = 0
}
$form.Controls.Add($cbConnector)

$currentY += 40

# === VALIDATION LABEL =============================================
$lblError = New-Object System.Windows.Forms.Label
$lblError.ForeColor = "Red"
$lblError.Font = New-Object System.Drawing.Font($fontStyle, 9, [System.Drawing.FontStyle]::Bold)
$lblError.AutoSize = $true
$lblError.Location = New-Object System.Drawing.Point(40, $currentY)
$lblError.Text = ""
$form.Controls.Add($lblError)

$currentY += 40

# === CONNECT BUTTON ===============================================
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Font = New-Object System.Drawing.Font($fontStyle, 10, [System.Drawing.FontStyle]::Bold)
$btnConnect.ForeColor = "White"
$btnConnect.BackColor = "SeaGreen"
$btnConnect.FlatStyle = "Flat"
$btnConnect.Size = New-Object System.Drawing.Size(120, 38)
$btnConnect.Location = New-Object System.Drawing.Point(165, $currentY)

$btnConnect.Add_Click({

    # --- VALIDATION ----------------------------------------------
    if ([string]::IsNullOrWhiteSpace($txtUser.Text)) {
        $lblError.Text = "Username is required."
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtTarget.Text)) {
        $lblError.Text = "Target Account is required."
        return
    }

    if ([string]::IsNullOrWhiteSpace($cbAddr.Text)) {
        $lblError.Text = "Target Address is required."
        return
    }

    # Clear validation message
    $lblError.Text = ""

    # Trim address
    $addr = $cbAddr.Text
    if ($addr -match " - ") {
        $addr = $addr.Split(" - ")[0]
    }

    $form.Tag = @{
        Username      = $txtUser.Text
        TargetAccount = $txtTarget.Text
        Address       = $addr
        Alias         = $txtAlias.Text
        Connector     = $cbConnector.Text
    }
    $form.Close()
})
$form.Controls.Add($btnConnect)

# === SHOW ==========================================================
$form.ShowDialog() | Out-Null
return $form.Tag
