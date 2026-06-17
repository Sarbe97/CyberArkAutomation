#========================================================================
# ServerManager.psm1 — Server Configuration Module
# Manages Servers.json: CRUD, import/export, connectivity testing
#========================================================================

$script:ServersFile    = $null
$script:Servers        = [System.Collections.Generic.List[hashtable]]::new()
$script:ValidCategories = @('PVWA','CPM','PSM','PTA','IIS','SQL','Utility','Other')

# ---------- Initialization --------------------------------------------------

function Initialize-ServerManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigDirectory
    )

    $script:ServersFile = Join-Path $ConfigDirectory 'Servers.json'

    if (-not (Test-Path $script:ServersFile)) {
        _CreateSampleServers
    }

    _LoadServers
    Write-NexusLog "Loaded $($script:Servers.Count) servers" -Level INFO -Component 'ServerMgr'
}

function _CreateSampleServers {
    $sample = @(
        [ordered]@{ Name='PVWA01'; ServerName='PVWA01.domain.local'; RootShare='\\PVWA01\D$'; Category='PVWA'; Description='Primary PVWA Server' }
        [ordered]@{ Name='PVWA02'; ServerName='PVWA02.domain.local'; RootShare='\\PVWA02\D$'; Category='PVWA'; Description='Secondary PVWA Server' }
        [ordered]@{ Name='CPM01';  ServerName='CPM01.domain.local';  RootShare='\\CPM01\D$';  Category='CPM';  Description='Primary CPM Server'  }
        [ordered]@{ Name='CPM02';  ServerName='CPM02.domain.local';  RootShare='\\CPM02\D$';  Category='CPM';  Description='Secondary CPM Server'  }
        [ordered]@{ Name='PSM01';  ServerName='PSM01.domain.local';  RootShare='\\PSM01\D$';  Category='PSM';  Description='Primary PSM Server'  }
        [ordered]@{ Name='PSM02';  ServerName='PSM02.domain.local';  RootShare='\\PSM02\D$';  Category='PSM';  Description='Secondary PSM Server'  }
        [ordered]@{ Name='PTA01';  ServerName='PTA01.domain.local';  RootShare='\\PTA01\D$';  Category='PTA';  Description='PTA Server'  }
    )
    $sample | ConvertTo-Json -Depth 3 | Set-Content -Path $script:ServersFile -Encoding UTF8
}

function _LoadServers {
    $script:Servers = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $json = Get-Content $script:ServersFile -Raw | ConvertFrom-Json
        foreach ($item in $json) {
            $script:Servers.Add([ordered]@{
                Name        = [string]$item.Name
                ServerName  = [string]$item.ServerName
                RootShare   = [string]$item.RootShare
                Category    = [string]$item.Category
                Description = [string]$item.Description
            })
        }
    }
    catch {
        Write-NexusLog "Failed to load Servers.json: $($_.Exception.Message)" -Level ERROR -Component 'ServerMgr'
    }
}

# ---------- Queries ---------------------------------------------------------

function Get-Servers {
    [CmdletBinding()]
    param([string]$Category)

    if ($Category) {
        return @($script:Servers | Where-Object { $_.Category -eq $Category })
    }
    return $script:Servers.ToArray()
}

function Get-ServerCategories {
    return @($script:Servers | Select-Object -ExpandProperty Category -Unique | Sort-Object)
}

function Get-ServerByName {
    param([Parameter(Mandatory)][string]$Name)
    return $script:Servers | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-ValidCategories { return $script:ValidCategories }

# ---------- CRUD ------------------------------------------------------------

function Add-Server {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RootShare,
        [Parameter(Mandatory)][ValidateSet('PVWA','CPM','PSM','PTA','IIS','SQL','Utility','Other')]
        [string]$Category,
        [string]$Description = ''
    )

    if ($script:Servers | Where-Object { $_.Name -eq $Name }) {
        throw "A server named '$Name' already exists."
    }

    $server = [ordered]@{
        Name        = $Name
        ServerName  = $ServerName
        RootShare   = $RootShare
        Category    = $Category
        Description = $Description
    }
    $script:Servers.Add($server)
    _SaveServers
    Write-NexusLog "Server added: $Name [$Category]" -Level INFO -Component 'ServerMgr'
    return $server
}

function Update-Server {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OriginalName,
        [Parameter(Mandatory)][hashtable]$Updated
    )

    $existing = $script:Servers | Where-Object { $_.Name -eq $OriginalName } | Select-Object -First 1
    if (-not $existing) { throw "Server '$OriginalName' not found." }

    $existing.Name        = $Updated.Name
    $existing.ServerName  = $Updated.ServerName
    $existing.RootShare   = $Updated.RootShare
    $existing.Category    = $Updated.Category
    $existing.Description = $Updated.Description
    _SaveServers
    Write-NexusLog "Server updated: $OriginalName -> $($Updated.Name)" -Level INFO -Component 'ServerMgr'
}

function Remove-Server {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $existing = $script:Servers | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $existing) { throw "Server '$Name' not found." }

    $script:Servers.Remove($existing) | Out-Null
    _SaveServers
    Write-NexusLog "Server removed: $Name" -Level INFO -Component 'ServerMgr'
}

function _SaveServers {
    $script:Servers.ToArray() | ConvertTo-Json -Depth 3 |
        Set-Content -Path $script:ServersFile -Encoding UTF8
}

# ---------- Import / Export -------------------------------------------------

function Import-ServerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)

    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
    Copy-Item $FilePath -Destination $script:ServersFile -Force
    _LoadServers
    Write-NexusLog "Servers imported from $FilePath ($($script:Servers.Count) servers)" -Level INFO -Component 'ServerMgr'
}

function Export-ServerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)

    $script:Servers.ToArray() | ConvertTo-Json -Depth 3 |
        Set-Content -Path $FilePath -Encoding UTF8
    Write-NexusLog "Servers exported to $FilePath" -Level INFO -Component 'ServerMgr'
}

# ---------- Connectivity ----------------------------------------------------

function Test-ServerConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Server,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    $driveName = "SAWTest$(Get-Random -Maximum 99999)"
    try {
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem `
                            -Root $Server.RootShare -Credential $Credential `
                            -ErrorAction Stop
        Write-NexusLog "Connection OK: $($Server.Name) - $($Server.RootShare)" -Level INFO -Component 'ServerMgr'
        return $true
    }
    catch {
        Write-NexusLog "Connection FAILED: $($Server.Name) - $($_.Exception.Message)" -Level WARN -Component 'ServerMgr'
        return $false
    }
    finally {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Initialize-ServerManager, Get-Servers, Get-ServerCategories,
    Get-ServerByName, Get-ValidCategories,
    Add-Server, Update-Server, Remove-Server,
    Import-ServerConfig, Export-ServerConfig, Test-ServerConnection
