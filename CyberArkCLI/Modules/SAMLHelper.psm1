function Set-BrowserEmulation {
    <#
    .SYNOPSIS
        Sets the Internet Explorer emulation mode for the current process to IE11.
    #>
    try {
        $key = "HKCU:\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION"
        if (-not (Test-Path $key)) {
            New-Item $key -Force | Out-Null
        }

        $processName = [System.IO.Path]::GetFileName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $currentValue = (Get-ItemProperty $key).$processName

        # 11001 (0x2AF9) = IE11. 
        if ($currentValue -ne 11001) {
            Write-Host "Setting Browser Emulation to IE11 for $processName..." -ForegroundColor DarkGray
            Set-ItemProperty $key -Name $processName -Value 11001 -Type DWord -Force
        }
    }
    catch {
        Write-Warning "Failed to set browser emulation: $_"
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
        Add-Type -AssemblyName System.Web
        
        # Ensure we are running with IE11 Emulation
        Set-BrowserEmulation

        # Save page source to file for debugging
        $debugDir = Join-Path $env:TEMP "SAML_Debug"
        if (-not (Test-Path $debugDir)) {
            New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
        }
        $debugFile = Join-Path $debugDir "saml_debug_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    }

    Process {
        $Script:SAMLResponse = $null
        
        $form = New-Object System.Windows.Forms.Form
        $form.StartPosition = "CenterScreen"
        $form.Width = 1000
        $form.Height = 800
        $form.Text = "SAML Authentication - Please Login"
        $form.ShowIcon = $false
        
        $web = New-Object System.Windows.Forms.WebBrowser
        $web.Dock = "Fill"
        $web.ScriptErrorsSuppressed = $true # Suppress JS errors which are common in IE control
        $form.Controls.Add($web)
        
        # Regex patterns to find SAML Response in HTML
        $patterns = @(
            '(?i)name=["'']SAMLResponse["'']\s+(?:type=["'']hidden["'']\s+)?value=["'']([^"'']+)["'']',
            '(?i)value=["'']([^"'']+)["'']\s+(?:type=["'']hidden["'']\s+)?name=["'']SAMLResponse["'']',
            'SAMLResponse=([^&"''\s]+)'
        )

        # Handler to check content
        $checkContent = {
            param($source, $msg)
            
            if ([string]::IsNullOrWhiteSpace($source)) { return }

            # Log URL for debug
            $url = $web.Url.ToString()
            $timestamp = Get-Date -Format "HH:mm:ss"
            Add-Content -Path $debugFile -Value "[$timestamp] $msg - $url"

            # Check 1: URL Parameters
            if ($url -match "SAMLResponse=([^&]+)") {
                Write-Host "DEBUG: Found SAML in URL!" -ForegroundColor Green
                $Script:SAMLResponse = [System.Web.HttpUtility]::UrlDecode($Matches[1])
                $form.Close()
                return
            }

            # Check 2: HTML Content via Regex
            foreach ($pattern in $patterns) {
                if ($source -match $pattern) {
                    Write-Host "DEBUG: Found SAML via Regex ($msg)" -ForegroundColor Green
                    $val = $Matches[1]
                    # Decode HTML entities if present
                    $val = $val -replace '&#x2b;', '+' -replace '&#x3d;', '='
                    $Script:SAMLResponse = $val
                    $form.Close()
                    return
                }
            }

            # Check 3: DOM Elements (more reliable for parsed HTML)
            if ($web.Document) {
                $inputs = $web.Document.GetElementsByTagName("input")
                foreach ($inp in $inputs) {
                    if ($inp.Name -eq "SAMLResponse") {
                        Write-Host "DEBUG: Found SAML input field in DOM!" -ForegroundColor Green
                        $Script:SAMLResponse = $inp.GetAttribute("value")
                        $form.Close()
                        return
                    }
                }
            }
        }

        # Event: Navigating (Before load)
        # Use this to catch redirects or early content
        $web.add_Navigating({
                param($sndr, $e)
            
                # Check if we are being redirected with SAMLResponse in URL
                $url = $e.Url.ToString()
            
                # Note: We can't easily see POST body here in WebBrowser control
                # But we can check if the URL *is* the logic endpoint
                if ($url -match "SAMLResponse") {
                    & $checkContent $url "Navigating(URL)"
                }
            })

        # Event: DocumentCompleted (After load)
        $web.add_DocumentCompleted({
                param($sndr, $e)
                $url = $web.Url.ToString()
            
                # Only process if we are not on 'about:blank'
                if ($url -ne "about:blank") {
                    Write-Host "Loaded: $url" -ForegroundColor Gray
                    & $checkContent $web.DocumentText "DocumentCompleted"
                }
            })
        
        # Navigate to IDP
        Write-Host "Opening Login Window..." -ForegroundColor Cyan
        $web.Navigate($LoginIDP)
        
        # Show form
        [void]$form.ShowDialog()
        
        $form.Dispose()

        if ($Script:SAMLResponse) {
            return $Script:SAMLResponse
        }
        else {
            Write-Warning "SAML Authentication window closed without capturing a response."
            Write-Warning "Debug log: $debugFile"
            return $null
        }
    }
}

Export-ModuleMember -Function New-SAMLInteractive