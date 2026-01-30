# =============================================================================
# Start-CyberArkCLI.ps1
# Wrapper script that syncs from GitHub before launching the CyberArk CLI
# =============================================================================

param(
    [switch]$SkipSync,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

# Get the git repository root (parent of CyberArkCLI folder)
$repoRoot = Split-Path $scriptRoot -Parent

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

function Sync-FromGitHub {
    param($RepoPath)
    
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " GitHub Sync Check" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
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
            Write-ColorHost "Remote branch not found. Skipping sync check." "Yellow"
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
                Write-Host "Would you like to pull the latest changes? (Y/N)" -ForegroundColor Yellow -NoNewline
                $pullChoice = Read-Host " "
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

# Check if Git is installed
if (-not (Test-GitInstalled)) {
    Write-ColorHost "[!] Git is not installed or not in PATH." "Yellow"
    Write-ColorHost "    Skipping sync check..." "Gray"
    $SkipSync = $true
}

# Check if this is a git repository
if (-not $SkipSync -and -not (Test-GitRepository $repoRoot)) {
    Write-ColorHost "[!] Not a Git repository: $repoRoot" "Yellow"
    Write-ColorHost "    Skipping sync check..." "Gray"
    $SkipSync = $true
}

# Perform sync check
if (-not $SkipSync) {
    $syncResult = Sync-FromGitHub -RepoPath $repoRoot
    
    if (-not $syncResult) {
        Write-Host ""
        Write-ColorHost "Sync failed. Do you want to continue anyway? (Y/N)" "Yellow" -NoNewline
        $continueChoice = Read-Host " "
        if ($continueChoice -ne 'Y' -and $continueChoice -ne 'y') {
            Write-ColorHost "Exiting..." "Gray"
            exit 1
        }
    }
}
else {
    Write-ColorHost "[i] Sync check skipped." "Gray"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Launching CyberArk CLI..." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Start-Sleep -Milliseconds 500

# Launch the main CLI
$cliPath = Join-Path $scriptRoot "cli.ps1"
if (Test-Path $cliPath) {
    & $cliPath
}
else {
    Write-ColorHost "[!] CLI script not found: $cliPath" "Red"
    exit 1
}
