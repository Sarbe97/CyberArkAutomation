# Safe Analysis Feature

The `SafeAnalysis` feature automates the auditing and remediation of permissions across CyberArk safes. It validates that all safes adhere to a standardized corporate permissions model, identifying deviations, missing core members, or improper owner permissions on Personal Safes. 

## Implemented Components

### 1. Feature Configuration
The `Scheduler/Features/SafeAnalysis/config.json` sets the compliance rules:
- **Mode Execution**: Operates in `Analysis`, `Remediation`, or `Simulation` modes.
- **CommonSafeMembers**: Defines the users or groups (e.g., `CyberArk Admins`) that **must** exist on every scanned safe, along with their expected `PermissionSet`.
- **Personal Safes**: 
  - Uses the `Pattern` regex (e.g. `^S-A-PR-WI-U\d{6}$`) to identify personal safes.
  - Dynamically extracts the primary owner using `OwnerExtractionRegex` to verify that the target owner is a member with the exact `OwnerPermissionSet`.
- **Exclusions**: Prevents auditing of built-in system safes (like `System` or `PasswordManager`) and any defined exception safes.

### 2. Orchestrator Script
`SafeAnalysis.ps1` manages the workflow phases:
1. **Discovery & Analysis**: Iterates over every non-excluded safe, checking its members against the required `CommonSafeMembers` and (if applicable) its dynamically calculated Primary Owner.
2. **Remediation**: If `Mode` is set to `Remediation` and deviations are found, it invokes the CyberArk API to add the missing member or merge in the missing permissions.
3. **Summary Notifications**: Dispatches an email report listing the compliance breakdown and attaches detailed CSVs (`SAFE_AnalysisReport.csv` and `SAFE_RemediationResults.csv`).

### 3. Data Collection Module
`Modules/SAFE_DataCollection.ps1` focuses on querying the CyberArk REST API:
- `Get-SAFEAllSafes`: Retrieves all safes and filters them against the `Exclusions` list.
- `Get-SAFESafeMembers`: Fetches the existing members and their explicit boolean permissions for a specific safe.

### 4. Operations Module
`Modules/SAFE_SafeOperations.ps1` acts as the execution arm for remediation:
- `Invoke-SAFEUpdateSafeMember`: Constructs a JSON payload of required permissions and issues a `POST` (for new members) or `PUT` (for existing members missing certain permissions) request to the CyberArk API.

### 5. Notifications Module & Templates
`Modules/SAFE_Notifications.ps1` controls the alerting:
- Integrates with the global `Send-SchedulerEmail` function.
- Populates the `Templates/RunSummary.html` template with live statistics (Total Safes, Compliant Safes, Remediation Actions).

## Verification & Execution Safety
- **Simulation First**: By default, the `Mode` is `Simulation`. The script fully maps out what is missing and generates the `SafeAnalysisReport.csv`, but it strictly blocks any API calls that would mutate safe permissions.
- **Merge-Only Updates**: When a member exists but lacks certain permissions, the logic identifies only the *missing* permissions and issues an update to ensure no existing access is accidentally overwritten or removed. Extra permissions not defined in the baseline are ignored to prevent breaking custom (but approved) additions.
