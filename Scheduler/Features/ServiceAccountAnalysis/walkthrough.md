# Service Account Analysis

The `ServiceAccountAnalysis` feature has been implemented to discover user accounts in Active Directory domains and filter out personal accounts using regex patterns, leaving only "Service Accounts". It acts primarily as a discovery and reporting tool, with built-in functionality to send summary emails.

## Implemented Components

### 1. Feature Configuration
The main configuration file `Scheduler/Features/ServiceAccountAnalysis/config.json` sets up the operational behavior:
- **Domains**: A list of AD domains to query for user accounts.
- **PersonalAccount.Pattern**: The regex pattern `^[A-Za-z]\d{6}$` used to identify and filter out personal (primary and secondary) accounts.
- **Exclusions**: Contains the ability to exclude entire domains or specific username patterns (e.g., `krbtgt`).
- **Notifications**: Configures the email recipients who will receive the summary report.

### 2. ServiceAccountAnalysis Orchestrator
The main script `ServiceAccountAnalysis.ps1` runs the core logic:
1. Load global settings and feature-specific settings.
2. Coordinate with `SVC_DataCollection.ps1` to query the AD domains.
3. Organize the discovered Service Accounts and write them to `Output/SVC_AnalysisReport_YYYYMMDD_HHMMSS.csv`.
4. Trigger the summary email via `SVC_Notifications.ps1` using the `RunSummary.html` template.

### 3. Data Collection Module
The module `Modules/SVC_DataCollection.ps1` contains the key functionality for interacting with AD:
- Supports authentication via direct credentials or the CyberArk Central Credential Provider (CCP).
- Uses `Get-ADUser` to fetch all enabled/disabled accounts.
- Iterates over all users and eliminates any that match the `PersonalAccount.Pattern` or username exclusion lists.
- Implements a caching mechanism to avoid re-querying AD if the script is run multiple times on the same day.

### 4. Notifications Module & Template
The module `Modules/SVC_Notifications.ps1` leverages the global `Send-SchedulerEmail` function:
- Replaces tokens in the `Templates/RunSummary.html` template.
- Attaches the resulting `SVC_AnalysisReport_*.csv` file.
- Dispatches the email to the administrators specified in `config.json`.

## Verification
- The directory structure and code modules were generated accurately to mirror existing scheduler features.
- A baseline syntax check on the main orchestrator script succeeded without errors.
- The regex used `^[A-Za-z]\d{6}$` effectively captures both typical primary (e.g. `U123456`) and secondary accounts (e.g. `A123456`, `M123456`), successfully keeping only the true Service Accounts.
