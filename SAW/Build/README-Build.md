# SAW Build & Deployment Guide

## Prerequisites

| Requirement | Details |
|-------------|---------|
| PowerShell | 5.1 or later |
| Windows    | Windows 10 / Server 2016+ |
| .NET       | 4.7.2+ (for WPF) |
| PS2EXE     | Optional — only for .exe packaging |

---

## Running from Source (Recommended for Development)

**Option 1 — Double-click launcher:**
```
SAW.bat
```

**Option 2 — PowerShell directly:**
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\SAW\SAW.ps1"
```

**Option 3 — From VS Code / IDE:**
Open `SAW.ps1` and press **F5** (or run in terminal).

---

## Building a Standalone .exe

### Step 1: Install PS2EXE
```powershell
Install-Module -Name ps2exe -Scope CurrentUser -Force
```

### Step 2: Run the build script
```powershell
.\Build\Build-Executable.ps1
```

Output will be in: `SAW\dist\SAW\SAW.exe`

### Step 3: Distribute
Copy the entire `dist\SAW\` folder to target machine. All required files are included:
```
SAW\
├── SAW.exe         ← Launcher
├── Modules\        ← Business logic
├── UI\             ← WPF window code
├── Config\         ← Configuration files
└── Logs\           ← Created at runtime
```

---

## Execution Policy

If PowerShell execution policy blocks the script:
```powershell
# Run once as administrator to allow script execution:
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

Or use the `.bat` launcher which passes `-ExecutionPolicy Bypass` automatically.

---

## Configuration

Edit `Config\Servers.json` to add your real servers before distribution.

> **NEVER** put passwords or credentials in any config file.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Access Denied" on UNC path | Verify privileged account credentials and share permissions |
| WPF won't load | Ensure .NET 4.7.2+ is installed |
| Slow search | Reduce file pattern scope or limit search to fewer servers |
| Log file not found | Check `Logs\` directory — created automatically on first run |

---

## Future Enhancement: Packaging as MSIX

For enterprise deployment via Intune/SCCM, the PS2EXE `.exe` can be wrapped in an MSIX package using the MSIX Packaging Tool.

---

## Security Notes

- ✅ Credentials stored in-memory only (`[PSCredential]`)
- ✅ Passwords are `[SecureString]` at all times
- ✅ Application log never writes passwords or tokens
- ✅ UNC drives are temporary (created and removed per operation)
- ✅ No registry writes for credentials
- ✅ Favorites.json and Settings.json contain zero credential data
