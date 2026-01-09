function New-SAMLInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $LoginIDP
    )

    Begin {
        $RegEx = '(?i)name="SAMLResponse"(?: type="hidden")? value=\"(.*?)\"(?:.*)?\/>'

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Web
    }

    Process {
        # Create window for embedded browser
        $form = New-Object Windows.Forms.Form
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Width = 640
        $form.Height = 700
        $form.ShowIcon = $false
        $form.TopMost = $true
        $form.Text = "CyberArk SAML Authentication"

        $web = New-Object Windows.Forms.WebBrowser
        $web.Size = $form.ClientSize
        $web.Anchor = "Left,Top,Right,Bottom"
        $web.ScriptErrorsSuppressed = $true

        $form.Controls.Add($web)
        $web.Navigate($LoginIDP)

        $web.add_Navigating({
                if ($web.DocumentText -match "SAMLResponse") {
                    $_.Cancel = $true

                    if ($web.DocumentText -match $RegEx) {
                        $form.Close()
                        $Script:SAMLResponse = $(($Matches[1] -replace '&#x2b;', '+') -replace '&#x3d;', '=')
                    }
                }
            })

        # Show browser window, waits for window to close
        [void][System.Windows.Forms.Application]::Run($form)
        
        if ($null -ne $Script:SAMLResponse) {
            Write-Output $Script:SAMLResponse
            $form.Close()
            Remove-Variable -Name SAMLResponse -Scope Script -ErrorAction SilentlyContinue
        }
        else {
            throw "SAMLResponse not matched or authentication cancelled"
        }
    }

    End {
        $form.Dispose()
    }
}

Export-ModuleMember -Function New-SAMLInteractive
