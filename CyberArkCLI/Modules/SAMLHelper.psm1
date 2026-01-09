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
        $pkgVersion = "1.0.1264.42" # Stable version
        $url = "https://www.nuget.org/api/v2/package/$pkgName/$pkgVersion"
        $zipPath = Join-Path $libPath "webview2.zip"

        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -ErrorAction Stop
        
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $extractPath = Join-Path $libPath "temp_extract"
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)

            # Copy DLLs
            # Core and WinForms
            $net45 = Join-Path $extractPath "lib\net45"
            Copy-Item (Join-Path $net45 "Microsoft.Web.WebView2.Core.dll") -Destination $libPath -Force
            Copy-Item (Join-Path $net45 "Microsoft.Web.WebView2.WinForms.dll") -Destination $libPath -Force
            
            # Loader (x64) - Assuming 64-bit PowerShell
            $runtimes = Join-Path $extractPath "runtimes\win-x64\native"
            Copy-Item (Join-Path $runtimes "WebView2Loader.dll") -Destination $libPath -Force

            # Cleanup
            Remove-Item $zipPath -Force
            Remove-Item $extractPath -Recurse -Force
            
            Write-Host "WebView2 dependencies downloaded." -ForegroundColor Green
        }
        catch {
            throw "Failed to download WebView2 dependencies: $($_.Exception.Message)"
        }
    }

    # Load Assemblies
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
        # Create Form
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Width = 600
        $form.Height = 800
        $form.ShowIcon = $false
        $form.TopMost = $false 
        $form.Text = "CyberArk SAML Authentication (WebView2)"

        # CREATE WEBVIEW2 CONTROL
        $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $webView.Dock = [System.Windows.Forms.DockStyle]::Fill
        $form.Controls.Add($webView)

        # 1. Define User Data Folder
        $userDataFolder = Join-Path $env:TEMP "CyberArkCLI_WebView2_Data"
        if (-not (Test-Path $userDataFolder)) {
            New-Item -ItemType Directory -Path $userDataFolder -Force | Out-Null
        }

        # 2. Create Environment (Async)
        try {
            $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $userDataFolder, $null)
            while (-not $envTask.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            if ($envTask.IsFaulted) { throw "Environment Creation Failed: $($envTask.Exception.InnerException.Message)" }
            $env = $envTask.Result

            # 3. Initialize WebView with Environment
            $task = $webView.EnsureCoreWebView2Async($env)
            while (-not $task.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            if ($task.IsFaulted) { throw "Control Initialization Failed: $($task.Exception.InnerException.Message)" }
        }
        catch { $form.Dispose(); throw "WebView2 Fatal Error: $_" }

        # --- EVENT HANDLERS ---
        
        $webView.add_NavigationStarting({
                param($sender, $e)
            
                $uri = $e.Uri.ToString()
                # Write-Host "Navigating to: $uri" -ForegroundColor DarkGray

                # OPTIMIZATION:
                # Only inspect the page content if we are navigating TO the CyberArk SAML Logon endpoint.
                # This means the CURRENT page (the autpost form) contains the SAML Response.
                # We skip inspection for all other IdP pages (Login, MFA, etc.) to prevent UI blocking.
            
                if ($uri -match "(?i)/PasswordVault/api/auth/saml/logon") {
                    Write-Host "Detected Redirect to CyberArk. Inspecting content..." -ForegroundColor Cyan

                    try {
                        $scriptTask = $webView.ExecuteScriptAsync("document.body.outerHTML")
                    
                        # Wait for script (blocking UI thread momentarily, but only once)
                        while (-not $scriptTask.IsCompleted) {
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 10
                        }

                        if ($scriptTask.Status -eq 'RanToCompletion') {
                            $html = $scriptTask.Result
                            if ($html -ne "null") {
                                $htmlUnescaped = [System.Text.RegularExpressions.Regex]::Unescape($html)
                                $htmlUnescaped = $htmlUnescaped.Trim('"')

                                $RegEx = '(?i)name="SAMLResponse"(?: type="hidden")? value=\"(.*?)\"(?:.*)?\/>'
                                if ($htmlUnescaped -match $RegEx) {
                                    $captured = $Matches[1]
                                    $captured = $captured -replace '&#x2b;', '+' -replace '&#x3d;', '='
                                
                                    Write-Host "SAML Response Captured!" -ForegroundColor Green
                                    $Script:SAMLResponse = $captured
                                
                                    $e.Cancel = $true
                                    $form.Close()
                                }
                            }
                        }
                    }
                    catch {
                        Write-Host "Error inspecting page: $_" -ForegroundColor Red
                    }
                }
            })
        
        # Start Navigation
        Write-Host "Navigating to Login Url..." -ForegroundColor Gray
        $webView.Source = [Uri]$LoginIDP

        # Show browser window
        [void][System.Windows.Forms.Application]::Run($form)

        if ($null -ne $Script:SAMLResponse) {
            Write-Output $Script:SAMLResponse
            $form.Close()
            Remove-Variable -Name SAMLResponse -Scope Script -ErrorAction SilentlyContinue
        }
        else {
            if ($null -eq $global:SAMLError) {
                # If no specific error but variable is null, assume user closed window
                Write-Warning "Authentication window closed by user."
            }
            else {
                throw $global:SAMLError
            }
        }
    }

    End {
        $form.Dispose()
    }
}

Export-ModuleMember -Function New-SAMLInteractive
