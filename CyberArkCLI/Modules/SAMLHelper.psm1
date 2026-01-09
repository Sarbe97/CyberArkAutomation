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
        
        # --- EVENT HANDLERS ---
        
        # Add Filter for WebResourceRequested
        # We want to intercept the specific POST to the CyberArk api
        $filter = "*PasswordVault/api/auth/saml/logon*"
        $webView.CoreWebView2.AddWebResourceRequestedFilter($filter, [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)

        $webView.add_WebResourceRequested({
                param($sender, $e)
            
                # Use Deferral to safely process async content
                # $deferral = $e.GetDeferral() # Not strictly needed if reading sync, but good practice if we were awaiting.
                # In PS event handlers, we try to be synchronous to avoid complexities.
            
                try {
                    $request = $e.Request
                    # We expect a POST with the SAMLResponse
                    if ($request.Method -eq "POST" -and $null -ne $request.Content) {
                    
                        # Log
                        Write-Host "Intercepted POST to logon API. Reading content..." -ForegroundColor Cyan
                    
                        # Content is an IStream. We need to read it.
                        # Since this runs in the event handler, we must be careful.
                        # The Content property returns a System.IO.Stream wrapper in the .NET projection.
                    
                        $stream = $request.Content
                        if ($null -ne $stream) {
                            $reader = New-Object System.IO.StreamReader($stream)
                            $body = $reader.ReadToEnd()
                         
                            # Check for SAMLResponse
                            # Format is usually: SAMLResponse=...&RelayState=...
                            # We can regex it.
                            if ($body -match "SAMLResponse=([^&]*)") {
                                $rawSaml = $Matches[1]
                             
                                # The value is URL Encoded. Decode it.
                                # Using System.Uri as it's standard available.
                                $decodedSaml = [System.Uri]::UnescapeDataString($rawSaml) 
                             
                                # Fix specific entities if UnescapeDataString didn't catch them (it handles %xx)
                                # Usually it's enough.
                             
                                if (-not [string]::IsNullOrWhiteSpace($decodedSaml)) {
                                    Write-Host "SAML Response Captured via Network!" -ForegroundColor Green
                                    $Script:SAMLResponse = $decodedSaml
                                 
                                    # We have the token. We can prevent the default network request if we want/can.
                                    # But simplest is just to close the form now.
                                    # If we let it proceed, it might return 401/200 but we don't care.
                                    $form.Close()
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Warning "Error processing WebResource: $_"
                }
                # finally { $deferral.Complete() } 
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
