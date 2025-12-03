# Prompt for alternate domain credentials
$cred = Get-Credential -Message "Enter the domain admin credentials"

# Target server name
$Server = "ServerNameHere"

# Test remote access (optional)
Test-WSMan -ComputerName $Server -Credential $cred

# Retrieve local users
Invoke-Command -ComputerName $Server -Credential $cred -ScriptBlock {
    Write-Host "`n--- Local Users ---`n"
    Get-LocalUser
}

# Retrieve local groups
Invoke-Command -ComputerName $Server -Credential $cred -ScriptBlock {
    Write-Host "`n--- Local Groups ---`n"
    Get-LocalGroup
}

# Retrieve group members (optional)
Invoke-Command -ComputerName $Server -Credential $cred -ScriptBlock {
    Write-Host "`n--- Local Group Members ---`n"
    Get-LocalGroup | ForEach-Object {
        Write-Host "Group: $($_.Name)"
        Get-LocalGroupMember -Group $_.Name | Select-Object Name, ObjectClass
        Write-Host ""
    }
}
