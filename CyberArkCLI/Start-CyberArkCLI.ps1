# =============================================================================
# Start-CyberArkCLI.ps1
# Self-contained launcher: syncs from GitHub then launches the CyberArk CLI.
# Tries Git first; falls back to GitHub API if Git is unavailable.
# =============================================================================

param(
    [switch]$SkipSync,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

# =============================================================================
# CONFIGURATION
# =============================================================================
$Owner = "Sarbe97"
$Repo = "CyberArkAutomation"
$Branch = "main"
$RemoteSubfolder = "CyberArkCLI"   # subfolder in the repo that contains the CLI

# Files/patterns to SKIP during API sync (won't overwrite if they already exist locally)
$ExcludedPatterns = @(
    "Start-CyberArkCLI.ps1",   # Don't overwrite this launcher
    "config.json",              # User's local configuration
    "*.log"                     # Local log files
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
function Write-ColorHost {
    param($Message, $Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Test-GitInstalled {
    try {
        $null = git --version 2>&1
        return $true
    }
    catch {
        return $false
    }
}

function Test-GitRepository {
    param($Path)
    try {
        Push-Location $Path
        $result = git rev-parse --is-inside-work-tree 2>&1
        Pop-Location
        return $result -eq "true"
    }
    catch {
        Pop-Location
        return $false
    }
}

# =============================================================================
# METHOD 1: GIT SYNC
# =============================================================================
function Sync-WithGit {
    param($RepoPath)
    
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " GitHub Sync (Git)" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    
    Push-Location $RepoPath
    
    try {
        # Fetch latest from remote
        Write-ColorHost "Fetching latest from origin..." "Yellow"
        git fetch origin 2>&1 | Out-Null
        
        # Get current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1
        Write-ColorHost "Current branch: $currentBranch" "Gray"
        
        # Check if there are uncommitted changes
        $status = git status --porcelain 2>&1
        $hasLocalChanges = -not [string]::IsNullOrWhiteSpace($status)
        
        # Check if behind remote
        $behindCount = git rev-list --count "HEAD..origin/$currentBranch" 2>&1
        $aheadCount = git rev-list --count "origin/$currentBranch..HEAD" 2>&1
        
        # Handle case where remote branch doesn't exist
        if ($behindCount -match "unknown revision") {
            Write-ColorHost "Remote branch not found. Skipping sync." "Yellow"
            Pop-Location
            return $true
        }
        
        $isBehind = [int]$behindCount -gt 0
        $isAhead = [int]$aheadCount -gt 0
        
        # Display status
        if ($hasLocalChanges) {
            Write-ColorHost "[!] You have uncommitted local changes" "Yellow"
            Write-Host ""
            Write-Host "Changed files:" -ForegroundColor Gray
            $status | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Host ""
        }
        
        if ($isBehind) {
            Write-ColorHost "[!] You are $behindCount commit(s) behind origin/$currentBranch" "Red"
        }
        
        if ($isAhead) {
            Write-ColorHost "[i] You are $aheadCount commit(s) ahead of origin/$currentBranch" "Cyan"
        }
        
        if (-not $isBehind -and -not $hasLocalChanges) {
            Write-ColorHost "[OK] Repository is up to date!" "Green"
            Pop-Location
            return $true
        }
        
        # If behind, prompt to pull
        if ($isBehind) {
            Write-Host ""
            if ($Force) {
                Write-ColorHost "Force mode: Pulling latest changes..." "Yellow"
                $pullChoice = 'Y'
            }
            else {
                Write-Host "Would you like to pull the latest changes? (Y/N) " -ForegroundColor Yellow -NoNewline
                $pullChoice = Read-Host
            }
            
            if ($pullChoice -eq 'Y' -or $pullChoice -eq 'y') {
                if ($hasLocalChanges) {
                    Write-ColorHost "Stashing local changes..." "Yellow"
                    git stash push -m "Auto-stash before sync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 2>&1 | Out-Null
                }
                
                Write-ColorHost "Pulling from origin/$currentBranch..." "Yellow"
                $pullResult = git pull origin $currentBranch 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    Write-ColorHost "[OK] Successfully pulled latest changes!" "Green"
                    
                    if ($hasLocalChanges) {
                        Write-ColorHost "Restoring stashed changes..." "Yellow"
                        $stashResult = git stash pop 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-ColorHost "[!] Merge conflict detected. Please resolve manually." "Red"
                            Write-Host $stashResult
                            Pop-Location
                            return $false
                        }
                    }
                }
                else {
                    Write-ColorHost "[!] Pull failed. Please resolve manually." "Red"
                    Write-Host $pullResult
                    Pop-Location
                    return $false
                }
            }
            else {
                Write-ColorHost "[!] Skipping pull. You may be running outdated code." "Yellow"
            }
        }
        
        Pop-Location
        return $true
    }
    catch {
        Pop-Location
        Write-ColorHost "[!] Git sync error: $($_.Exception.Message)" "Red"
        return $false
    }
}

# =============================================================================
# METHOD 2: GITHUB API SYNC (fallback when Git is not available)
# =============================================================================
function Sync-WithGitHubAPI {
    param($LocalRoot)

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " GitHub Sync (API Download)" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""

    $headers = @{ "User-Agent" = "CyberArkCLI-Sync" }

    function Sync-Folder {
        param (
            [string]$RemotePath,
            [string]$TargetPath
        )

        $apiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$($RemotePath)?ref=$Branch"

        try {
            $items = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers
        }
        catch {
            Write-ColorHost "[ERROR] Could not fetch: $RemotePath ($($_.Exception.Message))" "Red"
            return $false
        }

        foreach ($item in $items) {
            $currentLocalPath = Join-Path $TargetPath $item.name

            if ($item.type -eq "dir") {
                # Skip Output folder
                if ($item.name -eq "Output") { continue }

                if (!(Test-Path $currentLocalPath)) {
                    New-Item -ItemType Directory -Path $currentLocalPath -Force | Out-Null
                }
                Sync-Folder -RemotePath $item.path -TargetPath $currentLocalPath
            }
            elseif ($item.type -eq "file") {

                # Check exclusions
                $isExcluded = $false
                foreach ($pattern in $ExcludedPatterns) {
                    if ($item.name -like $pattern) {
                        $isExcluded = $true
                        break
                    }
                }

                # Skip excluded files only if they already exist locally
                if ($isExcluded -and (Test-Path $currentLocalPath)) {
                    Write-Host "  [SKIP] $($item.name)" -ForegroundColor Yellow
                    continue
                }

                # Download
                Write-Host "  [SYNC] $($item.name)" -ForegroundColor Green
                try {
                    Invoke-WebRequest -Uri $item.download_url -OutFile $currentLocalPath -UseBasicParsing
                }
                catch {
                    Write-ColorHost "  [FAIL] $($item.name): $($_.Exception.Message)" "Red"
                }
            }
        }
        return $true
    }

    # Create target folder if needed
    if (!(Test-Path $LocalRoot)) {
        New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null
    }

    Write-ColorHost "Downloading from $Owner/$Repo/$RemoteSubfolder ..." "Yellow"
    Write-Host ""

    $result = Sync-Folder -RemotePath $RemoteSubfolder -TargetPath $LocalRoot

    Write-Host ""
    if ($result) {
        Write-ColorHost "[OK] API sync complete." "Green"
    }
    else {
        Write-ColorHost "[!] API sync completed with errors." "Yellow"
    }

    return $result
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "  ______      __              ___         __     ________    ____" -ForegroundColor Cyan
Write-Host " / ____/_  __/ /_  ___  _____/   |  _____/ /__  / ____/ /   /  _/" -ForegroundColor Cyan
Write-Host "/ /   / / / / __ \/ _ \/ ___/ /| | / ___/ //_/ / /   / /    / /  " -ForegroundColor Cyan
Write-Host "/ /___/ /_/ / /_/ /  __/ /  / ___ |/ /  / ,<   / /___/ /____/ /   " -ForegroundColor Cyan
Write-Host "\____/\__, /_.___/\___/_/  /_/  |_/_/  /_/|_|  \____/_____/___/   " -ForegroundColor Cyan
Write-Host "     /____/                                                       " -ForegroundColor Cyan
Write-Host ""

# --- SYNC PHASE ---
if (-not $SkipSync) {

    $gitAvailable = Test-GitInstalled
    $repoRoot = Split-Path $scriptRoot -Parent
    $isGitRepo = $gitAvailable -and (Test-GitRepository $repoRoot)

    # Build menu based on what's available
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " Sync Options" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""

    if ($isGitRepo) {
        Write-Host "  1. Git Sync        (pull latest from repository)" -ForegroundColor White
    }
    else {
        Write-Host "  1. Git Sync        (not available)" -ForegroundColor DarkGray
    }
    Write-Host "  2. API Download    (download from GitHub without Git)" -ForegroundColor White
    Write-Host "  3. Skip            (launch without syncing)" -ForegroundColor White
    Write-Host ""

    $syncChoice = Read-Host "Select option (1/2/3)"

    switch ($syncChoice) {
        '1' {
            if ($isGitRepo) {
                $syncResult = Sync-WithGit -RepoPath $repoRoot
                if (-not $syncResult) {
                    Write-Host ""
                    Write-Host "Sync had issues. Continue anyway? (Y/N) " -ForegroundColor Yellow -NoNewline
                    $c = Read-Host
                    if ($c -ne 'Y' -and $c -ne 'y') { exit 1 }
                }
            }
            else {
                Write-ColorHost "[!] Git is not available in this environment." "Red"
                Write-ColorHost "    Use option 2 (API Download) instead." "Yellow"
                Write-Host ""
                Write-Host "Press Enter to continue without sync..." -ForegroundColor Gray
                Read-Host | Out-Null
            }
        }
        '2' {
            $syncResult = Sync-WithGitHubAPI -LocalRoot $scriptRoot
            if (-not $syncResult) {
                Write-Host ""
                Write-Host "Sync had issues. Continue anyway? (Y/N) " -ForegroundColor Yellow -NoNewline
                $c = Read-Host
                if ($c -ne 'Y' -and $c -ne 'y') { exit 1 }
            }
        }
        default {
            Write-ColorHost "[i] Sync skipped." "Gray"
        }
    }
}
else {
    Write-ColorHost "[i] Sync skipped (-SkipSync)." "Gray"
}

# --- LAUNCH CLI ---
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " Launching CyberArk CLI..." -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Start-Sleep -Milliseconds 500

$cliPath = Join-Path $scriptRoot "cli.ps1"
if (Test-Path $cliPath) {
    & $cliPath
}
else {
    Write-ColorHost "[!] CLI script not found: $cliPath" "Red"
    Write-ColorHost "    Run again and choose option 2 (API Download) to fetch the files." "Yellow"
    exit 1
}
