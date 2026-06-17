#========================================================================
# Favorites.psm1 — Favorites and Recent History Module
# Stores: favorite servers, favorite folders, recent history
# NEVER stores credentials or passwords
#========================================================================

$script:FavFile  = $null
$script:FavData  = $null
$script:MaxRecent = 50

# ---------- Init ------------------------------------------------------------

function Initialize-Favorites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDirectory)

    $script:FavFile = Join-Path $ConfigDirectory 'Favorites.json'

    if (-not (Test-Path $script:FavFile)) {
        _ResetFavData
        _SaveFavorites
    } else {
        _LoadFavorites
    }
}

function _ResetFavData {
    $script:FavData = [PSCustomObject]@{
        FavoriteServers  = [System.Collections.ArrayList]::new()
        FavoriteFolders  = [System.Collections.ArrayList]::new()
        FavoriteFiles    = [System.Collections.ArrayList]::new()
        RecentServers    = [System.Collections.ArrayList]::new()
        RecentFiles      = [System.Collections.ArrayList]::new()
        RecentSearches   = [System.Collections.ArrayList]::new()
        RecentLocations  = [System.Collections.ArrayList]::new()
    }
}

function _LoadFavorites {
    try {
        $json = Get-Content $script:FavFile -Raw | ConvertFrom-Json

        $script:FavData = [PSCustomObject]@{
            FavoriteServers  = [System.Collections.ArrayList](@($json.FavoriteServers))
            FavoriteFolders  = [System.Collections.ArrayList](@($json.FavoriteFolders))
            FavoriteFiles    = [System.Collections.ArrayList](@($json.FavoriteFiles))
            RecentServers    = [System.Collections.ArrayList](@($json.RecentServers))
            RecentFiles      = [System.Collections.ArrayList](@($json.RecentFiles))
            RecentSearches   = [System.Collections.ArrayList](@($json.RecentSearches))
            RecentLocations  = [System.Collections.ArrayList](@($json.RecentLocations))
        }
    }
    catch {
        Write-NexusLog "Failed to load Favorites.json - resetting: $($_.Exception.Message)" -Level WARN -Component 'Favorites'
        _ResetFavData
        _SaveFavorites
    }
}

function _SaveFavorites {
    try {
        [PSCustomObject]@{
            FavoriteServers  = @($script:FavData.FavoriteServers)
            FavoriteFolders  = @($script:FavData.FavoriteFolders)
            FavoriteFiles    = @($script:FavData.FavoriteFiles)
            RecentServers    = @($script:FavData.RecentServers)
            RecentFiles      = @($script:FavData.RecentFiles)
            RecentSearches   = @($script:FavData.RecentSearches)
            RecentLocations  = @($script:FavData.RecentLocations)
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $script:FavFile -Encoding UTF8
    }
    catch {
        Write-NexusLog "Failed to save Favorites.json: $($_.Exception.Message)" -Level ERROR -Component 'Favorites'
    }
}

function _Prepend {
    param([System.Collections.ArrayList]$List, $Item, [int]$Max)
    $List.Remove($Item) | Out-Null
    $List.Insert(0, $Item)
    while ($List.Count -gt $Max) { $List.RemoveAt($List.Count - 1) }
}

# ---------- Favorite Servers ------------------------------------------------

function Add-FavoriteServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerName)
    if ($ServerName -notin $script:FavData.FavoriteServers) {
        $null = $script:FavData.FavoriteServers.Add($ServerName)
        _SaveFavorites
        Write-NexusLog "Favorite server added: $ServerName" -Level INFO -Component 'Favorites'
    }
}

function Remove-FavoriteServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerName)
    $script:FavData.FavoriteServers.Remove($ServerName) | Out-Null
    _SaveFavorites
}

function Get-FavoriteServers { return @($script:FavData.FavoriteServers) }

function Test-IsFavoriteServer {
    param([string]$ServerName)
    return $ServerName -in $script:FavData.FavoriteServers
}

# ---------- Favorite Folders ------------------------------------------------

function Add-FavoriteFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )
    $existing = @($script:FavData.FavoriteFolders) | Where-Object { $_.Path -eq $Path }
    if (-not $existing) {
        $null = $script:FavData.FavoriteFolders.Add([PSCustomObject]@{ Name = $Name; Path = $Path; Added = (Get-Date -Format 's') })
        _SaveFavorites
        Write-NexusLog "Favorite folder added: $Name -> $Path" -Level INFO -Component 'Favorites'
    }
}

function Remove-FavoriteFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $item = @($script:FavData.FavoriteFolders) | Where-Object { $_.Path -eq $Path } | Select-Object -First 1
    if ($item) { $script:FavData.FavoriteFolders.Remove($item) | Out-Null; _SaveFavorites }
}

function Get-FavoriteFolders { return @($script:FavData.FavoriteFolders) }

# ---------- Favorite Files --------------------------------------------------

function Add-FavoriteFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $existing = @($script:FavData.FavoriteFiles) | Where-Object { $_ -eq $FilePath }
    if (-not $existing) {
        $null = $script:FavData.FavoriteFiles.Add($FilePath)
        _SaveFavorites
    }
}

function Remove-FavoriteFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $script:FavData.FavoriteFiles.Remove($FilePath) | Out-Null
    _SaveFavorites
}

function Get-FavoriteFiles { return @($script:FavData.FavoriteFiles) }

# ---------- Recent History --------------------------------------------------

function Add-RecentServer {
    param([string]$ServerName)
    _Prepend $script:FavData.RecentServers $ServerName $script:MaxRecent
    _SaveFavorites
}

function Add-RecentFile {
    param([string]$FilePath)
    _Prepend $script:FavData.RecentFiles $FilePath $script:MaxRecent
    _SaveFavorites
}

function Add-RecentSearch {
    param([string]$SearchText)
    _Prepend $script:FavData.RecentSearches $SearchText $script:MaxRecent
    _SaveFavorites
}

function Add-RecentLocation {
    param([string]$Location)
    _Prepend $script:FavData.RecentLocations $Location $script:MaxRecent
    _SaveFavorites
}

function Get-RecentServers   { return @($script:FavData.RecentServers   | Select-Object -First 15) }
function Get-RecentFiles     { return @($script:FavData.RecentFiles     | Select-Object -First 15) }
function Get-RecentSearches  { return @($script:FavData.RecentSearches  | Select-Object -First 15) }
function Get-RecentLocations { return @($script:FavData.RecentLocations | Select-Object -First 15) }

Export-ModuleMember -Function Initialize-Favorites,
    Add-FavoriteServer, Remove-FavoriteServer, Get-FavoriteServers, Test-IsFavoriteServer,
    Add-FavoriteFolder, Remove-FavoriteFolder, Get-FavoriteFolders,
    Add-FavoriteFile,   Remove-FavoriteFile,   Get-FavoriteFiles,
    Add-RecentServer,   Get-RecentServers,
    Add-RecentFile,     Get-RecentFiles,
    Add-RecentSearch,   Get-RecentSearches,
    Add-RecentLocation, Get-RecentLocations
