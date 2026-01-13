function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Begin {
        Add-Type -AssemblyName System.Windows.Forms 
        Add-Type -AssemblyName System.Web
    }

    Process {
        $Script:SAMLResponse = $null
        
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = "CenterScreen"
        $form.Width = 800
        $form.Height = 700
        $form.Text = "SAML Login - Will auto-close"
        
        $web = New-Object System.Windows.Forms.WebBrowser
        $web.Dock = "Fill"
        $web.ScriptErrorsSuppressed = $true
        $form.Controls.Add($web)
        
        # Navigate to IdP
        Write-Host "Opening SAML login..." -ForegroundColor Cyan
        $web.Navigate($LoginIDP)
        
        # Monitor for SAML response
        $web.add_DocumentCompleted({
                param($sender, $e)
            
                $url = $web.Url.ToString()
                Write-Host "Page loaded: $url" -ForegroundColor DarkGray
            
                try {
                    # Method 1: Check DOM for SAMLResponse input field
                    $doc = $web.Document
                    if ($doc -ne $null) {
                        $inputs = $doc.GetElementsByTagName("input")
                        foreach ($input in $inputs) {
                            $name = $input.GetAttribute("name")
                            if ($name -eq "SAMLResponse") {
                                $value = $input.GetAttribute("value")
                                if (-not [string]::IsNullOrWhiteSpace($value)) {
                                    Write-Host "Found SAMLResponse in DOM!" -ForegroundColor Green
                                
                                    # CORRECT DECODING: First URL decode, then fix entities
                                    $decoded = [System.Web.HttpUtility]::UrlDecode($value)
                                    $decoded = $decoded -replace '&#x2b;', '+'
                                    $decoded = $decoded -replace '&#x3d;', '='
                                    $decoded = $decoded -replace '&#13;&#10;', ''
                                    $decoded = $decoded.Trim()
                                
                                    $Script:SAMLResponse = $decoded
                                    $form.Close()
                                    return
                                }
                            }
                        }
                    }
                
                    # Method 2: Check URL for SAMLResponse
                    if ($url -match "SAMLResponse=([^&]+)") {
                        Write-Host "Found SAMLResponse in URL!" -ForegroundColor Green
                    
                        $encodedSaml = $Matches[1]
                        # URL decode the SAML response
                        $decoded = [System.Web.HttpUtility]::UrlDecode($encodedSaml)
                        $decoded = $decoded -replace '\+', ' '
                        $decoded = $decoded.Trim()
                    
                        $Script:SAMLResponse = $decoded
                        $form.Close()
                        return
                    }
                
                    # Method 3: Check for form with SAMLResponse
                    if ($doc -ne $null) {
                        $forms = $doc.GetElementsByTagName("form")
                        foreach ($formElem in $forms) {
                            $action = $formElem.GetAttribute("action")
                            if ($action -match "PasswordVault.*saml.*logon") {
                                Write-Host "Found CyberArk SAML form!" -ForegroundColor Yellow
                            
                                # Look for SAMLResponse in this form
                                $formHtml = $formElem.OuterHtml
                                if ($formHtml -match 'name="SAMLResponse" value="([^"]+)"') {
                                    $value = $Matches[1]
                                    Write-Host "Extracted SAML from form HTML" -ForegroundColor Green
                                
                                    $decoded = [System.Web.HttpUtility]::UrlDecode($value)
                                    $decoded = $decoded -replace '&#x2b;', '+'
                                    $decoded = $decoded -replace '&#x3d;', '='
                                    $decoded = $decoded.Trim()
                                
                                    $Script:SAMLResponse = $decoded
                                    $form.Close()
                                    return
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Host "Error checking page: $_" -ForegroundColor Red
                }
            })
        
        # Also check when navigating
        $web.add_Navigating({
                param($sender, $e)
            
                $url = $e.Url.ToString()
                if ($url -match "SAMLResponse=([^&]+)") {
                    Write-Host "Intercepted SAML in navigation!" -ForegroundColor Green
                
                    $encodedSaml = $Matches[1]
                    $decoded = [System.Web.HttpUtility]::UrlDecode($encodedSaml)
                    $decoded = $decoded -replace '\+', ' '
                    $decoded = $decoded.Trim()
                
                    $Script:SAMLResponse = $decoded
                    $e.Cancel = $true
                    $form.Close()
                }
            })
        
        # Show and wait
        [void]$form.ShowDialog()
        
        if ($null -ne $Script:SAMLResponse) {
            Write-Host "SAML captured successfully!" -ForegroundColor Green
            Write-Host "SAML length: $($Script:SAMLResponse.Length) chars" -ForegroundColor DarkGray
            
            # Validate format
            if ($Script:SAMLResponse -match "^[A-Za-z0-9+/]+={0,2}$") {
                Write-Host "Format: Valid Base64" -ForegroundColor Green
            }
            else {
                Write-Host "Format: Not Base64 - may need different encoding" -ForegroundColor Yellow
            }
            
            return $Script:SAMLResponse
        }
        else {
            throw "No SAML response captured"
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive