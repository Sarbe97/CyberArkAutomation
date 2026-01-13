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
        Ensure-WebView2Dependencies
    }

    Process {
        # Create Script-level variable for SAML response
        $Script:SAMLResponse = $null
        
        # Create Form
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Width = 600
        $form.Height = 800
        $form.ShowIcon = $false
        $form.TopMost = $false 
        $form.Text = "CyberArk SAML Authentication"
        $form.Add_FormClosing({
                param($sender, $e)
                # If we don't have a SAML response yet and user closes window, cancel
                if (-not $Script:SAMLResponse) {
                    Write-Warning "Authentication cancelled by user"
                }
            })

        # CREATE WEBVIEW2 CONTROL
        $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $webView.Dock = [System.Windows.Forms.DockStyle]::Fill
        $form.Controls.Add($webView)

        # Initialize WebView2 properly with async pattern
        $initTask = $webView.EnsureCoreWebView2Async($null)
        
        # Wait for initialization
        while (-not $initTask.IsCompleted) { 
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100 
        }

        if ($initTask.IsFaulted) {
            $form.Dispose()
            throw "WebView2 Initialization Failed: $($initTask.Exception.InnerException.Message)"
        }

        # Set up event handlers BEFORE navigating
        $webView.CoreWebView2.add_NavigationCompleted({
                param($sender, $e)
            
                if ($e.IsSuccess) {
                    Write-Host "Navigation completed to: $($sender.Source)" -ForegroundColor Gray
                
                    # Check if we're on a CyberArk callback URL (common patterns)
                    $currentUrl = $sender.Source.ToString()
                    if ($currentUrl -like "*PasswordVault/api/auth/saml/logon*") {
                        Write-Host "Detected CyberArk SAML callback URL" -ForegroundColor Cyan
                    
                        # Try to extract SAML from URL fragment/query string
                        try {
                            $uri = [Uri]$currentUrl
                            $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
                        
                            if ($query["SAMLResponse"]) {
                                $Script:SAMLResponse = $query["SAMLResponse"]
                                Write-Host "SAML Response found in URL query!" -ForegroundColor Green
                                $form.Close()
                            }
                            elseif ($uri.Fragment -match "SAMLResponse=([^&]*)") {
                                $Script:SAMLResponse = $Matches[1]
                                Write-Host "SAML Response found in URL fragment!" -ForegroundColor Green
                                $form.Close()
                            }
                        }
                        catch {
                            Write-Warning "Error parsing URL: $_"
                        }
                    }
                }
                else {
                    Write-Warning "Navigation failed: $($e.WebErrorStatus)"
                }
            })

        # Intercept WebResource responses to catch SAML POST
        $webView.CoreWebView2.AddWebResourceRequestedFilter("*", [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
        
        $webView.CoreWebView2.add_WebResourceRequested({
                param($sender, $e)
            
                $request = $e.Request
                $uri = $request.Uri
            
                Write-Host "Request to: $uri" -ForegroundColor DarkGray
            
                # Look for SAML response in POST requests
                if ($request.Method -eq "POST" -and $uri -like "*PasswordVault/api/auth/saml/logon*") {
                    Write-Host "Intercepted SAML POST request" -ForegroundColor Cyan
                
                    # Get the content
                    try {
                        $stream = $request.Content
                        if ($stream) {
                            $reader = New-Object System.IO.StreamReader($stream)
                            $body = $reader.ReadToEnd()
                        
                            # Parse the form data
                            if ($body -match "SAMLResponse=([^&]*)") {
                                $encodedSaml = $Matches[1]
                            
                                # URL decode the SAML response
                                $decodedSaml = [System.Web.HttpUtility]::UrlDecode($encodedSaml)
                            
                                if (-not [string]::IsNullOrWhiteSpace($decodedSaml)) {
                                    $Script:SAMLResponse = $decodedSaml
                                    Write-Host "SAML Response captured from POST body!" -ForegroundColor Green
                                    $form.Close()
                                }
                            }
                        }
                    }
                    catch {
                        Write-Warning "Error reading POST content: $_"
                    }
                }
            })

        # Monitor for SAML in page content (some IdPs embed it in HTML)
        $webView.CoreWebView2.add_ContentLoading({
                param($sender, $e)
            
                # After page loads, check for hidden SAML input fields
                $script = @"
                (function() {
                    // Look for SAMLResponse input field
                    var samlInput = document.querySelector('input[name="SAMLResponse"]');
                    if (samlInput && samlInput.value) {
                        return samlInput.value;
                    }
                    
                    // Look for SAMLResponse in forms
                    var forms = document.getElementsByTagName('form');
                    for (var i = 0; i < forms.length; i++) {
                        var form = forms[i];
                        if (form.action && form.action.includes('PasswordVault')) {
                            var inputs = form.getElementsByTagName('input');
                            for (var j = 0; j < inputs.length; j++) {
                                if (inputs[j].name === 'SAMLResponse' && inputs[j].value) {
                                    return inputs[j].value;
                                }
                            }
                        }
                    }
                    return null;
                })();
"@
            
                # Execute script to check for SAML
                $webView.CoreWebView2.ExecuteScriptAsync($script) | Out-Null
            })

        # Handle script execution results
        $webView.CoreWebView2.add_WebMessageReceived({
                param($sender, $e)
            
                try {
                    $message = $e.WebMessageAsJson | ConvertFrom-Json
                    if ($message -and $message.SAMLResponse) {
                        $Script:SAMLResponse = $message.SAMLResponse
                        Write-Host "SAML Response found via JavaScript!" -ForegroundColor Green
                        $form.Close()
                    }
                }
                catch {
                    # Not a JSON message or not our SAML response
                }
            })

        # Start Navigation
        Write-Host "Opening browser for SAML authentication..." -ForegroundColor Cyan
        $webView.CoreWebView2.Navigate($LoginIDP)

        # Show and process the form
        $form.Add_Shown({ $form.Activate() })
        [void]$form.ShowDialog()

        # Cleanup
        $form.Dispose()

        if ($Script:SAMLResponse) {
            # Remove any + signs that might be spaces (URL encoding artifact)
            $Script:SAMLResponse = $Script:SAMLResponse.Replace('+', ' ')
            return $Script:SAMLResponse
        }
        else {
            throw "SAML authentication failed or was cancelled"
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive