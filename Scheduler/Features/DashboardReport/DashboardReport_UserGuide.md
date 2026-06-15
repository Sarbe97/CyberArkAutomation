# CyberArk Dashboard Reporting - Overview

## 1. Overview & Functionality
The `DashboardReport.ps1` script provides automated daily visibility into the CyberArk environment. Its primary functions include:
*   **Inventory Tracking**: Categorizes accounts by Domain, CPM status, and Creation source.
*   **Failure Analysis**: Identifies accounts failing password management.
*   **Delta Comparison**: Automatically compares today's failures with yesterday's to highlight what was fixed and what is new.

---

## 2. User Deliverables (What you see)

### A. Daily Email Summary
Each morning, the team receives a high-level summary. It uses trend indicators (arrows) to show if metrics like "Failed Accounts" have improved or worsened compared to the previous day.

> **[PLACEHOLDER: Insert Screenshot of the HTML Email Report here]**

### B. Failure Comparison Report (Excel)
Attached to the email is a color-coded Excel file (`.xls`) for quick remediation:
*   **Green**: Issues resolved in the last 24 hours.
*   **Red**: New failures that require immediate attention.
*   **Yellow**: Existing failures that are still pending.

> **[PLACEHOLDER: Insert Screenshot of the Color-Coded Excel Report here]**

### C. Detailed ZIP Archive
The email also includes a ZIP file containing the raw data for every account, safe, and platform in the environment for deep-dive analysis.

---

## 3. Configuration & Scheduling

### A. Configuration (`config.json`)
Settings that control the report are managed in the `Scheduler/config.json` file:
*   **Recipients**: Managed under the `Email.To` section.
*   **Exclusions**: Platforms to ignore are listed in `FailedAccountExcludePlatforms`.
*   **Tracked Accounts**: Specific high-priority accounts are monitored in the `TrackedFailedAccounts` list.
*   **Cleanup**: Controls log and output data retention limits (e.g., `RetentionDays`).

### B. Scheduling
The report is scheduled on **Server A** via Windows Task Scheduler.
*   **Execution**: Daily at 01:00 AM.
*   **Command**: `powershell.exe -ExecutionPolicy Bypass -File "C:\Path\To\Scheduler\DashboardReport.ps1"`

> **[PLACEHOLDER: Insert Screenshot of Windows Task Scheduler Configuration here]**
