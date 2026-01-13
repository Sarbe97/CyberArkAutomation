function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Begin {
        Add-Type -AssemblyName System.Windows.Forms 
        Add-Type -AssemblyName System.Web
        
        # Save page source to file for debugging
        $debugDir = Join-Path $env:TEMP "SAML_Debug"
        if (-not (Test-Path $debugDir)) {
            New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
        }
        $debugFile = Join-Path $debugDir "saml_debug_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    }

    Process {
        $Script:SAMLResponse = $null
        $formClosed = $false
        
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = "CenterScreen"
        $form.Width = 800
        $form.Height = 700
        $form.Text = "SAML DEBUG - Login will auto-close when SAML found"
        
        $web = New-Object System.Windows.Forms.WebBrowser
        $web.Dock = "Fill"
        $web.ScriptErrorsSuppressed = $true
        $form.Controls.Add($web)
        
        # DEBUG: Save every page load
        $web.add_DocumentCompleted({
                param($sender, $e)
            
                $url = $web.Url.ToString()
                Write-Host "DEBUG: Page loaded - $url" -ForegroundColor Cyan
            
                # Save page source to file
                try {
                    $pageSource = $web.DocumentText
                    if (-not [string]::IsNullOrWhiteSpace($pageSource)) {
                        $timestamp = Get-Date -Format "HH:mm:ss"
                        $divider = "`n`n" + ("=" * 80) + "`n"
                        $debugContent = "`n`n[$timestamp] URL: $url`n" + $divider + $pageSource
                        Add-Content -Path $debugFile -Value $debugContent -Encoding UTF8
                    
                        Write-Host "DEBUG: Page saved to $debugFile" -ForegroundColor DarkGray
                    
                        # Check for SAML in multiple ways
                        CheckForSAML -WebControl $web -PageSource $pageSource -Url $url
                    }
                }
                catch {
                    Write-Host "DEBUG: Failed to save page: $_" -ForegroundColor Red
                }
            })
        
        function CheckForSAML {
            param($WebControl, $PageSource, $Url)
            
            # Method 1: Check URL
            if ($Url -match "SAMLResponse=([^&]+)") {
                Write-Host "DEBUG: Found SAML in URL!" -ForegroundColor Green
                $Script:SAMLResponse = [System.Web.HttpUtility]::UrlDecode($Matches[1])
                $form.Close()
                return
            }
            
            # Method 2: Check HTML for SAMLResponse input
            try {
                $doc = $WebControl.Document
                if ($doc -ne $null) {
                    $inputs = $doc.GetElementsByTagName("input")
                    foreach ($input in $inputs) {
                        $name = $input.GetAttribute("name")
                        if ($name -eq "SAMLResponse") {
                            $value = $input.GetAttribute("value")
                            if (-not [string]::IsNullOrWhiteSpace($value)) {
                                Write-Host "DEBUG: Found SAML in input field!" -ForegroundColor Green
                                $Script:SAMLResponse = $value
                                $form.Close()
                                return
                            }
                        }
                    }
                }
            }
            catch {}
            
            # Method 3: Regex on page source
            $patterns = @(
                'name=["'']SAMLResponse["''][^>]*value=["'']([^"'']+)["'']',
                'value=["'']([^"'']+)["''][^>]*name=["'']SAMLResponse["'']',
                'SAMLResponse=([^&"''\s]+)'
            )
            
            foreach ($pattern in $patterns) {
                if ($PageSource -match $pattern) {
                    Write-Host "DEBUG: Found SAML with pattern: $pattern" -ForegroundColor Green
                    $Script:SAMLResponse = $Matches[1]
                    $Script:SAMLResponse = $Script:SAMLResponse -replace '&#x2b;', '+' -replace '&#x3d;', '='
                    $form.Close()
                    return
                }
            }
            
            Write-Host "DEBUG: No SAML found on this page" -ForegroundColor DarkGray
        }
        
        # Navigate
        Write-Host "DEBUG: Navigating to $LoginIDP" -ForegroundColor Yellow
        $web.Navigate($LoginIDP)
        
        # Show form
        [void]$form.ShowDialog()
        
        if ($Script:SAMLResponse) {
            Write-Host "SUCCESS: Got SAML response!" -ForegroundColor Green
            Write-Host "DEBUG file: $debugFile" -ForegroundColor DarkGray
            return $Script:SAMLResponse
        }
        else {
            Write-Host "FAILED: No SAML found" -ForegroundColor Red
            Write-Host "Check debug file: $debugFile" -ForegroundColor Yellow
            Write-Host "Look for any HTML forms with SAMLResponse" -ForegroundColor Yellow
            throw "No SAML response captured. Check debug file."
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive