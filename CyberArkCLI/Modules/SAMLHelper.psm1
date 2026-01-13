function Ensure-WebView2Dependencies {
    $libPath = Join-Path $PSScriptRoot "..\..\Lib"
    if (-not (Test-Path $libPath)) {
        New-Item -ItemType Directory -Path $libPath -Force | Out-Null
    }

    $dlls = @(
        "Microsoft.Web.WebView2.Core.dll",
        "Microsoft.Web.WebView2.WinForms.dll",
        "WebView2Loader.dll"
    )

    $missing = $false
    foreach ($dll in $dlls) {
        if (-not (Test-Path (Join-Path $libPath $dll))) {
            $missing = $true
            break
        }
    }

    if ($missing) {
        Write-Host "Downloading WebView2 dependencies..." -ForegroundColor Cyan
        $pkgName = "Microsoft.Web.WebView2"
        $pkgVersion = "1.0.1264.42"
        $url = "https://www.nuget.org/api/v2/package/$pkgName/$pkgVersion"
        $zipPath = Join-Path $libPath "webview2.zip"

        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -ErrorAction Stop
        
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $extractPath = Join-Path $libPath "temp_extract"
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)

            $net45 = Join-Path $extractPath "lib\net45"
            Copy-Item (Join-Path $net45 "Microsoft.Web.WebView2.Core.dll") -Destination $libPath -Force
            Copy-Item (Join-Path $net45 "Microsoft.Web.WebView2.WinForms.dll") -Destination $libPath -Force
            
            $runtimes = Join-Path $extractPath "runtimes\win-x64\native"
            Copy-Item (Join-Path $runtimes "WebView2Loader.dll") -Destination $libPath -Force

            Remove-Item $zipPath -Force
            Remove-Item $extractPath -Recurse -Force
            
            Write-Host "WebView2 dependencies downloaded." -ForegroundColor Green
        }
        catch {
            throw "Failed to download WebView2 dependencies: $($_.Exception.Message)"
        }
    }

    try {
        Add-Type -Path (Join-Path $libPath "Microsoft.Web.WebView2.Core.dll")
        Add-Type -Path (Join-Path $libPath "Microsoft.Web.WebView2.WinForms.dll")
    }
    catch {
        throw "Failed to load WebView2 assemblies: $($_.Exception.Message)"
    }
}

function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Begin {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }

    Process {
        # Create a simple form with instructions
        $form = New-Object System.Windows.Forms.Form
        $form.Text = "CyberArk SAML Authentication"
        $form.Size = New-Object System.Drawing.Size(600, 400)
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true

        # Instructions label
        $label = New-Object System.Windows.Forms.Label
        $label.Location = New-Object System.Drawing.Point(10, 10)
        $label.Size = New-Object System.Drawing.Size(560, 120)
        $label.Text = @"
INSTRUCTIONS:
1. A browser window will open for SAML authentication
2. Complete your login in the browser
3. After successful login, the browser will redirect to CyberArk
4. Press F12 to open Developer Tools
5. Go to the Network tab
6. Look for the POST request to: /PasswordVault/api/auth/saml/logon
7. Click on that request and go to the 'Request' or 'Payload' tab
8. Copy the entire SAMLResponse value (it will be a long encoded string)
9. Paste it in the text box below
"@
        $label.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
        $form.Controls.Add($label)

        # Text box for SAML response
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(10, 140)
        $textBox.Size = New-Object System.Drawing.Size(560, 100)
        $textBox.Multiline = $true
        $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $textBox.Font = New-Object System.Drawing.Font("Consolas", 8)
        $form.Controls.Add($textBox)

        # Status label
        $statusLabel = New-Object System.Windows.Forms.Label
        $statusLabel.Location = New-Object System.Drawing.Point(10, 250)
        $statusLabel.Size = New-Object System.Drawing.Size(560, 20)
        $statusLabel.Text = "Waiting for SAML response..."
        $form.Controls.Add($statusLabel)

        # Buttons
        $okButton = New-Object System.Windows.Forms.Button
        $okButton.Location = New-Object System.Drawing.Point(400, 280)
        $okButton.Size = New-Object System.Drawing.Size(80, 30)
        $okButton.Text = "OK"
        $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($okButton)

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Location = New-Object System.Drawing.Point(490, 280)
        $cancelButton.Size = New-Object System.Drawing.Size(80, 30)
        $cancelButton.Text = "Cancel"
        $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($cancelButton)

        # Open browser button
        $browserButton = New-Object System.Windows.Forms.Button
        $browserButton.Location = New-Object System.Drawing.Point(10, 280)
        $browserButton.Size = New-Object System.Drawing.Size(120, 30)
        $browserButton.Text = "Open Browser"
        $browserButton.Add_Click({
            Write-Host "Opening browser to: $LoginIDP" -ForegroundColor Cyan
            Start-Process $LoginIDP
            $statusLabel.Text = "Browser opened. Complete authentication..."
        })
        $form.Controls.Add($browserButton)

        # Set form properties
        $form.AcceptButton = $okButton
        $form.CancelButton = $cancelButton

        # Open browser automatically
        Write-Host "Opening browser for SAML authentication..." -ForegroundColor Cyan
        Write-Host "URL: $LoginIDP" -ForegroundColor Gray
        Start-Process $LoginIDP

        # Show the form
        $result = $form.ShowDialog()

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $samlResponse = $textBox.Text.Trim()
            
            if ([string]::IsNullOrWhiteSpace($samlResponse)) {
                throw "No SAML response provided"
            }

            # Clean up the SAML response (remove quotes, trim)
            $samlResponse = $samlResponse.Trim('"', "'").Trim()
            
            # Validate it looks like a SAML response
            if ($samlResponse -match "^[A-Za-z0-9+/]+={0,2}$") {
                Write-Host "SAML response captured successfully" -ForegroundColor Green
                return $samlResponse
            }
            else {
                Write-Warning "The entered text doesn't look like a valid SAML response"
                Write-Host "Make sure you copied only the SAMLResponse value (not the entire POST data)" -ForegroundColor Yellow
                throw "Invalid SAML response format"
            }
        }
        else {
            throw "SAML authentication cancelled by user"
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive