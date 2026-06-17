# Server Access Workbench (SAW) — Architecture Document

## Overview

SAW is a PowerShell 5.1 WPF desktop application for CyberArk support/operations teams.  
It provides credential-aware UNC browsing, log analysis, and parallel multi-server search — without drive mappings or credential persistence.

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SAW.ps1 (Entry Point)                         │
│  • Loads WPF assemblies                                              │
│  • Imports all modules                                               │
│  • Initializes subsystems                                            │
│  • Shows login → launches main window                                │
└──────────────────┬───────────────────────────────────────────────────┘
                   │
         ┌─────────▼──────────┐
         │  Auth.psm1          │  ← Login dialog (NA\S123456 default)
         │  PSCredential only  │     SecureString in memory
         └─────────┬──────────┘
                   │ $script:Credential (global session)
    ┌──────────────┼──────────────────────────────┐
    │              │                              │
    ▼              ▼                              ▼
┌───────────┐  ┌──────────────┐         ┌─────────────────┐
│ Server    │  │ FileExplorer │         │    Search       │
│ Manager   │  │ psm1         │         │    psm1         │
│           │  │              │         │                 │
│ CRUD ops  │  │ New-PSDrive  │         │ RunspacePool    │
│ JSON      │  │ (temp/auto-  │         │ (parallel)      │
│ persist   │  │ removed)     │         │ ConcurrentQueue │
└───────────┘  └──────┬───────┘         └────────┬────────┘
                      │                          │
               ┌──────▼──────┐         ┌─────────▼───────┐
               │  LogViewer  │         │   Favorites     │
               │  psm1       │         │   psm1          │
               │             │         │                 │
               │ Paginated   │         │ Servers/Folders │
               │ reading     │         │ Recent history  │
               │ Tail/search │         │ (JSON, no creds)│
               └─────────────┘         └─────────────────┘
                      │
               ┌──────▼──────────────────────────────────┐
               │         UI\MainWindow.ps1                │
               │                                          │
               │  ┌──────────┬──────────────┬──────────┐ │
               │  │  Left    │   Center     │  Right   │ │
               │  │  Panel   │   Panel      │  Panel   │ │
               │  │          │              │          │ │
               │  │ Server   │ Path bar     │ Search   │ │
               │  │ TreeView │ QuickPaths   │ Results  │ │
               │  │ by cat   │ File list    │ Filters  │ │
               │  │          │              │ Recent   │ │
               │  └──────────┴──────────────┴──────────┘ │
               │                                          │
               │  ┌──────────────────────────────────┐   │
               │  │    Bottom: Log Viewer TabControl  │   │
               │  │  DataGrid: LineNum | Content      │   │
               │  │  Multiple tabs, jump-to-line      │   │
               │  └──────────────────────────────────┘   │
               └──────────────────────────────────────────┘
```

---

## Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| `AppLogger.psm1` | Thread-safe daily-rotating log. Strips credential patterns. |
| `Auth.psm1` | WPF login dialog. Returns `[PSCredential]`. Never writes anything. |
| `ServerManager.psm1` | Reads/writes `Servers.json`. CRUD + connectivity test. |
| `FileExplorer.psm1` | UNC browsing via `New-PSDrive` + cleanup. Path browser dialog. QuickPaths persistence. |
| `LogViewer.psm1` | Paginated file reading. File-level search. Tail support. |
| `Search.psm1` | RunspacePool parallel search. `ConcurrentQueue` result streaming. |
| `Favorites.psm1` | Favorites + recent history. `Favorites.json`. Zero credentials. |

---

## Security Design

### Credential Lifecycle
```
Login dialog ──► [PSCredential] in $script:Credential ──► UNC operation ──► discarded
                       │
                       ▼
               NEVER written to:
                 • Disk (any file)
                 • Registry
                 • Event log
                 • Application log
                 • Network (except the target UNC share)
```

### UNC Access Pattern
```powershell
$driveName = "SAW$(Get-Random -Maximum 99999)"
try {
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root $share -Credential $cred
    # Do work here using $driveName:\
}
finally {
    Remove-PSDrive -Name $driveName -Force  # ALWAYS removed
}
```

No drive letters survive between operations.

---

## Threading Model

| Operation | Thread Strategy |
|-----------|----------------|
| UI events | STA main thread |
| File listing | `System.Threading.Thread` (STA, IsBackground) |
| Log file opening | `System.Threading.Thread` (STA, IsBackground) |
| Global search | `RunspacePool` (1–4 threads, configurable) |
| UI updates from bg | `$window.Dispatcher.Invoke()` |
| Search results poll | `DispatcherTimer` (500ms tick) |

---

## Configuration Files

| File | Purpose | Credentials |
|------|---------|-------------|
| `Servers.json` | Server definitions | ❌ None |
| `QuickPaths.json` | Category paths + user-saved paths | ❌ None |
| `Favorites.json` | Favorites + recent history | ❌ None |
| `Settings.json` | App settings | ❌ None |

---

## Future Enhancement Roadmap

| Feature | Notes |
|---------|-------|
| Windows Event Log Viewer | Read remote event logs via `Get-WinEvent -ComputerName` |
| Multi-server health checks | `Test-ServerConnection` bulk parallel |
| CyberArk service status | `Get-Service -ComputerName` via credential |
| Live tail (follow) | DispatcherTimer polling `Get-LogTail` |
| Saved search templates | Add to Settings.json |
| Log comparison | Diff two files side-by-side |
| Excel export | `ImportExcel` module integration |
| Environment groups | DEV/UAT/PROD server grouping |
| Notepad++ integration | `Start-Process npp` with file path |
| Scheduled searches | Background job + notification |

---

## File Structure

```
SAW\
├── SAW.ps1              ← Entry point
├── SAW.bat              ← Double-click launcher
├── Build\
│   ├── Build-Executable.ps1
│   └── README-Build.md
├── Config\
│   ├── Servers.json
│   ├── QuickPaths.json
│   ├── Favorites.json
│   └── Settings.json
├── Logs\                ← Created at runtime
│   └── SAW_YYYYMMDD.log
├── Modules\
│   ├── AppLogger.psm1
│   ├── Auth.psm1
│   ├── ServerManager.psm1
│   ├── FileExplorer.psm1
│   ├── LogViewer.psm1
│   ├── Search.psm1
│   └── Favorites.psm1
└── UI\
    └── MainWindow.ps1
```
