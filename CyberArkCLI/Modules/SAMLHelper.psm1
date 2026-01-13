function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Begin {
        # Same regex pattern as the working example
        $RegEx = '(?i)name="SAMLResponse"(?: type="hidden")? value=\"(.*?)\"(?:.*)?\/>'
        
        Add-Type -AssemblyName System.Windows.Forms 
        Add-Type -AssemblyName System.Web
    }

    Process {
        # Create Script-level variable for SAML response
        $Script:SAMLResponse = $null
        
        # Create window for embedded browser
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Width = 640
        $form.Height = 700
        $form.ShowIcon = $false
        $form.TopMost = $true
    
        # Use the legacy WebBrowser control (NOT WebView2)
        $web = New-Object System.Windows.Forms.WebBrowser
        $web.Size = $form.ClientSize
        $web.Anchor = "Left,Top,Right,Bottom"
        $web.ScriptErrorsSuppressed = $true
        $form.Controls.Add($web)

        # Navigate to the IdP
        $web.Navigate($LoginIDP)
        
        # Monitor for SAML response during navigation
        $web.add_Navigating({
                param($sender, $e)
            
                # Check if current page contains SAMLResponse
                if ($web.DocumentText -match "SAMLResponse") {
                    # Cancel further navigation since we found what we need
                    $e.Cancel = $true

                    # Extract the SAMLResponse using regex
                    if ($web.DocumentText -match $RegEx) {
                        # Close the form
                        $form.Close()
                    
                        # Decode HTML entities (&#x2b; = +, &#x3d; = =)
                        $Script:SAMLResponse = $(($Matches[1] -replace '&#x2b;', '+') -replace '&#x3d;', '=')
                    }
                }
            })
        
        # Add additional check for DocumentCompleted event (sometimes needed)
        $web.add_DocumentCompleted({
                if ($web.DocumentText -match $RegEx) {
                    $form.Close()
                    $Script:SAMLResponse = $(($Matches[1] -replace '&#x2b;', '+') -replace '&#x3d;', '=')
                }
            })
    
        # Show browser window and wait for it to close
        Write-Host "Opening SAML authentication window..." -ForegroundColor Cyan
        Write-Host "Please complete login in the browser window" -ForegroundColor Yellow
        
        $form.Add_Shown({ $form.Activate() })
        [void]$form.ShowDialog()

        # Return the SAML response
        if ($null -ne $Script:SAMLResponse) {
            Write-Host "SAML response captured successfully!" -ForegroundColor Green
            return $Script:SAMLResponse
        }
        else {
            throw "SAMLResponse not found. Authentication may have failed or was cancelled."
        }
    }

    End {
        # Cleanup
        if ($form -ne $null) {
            $form.Dispose()
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive