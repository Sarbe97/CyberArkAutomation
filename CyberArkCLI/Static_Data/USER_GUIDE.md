# CyberArk CLI - User Guide

Welcome to the CyberArk CLI! This tool helps you perform common CyberArk tasks quickly without needing deep API or scripting knowledge.

## Getting Started

### 1. Launching the Tool
Run the launcher script -- it automatically checks for updates via Git.

```powershell
.\Start-CyberArkCLI.ps1
```

### 2. Logging In
Select your authentication method:
- **CyberArk (User/Password)**: Vault-specific credentials.
- **LDAP (Domain)**: Company network credentials.
- **SAML (SSO)**: Browser-based Single Sign-On.

### 3. Startup Checks
On launch the CLI validates your `config.json`:
- Ensures `PVWAURL` is configured.
- Creates the `Output` directory if missing.
- Warns if `LDAPDomain` is not set.

### 4. Session Expiry
If your session expires mid-operation, the CLI will automatically prompt you to re-login (using your original login method) and then retry the failed operation -- no work is lost.

---

## Configuration (`config.json`)

Before running the CLI, you **must** edit `config.json` in the tool's root folder. Below is a summary of every setting.

### Required Settings

| Setting | Description | Example |
|---------|-------------|---------|
| `PVWAURL` | **Your CyberArk PVWA base URL.** Must be updated before first use. | `https://cyberark.yourcompany.com` |
| `LDAPDomain` | Your company's LDAP domain. Used for group member lookups and safe operations. | `YOURCOMPANY.COM` |

### Optional Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `IgnoreSSLErrors` | `false` | Set to `true` if your PVWA uses a self-signed certificate. |
| `UserCacheTTL` | `30` | Minutes to cache the user list before refreshing. |
| `LogLevel` | `INFO` | Log verbosity: `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `PersonalSafePattern` | `WI-A-SVC-{userid}` | Naming pattern for personal safes. `{userid}` is replaced at runtime. |
| `GroupsToHide` | *(list)* | Built-in groups hidden from group listings (e.g. `Vault Admins`, `Auditors`). |

### Mail Settings (`Mail` block)

Used by features that send email notifications (e.g. secondary account onboarding).

| Setting | Default | Description |
|---------|---------|-------------|
| `SmtpServer` | `smtp.yourdomain.com` | Your SMTP relay server. |
| `SmtpPort` | `25` | SMTP port. |
| `SmtpFrom` | `cyberark-noreply@yourdomain.com` | Sender address. |
| `SmtpUseSSL` | `false` | Enable SSL for SMTP. |
| `DefaultCC` / `DefaultBCC` | `[]` | Default CC/BCC recipients (array of email addresses). |

### Default Safe Members (`DefaultSafeMembers`)

Groups that are **automatically added** to every new safe created via batch creation. Each entry specifies:
- **Key**: Group name (e.g. `Vault Admins`, `Sailpoint`)
- **PermissionKey**: References a permission preset from `SafePermissionSets`
- **MemberType**: `Group` or `User`

### Safe Permission Presets (`SafePermissionSets`)

Pre-defined permission bundles used when assigning members to safes. Available presets:

| Preset | Typical Use |
|--------|-------------|
| `SAFE_READ` | View-only access (list, retrieve, view audit) |
| `SAFE_READ_WRITE` | Full account management (add, update, delete, manage safe) |
| `VAULT_ADMIN` | Administrative access (manage members, backup, unlock) |
| `USER_ACCESS` | Standard user access (use, retrieve, initiate CPM) |
| `CCP_PROVIDER` / `CCP_APPID` | Application credential retrieval only |

> The `_AvailablePermissions_Reference` field in config.json lists all individual permissions for reference — it is not used by the tool.

---

## Main Menu Overview

| # | Menu | Description |
|---|------|-------------|
| 1 | Session Info | View session status, login method, and user details |
| 2 | System Health | Check component health and export results |
| 3 | User Operations | Lookup users, browse groups, view memberships |
| 4 | User & Group Management | Create/delete groups, add users, reset passwords |
| 5 | Account Operations | Search, onboard, delete, connect via PSM |
| 6 | Safe Operations | Export safes, account counts, consolidated reports |
| 7 | Safe Bulk Activities | Create, rename, manage members, delete safes (batch) |
| 8 | Platform Management | View platforms, export platform packages |
| 9 | Discovery & Onboarding | Search discovered accounts, manage onboarding rules |
| 10 | Application Management | View and search applications |

---

## Session Info (Menu 1)

Displays your current session details:
- Connection status, PVWA URL, and login method (CyberArk/LDAP/SAML)
- Session start time and duration
- User details: name, email, department, user type

---

## System Health (Menu 2)

Checks the health of all CyberArk components and shows their status. Results are automatically exported to `Output/SystemHealth_<timestamp>.csv`.

---

## User Operations (Menu 3)

Read-only utilities for looking up users and groups.

- **Refresh User Cache**: Pull the latest user list from CyberArk.
- **Lookup User**: Search by username or ID.
- **Get All Groups**: Lists all Vault + LDAP groups with optional member details.
- **Get Members of a Group**: Shows who belongs to a specific group.
- **Get Groups of a User**: Shows which groups a user belongs to.

---

## User & Group Management (Menu 4)

This is the dedicated menu for managing groups and user credentials.

### Create Groups (Manual or CSV)
1. Select **User & Group Management** > **Create Groups**.
2. Choose **Manual** (single group) or **CSV** (batch).
3. For CSV, provide columns: `GroupName`, `Description`, `GroupMembers` (comma/semicolon-separated usernames).
4. The tool creates the group and optionally adds users in one step.

### Add Users to Group (Manual or CSV)
1. Select **User & Group Management** > **Add Users to Group**.
2. Choose **Manual** or **CSV**. For CSV, columns: `GroupName`, `UserName`, `MemberType` (defaults to `Vault`).
3. Already-existing memberships are handled gracefully (shown as `[ALREADY MEMBER]`).

### Delete Group (Single)
1. Select **User & Group Management** > **Delete Group (Single)**.
2. Enter the group name. Review the confirmation, then type `Y` to delete.

### Delete Groups (Batch)
1. Select **User & Group Management** > **Delete Groups (Batch)**.
2. Enter a single name or provide a CSV with `GroupName` column.
3. Review summary. Use `-WhatIf` for dry run.

### Reset User Password
1. Select **User & Group Management** > **Reset User Password**.
2. Enter the username, confirm the user, enter a new password (masked input).

---

## Safe Bulk Activities (Menu 7)

### Create Safes (Batch)
1. Select **Safe Bulk Activities** > **Create Safes (from CSV)**.
2. Type `T` to download a **template**.
3. Fill out: **SafeName**, **MemberType** (`User` or `Group`), **PermissionKey**.
4. Run again and provide your filled CSV.

### Rename Safes
1. Select **Safe Bulk Activities** > **Rename Safes**.
2. Provide CSV with `OldSafeName` and `SafeName` (new name).
3. The tool renames the safe and its associated `KA_` groups.

### Delete Safes (Batch)
1. Select **Safe Bulk Activities** > **Delete Safes (Batch)**.
2. Provide a CSV with `SafeName` column, or enter names manually.
3. Review the summary and confirm. Use `-WhatIf` for a dry run.

### Safe Reports (Menu 6)
1. Select **Safe Operations** > **Consolidated Safe Report**.
2. Choose: **Inventory**, **Permissions Audit**, or **Detailed Audit**.

---

## Account Operations (Menu 5)

### Search for Accounts
1. Select **Account Operations** > **Search Accounts**.
2. Search by keyword or safe. Results are saved to `Output/`.

### Onboard Accounts (Batch)
1. Select **Account Operations** > **Batch Onboard Accounts**.
2. Type `T` for a template. Fill out the CSV:
   - Leave `AccountID` **empty** -> CREATE new account.
   - Fill `AccountID` -> UPDATE existing account.
   - Supports `Prop_*`, `SM_*`, `RMA_*` prefixed columns for platform properties.

### Batch Delete Accounts
1. Select **Account Operations** > **Batch Delete Accounts**.
2. Provide a CSV with `AccountID` or `id` column.
3. Review summary and confirm. Use `-WhatIf` for dry run.

### PSM Connect
1. Select **Account Operations** > **Connect via PSM**.
2. Enter the Account ID. The tool generates and optionally launches an `.rdp` file.

---

## Platform Management (Menu 8)

- **Get Platform Details**: Fetch active, inactive, or all platforms. Output as individual files or a single CSV.
- **Get Platform Details (Manual/CSV)**: Provide specific platform names to fetch details.
- **Export Platform Package**: Export platform configuration as a `.zip` package.

---

## Discovery & Onboarding (Menu 9)

- **Get Discovered Accounts**: Search and filter discovered accounts. Results display in a summary table with optional CSV export.
- **Get Onboarding Rules**: View automatic onboarding rules with optional filtering by name.
- **Delete Discovered Accounts**: Purge all discovered accounts (requires typing `DELETE` to confirm).

---

## Application Management (Menu 10)

- **List All Applications**: Displays all registered applications with optional CSV export.
- **Get Application Details**: Look up a specific application by ID.
- **Get Auth Methods**: View authentication methods configured for an application.
- **Search Applications**: Search by AppID or description.

---

## Tips & Tricks

- **Templates**: Most batch operations let you type `T` to download a template CSV.
- **File Picker**: When prompted for a CSV, a file dialog opens automatically. Falls back to manual path entry if needed.
- **Dry Run**: Add `-WhatIf` to any batch delete command to simulate without making changes.
- **Output Folder**: All reports, logs, and exports are saved in the `Output/` folder.
- **Git Sync**: Always use `Start-CyberArkCLI.ps1` to launch -- it warns if you're out of date.

## Troubleshooting

| Error | Solution |
|-------|----------|
| **"CSV file not found"** | Use full path. Quote paths with spaces: `"C:\My Folder\file.csv"` |
| **"403 Forbidden"** | Your account lacks permissions for this action. Contact your CyberArk admin. |
| **"Login Failed"** | Check credentials. For LDAP, ensure VPN is active. For SAML, complete the browser sign-in. |
| **"Session expired"** | The CLI will auto-prompt for re-login. Just authenticate again. |
