Import-Module psPAS

function Start-CACOnboarding {
    param(
        [string]$SafeName,
        [string]$AccountUser
    )

    Write-Host "Starting onboarding..." -ForegroundColor Cyan

    # 1. Create safe if missing
    if (-not (Get-PASSafe -SafeName $SafeName -ErrorAction Ignore)) {
        New-PASSafe -SafeName $SafeName -Description "Created by CLI"
        Write-Host "Safe created." -ForegroundColor Green
    }

    # 2. Add default safe members
    Add-PASSafeMember -SafeName $SafeName -MemberName "PVWAAdmin" -Permissions @("ListAccounts", "RetrieveAccounts")
    Write-Host "Members added." -ForegroundColor Green

    # 3. Create sample account
    New-PASAccount -SafeName $SafeName -UserName $AccountUser -PlatformID "WinDomain" -Address "localhost"
    Write-Host "Account created." -ForegroundColor Green

    Write-Host "Onboarding completed." -ForegroundColor Cyan
}

Export-ModuleMember -Function Start-CACOnboarding
