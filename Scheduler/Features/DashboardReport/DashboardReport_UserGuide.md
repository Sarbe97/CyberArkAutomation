# CyberArk Dashboard Reporting - Team Walkthrough Guide

This document provides a non-technical overview of the **CyberArk Dashboard Reporting** tool, explaining what it does, the reports it generates, and how it is scheduled. 

---

## 1. What is the CyberArk Dashboard Report?
The CyberArk Dashboard Report is an automated utility that runs daily to monitor the status and health of our CyberArk PAM (Privileged Access Management) environment. It collects inventory data, tracks onboarded safes and platforms, identifies password rotation issues, and delivers daily updates to the team.

Instead of requiring team members to manually log into CyberArk to check for errors or pull inventory lists, this tool compiles everything automatically and sends a digest directly to your inbox every morning.

---

## 2. Key Features & Business Value

### A. Account Failure Tracking & Delta Comparison
The tool's most critical feature is how it handles password management failures (e.g., accounts that cannot rotate their passwords). It compares today’s failures with yesterday’s failures to classify them:
*   🟢 **Fixed (Green)**: Accounts that were failing yesterday but have been successfully rotated or resolved. This helps the team measure daily progress.
*   🔴 **New (Red)**: Newly failing accounts that requires immediate investigation.
*   🟡 **Existing (Yellow)**: Legacy failures that remain unresolved.

### B. Intelligent Filtering & Target Tracking
*   **Exclusions**: It filters out expected failures (e.g., test platforms or specific non-production servers) to reduce noise.
*   **High-Priority Tracking**: You can configure it to explicitly flag critical service or admin accounts (like `admin`, `svc_backup`, `sql_svc`), making sure high-risk failures are never missed.

### C. Discovery Pipeline Monitoring
It checks for pending discovered accounts waiting to be onboarded. This allows our team to quickly identify newly added assets across the network that need to be brought under CyberArk management.

### D. Inventory & Migration Statistics
It tracks the progress of our migration and onboarding initiatives by categorizing:
*   Shared Safes vs. Personal Safes.
*   Migrated Safes/Platforms (identified by specific keywords in their names).
*   Active vs. In-use platforms.

---

## 3. Daily Deliverables (What the Team Receives)

Every morning, the team will receive an email containing the following deliverables:

### A. Interactive HTML Email Summary
The email body displays a quick-reference dashboard showing key counts (Total Accounts, Failed Accounts, Safes, and Platforms). 
*   **Trend Indicators**: The email shows previous day counts and color-coded changes (e.g., `+5` or `-2`).
*   **Status Indicators**: 
    *   An increase in **Failed Accounts** or **Pending Discovered** accounts will trigger a red warning indicator (`trend-bad`).
    *   A decrease in **Failed Accounts** will trigger a green success indicator (`trend-good`).

> **[Insert Screenshot of HTML Email Report Here]**

### B. Color-Coded Excel Remediation Sheet (`DashboardFailedComparison_*.xls`)
Attached to the email is an Excel sheet designed specifically for operational tasks. It contains all failed accounts categorized by their remediation status:
*   **Green rows** show issues that were successfully resolved in the last 24 hours.
*   **Red rows** highlight new issues that need immediate action.
*   **Yellow rows** show continuing failures.

> **[Insert Screenshot of Color-Coded Excel Report Here]**

### C. Detailed Report Archive (`DashboardReports_*.zip`)
For deeper analysis, the email attaches a ZIP archive containing raw detailed data in CSV format:
1.  `DashboardInventoryDetails_*.csv`: Full list of all accounts and their categories.
2.  `DashboardSafesDetails_*.csv`: Full inventory of safes (shared, personal, migrated).
3.  `DashboardPlatformsDetails_*.csv`: Full list of active platforms and their usage.
4.  `DashboardFailedAccountsDetails_*.csv`: Full list of all failing accounts.
5.  `DashboardDiscoveryPendingDetails_*.csv`: Accounts pending auto-onboarding or review.
6.  `DashboardCounts_*.csv`: The raw summary numbers.

---

## 4. Hosting & Scheduled Execution

To ensure daily execution without human intervention, the script is scheduled on a dedicated server.

*   **Server Name**: **Server A** (e.g., our primary automation utility server)
*   **Task Type**: Windows Task Scheduler
*   **Trigger Time**: Daily at **01:00 AM**
*   **Task Action**: Runs the PowerShell script in a bypassed execution policy mode.
*   **Code Location (Dummy)**: `C:\Path\To\Scheduler\DashboardReport.ps1` *(Note: Replace this with the actual installation directory, e.g., D:\CyberArkAutomation\Scheduler\Features\DashboardReport\)*

### Active Windows Task Configuration:
*   **Program/script**: `powershell.exe`
*   **Add arguments**: `-ExecutionPolicy Bypass -File "C:\Path\To\Scheduler\DashboardReport.ps1"`
*   **Run rules**: "Run whether user is logged on or not" with administrative privileges.

> **[Insert Screenshot of Windows Task Scheduler Task Settings Here]**

---

## 5. Configuration Settings (`config.json`)

The tool’s behavior can be customized by editing the `config.json` file in the feature directory. Key settings include:

*   **`Email.To`**: A list of email addresses that will receive the daily report.
*   **`Cleanup.RetentionDays`**: The number of days the script will store old logs and reports on the server before deleting them to conserve disk space (defaults to `30`).
*   **`FailedAccountExcludePlatforms`**: Platforms list to be ignored from the password failure reports.
*   **`TrackedFailedAccounts`**: Critical accounts that require dedicated visibility in the email summary if they fail.
*   **`SharePoint`**: If enabled, the script can automatically upload a copy of the summary dashboard to our SharePoint document portal.
