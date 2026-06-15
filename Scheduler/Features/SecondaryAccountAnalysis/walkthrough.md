# Secondary Account Analysis

The `SecondaryAccountAnalysis` feature automates the discovery, analysis, and onboarding of secondary/admin Active Directory accounts into CyberArk personal safes. It ensures that privileged secondary accounts are properly managed, linked to their primary owners, and provisioned with the right permissions.

## Implemented Components

### 1. Feature Configuration
The main configuration file `Scheduler/Features/SecondaryAccountAnalysis/config.json` governs the entire workflow:
- **Mode Execution**: Supports multiple modes (`Discovery`, `Analysis`, `Onboarding`, `Simulation`) allowing safe testing before making changes in CyberArk.
- **Account Definitions**: 
  - `PrimaryAccount`: Defined by a regex pattern (e.g., `^U\d{6}$`). Must be present in the primary domain.
  - `SecondaryAccount`: Defined by specific prefixes (e.g., A, I, M, S, W) and an overarching regex `^[A-Za-z]\d{6}$`.
- **Personal Safes**: Specifies the naming convention for the personal safes (e.g., `S-A-PR-WI-{PrimaryAccount}`) and the permission sets granted to the primary owner.
- **Domains**: A list of AD domains to query for primary and secondary accounts, with support for specific platform IDs.
- **Notifications**: Configures email recipients for administrative summaries and controls user notification behavior.
- **Cleanup**: Controls log and output data retention limits (e.g., `RetentionDays`).

### 2. SecondaryAccountAnalysis Orchestrator
The main script `SecondaryAccountAnalysis.ps1` runs the workflow in distinct phases:
1. **Phase 1: Discovery**: Gathers AD data (primary users, secondary accounts, AD group members) and CyberArk data (existing safes, onboarded accounts, licensed users).
2. **Phase 2: Analysis**: Maps secondary accounts to primary accounts using the employee number. Categorizes the status of each secondary account (e.g., `Managed`, `NeedsAll`, `NeedsOnboarding`, `MissingPrimary`, `MissingGroupAccess`). Generates detailed CSV reports.
3. **Phase 3: Onboarding & API Calls**: 
   - Provisions new personal safes for primary users who don't have them.
   - Onboards the unmanaged secondary accounts into the corresponding personal safe.
4. **Phase 3B: User Notifications**: Sends an automated email to each primary user listing the accounts that were successfully provisioned for them.
5. **Phase 4: Run Summary**: Sends a consolidated report to the PAM Administrators outlining license utilization, status breakdowns, and attaches the generated CSVs.
6. **Phase 5: Cleanup**: Automatically removes `.log` files and `Output` date-folders older than the configured `RetentionDays` to prevent uncontrolled disk growth.

### 3. Data Collection Module
`Modules/SAA_DataCollection.ps1` handles robust, cached data retrieval:
- Queries the primary domain for `U-prefix` accounts and the required AD access group.
- Iterates across all configured domains to find secondary prefix accounts.
- Queries the CyberArk REST API to map current safe states and consumed EPV licenses.
- Caches raw data locally to allow quick re-runs and prevent unnecessary strain on AD/CyberArk.

### 4. Safe Operations Module
`Modules/SAA_SafeOperations.ps1` manages the CyberArk state changes:
- `Invoke-SAASafeProvisioning`: Creates a new safe and adds the primary AD user with specific access permissions (e.g., `USER_ACCESS`).
- `Invoke-SAAAccountOnboard`: Onboards the secondary AD credential into the provisioned safe using the assigned target platform.

### 5. Notifications Module & Templates
`Modules/SAA_Notifications.ps1` dispatches context-aware emails:
- `Send-SAAUserSuccessNotification`: Uses `Templates/UserNotification_Success.html` to notify end-users.
- `Send-SAARunSummary`: Uses `Templates/RunSummary.html` to alert administrators, including license consumption tracking and onboarding statistics.

## Verification & Safety
- **Simulation Mode**: By default, the script runs in Simulation mode, meaning all AD and CyberArk queries are performed, but **no** safes are created and **no** accounts are onboarded. This generates the expected analysis reports without altering the environment.
- **Group Requirement Check**: Ensures the primary owner is part of the designated Active Directory group (e.g., `kapamprodusers`) before provisioning safes or onboarding accounts, keeping access tightly controlled.
