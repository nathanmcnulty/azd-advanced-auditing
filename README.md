# azd-advanced-auditing

`azd-advanced-auditing` is an Azure Developer CLI template that rebuilds the advanced auditing solution from Nathan McNulty's April 2025 guide:

- Blog article: https://nathanmcnulty.com/blog/2025/04/comprehensive-guide-to-configuring-advanced-auditing/
- Source mailbox auditing script: https://github.com/nathanmcnulty/nathanmcnulty/blob/master/ExchangeOnline/Enable-AdvancedAuditing.ps1

The template provisions an Azure Automation account, creates a PowerShell 7.6 runtime environment, publishes runbooks for advanced mailbox auditing, bootstraps the required Exchange Online permissions for the automation managed identity, and runs validation jobs after provisioning.

## What this template deploys

`azd provision` creates and configures:

- An Azure resource group named `rg-<AZURE_ENV_NAME>` by default, or a custom group if `AZURE_RESOURCE_GROUP` is already set in the azd environment
- An Azure Automation account named `aaaudit<environment-suffix>`
- A PowerShell 7.6 runtime environment with ExchangeOnlineManagement 3.10.1 or newer
- Three Automation runbooks:
  - `Enable-AdvancedAuditing`
  - `Validate-ExchangeManagedIdentity`
  - `Validate-AdvancedAuditingConfiguration`
- A daily Automation schedule linked to `Enable-AdvancedAuditing`
- Automation variables used by the runbooks, including the tenant Exchange organization value

## What postprovision does

After the Azure resources exist, `hooks\postprovision.ps1` performs the tenant bootstrap that cannot be modeled entirely in ARM or Bicep:

1. Connects to Microsoft Graph, Exchange Online, and Security & Compliance PowerShell.
2. Resolves the tenant's initial `*.onmicrosoft.com` domain for managed identity Exchange connections.
3. Enables unified audit log ingestion if it is disabled.
4. Creates a one-year unified audit log retention policy named `All Records - 1 Year` if it does not already exist.
5. Grants `ExchangeManageAsApp` to the Automation account managed identity.
6. Creates the linked Exchange service principal.
7. Creates or repairs the limited `Mailbox Auditing` management role and `Advanced Auditing Management` role group.
8. Publishes the local runbook files from this repository into Azure Automation.
9. Validates managed identity connectivity before attempting remediation.
10. Runs remediation, then validates the complete expected mailbox auditing configuration and reports any mailbox audit bypass associations.

## Prerequisites

You need:

- Azure CLI and Azure Developer CLI (`azd`)
- PowerShell 7
- An Azure subscription where you can create Automation resources
- Exchange Online administrative access capable of creating the role, role group, service principal link, and audit retention policy
- Microsoft Graph consent for:
  - `Application.Read.All`
  - `AppRoleAssignment.ReadWrite.All`
  - `Domain.Read.All`

The postprovision hook installs ExchangeOnlineManagement 3.10.1 or newer for the current user when needed.

## Usage

1. Sign in to Azure:

   ```powershell
   az login
   azd auth login
   ```

2. Create or select an azd environment:

   ```powershell
   azd env new
   ```

3. Provision the template:

   ```powershell
   azd provision
   ```

During `preprovision`, the template derives the Automation account name from `AZURE_ENV_NAME` and manages Automation `jobSchedule` cleanup so repeated deployments do not break after resource group deletion. These generated values are passed explicitly to Bicep so redeployments use the prepared account name, timestamp, and stable job-schedule identifier.

Use `azd down` to remove the deployment. A `predown` hook removes the template's `CanNotDelete` lock from the Automation account before resource-group deletion.

## Product coverage

| Area | Coverage |
| --- | --- |
| Unified audit ingestion | Verified and enabled tenant-wide when necessary |
| Audit retention | Creates and verifies an all-users, all-record-types, one-year custom policy when Security & Compliance PowerShell authentication is available |
| Exchange mailbox actions | Configures the complete expected admin, delegate, and owner action sets on every user mailbox |
| Mailbox audit bypass | Validation fails and reports every bypass-enabled association |
| SharePoint, OneDrive, Teams, Microsoft Entra, Dynamics 365, and Power Platform | Their records are covered by unified audit ingestion and the all-record-types retention policy; these products do not expose equivalent per-mailbox action lists for this template to manage |
| Licensing | Microsoft applies the effective retention period according to the license assigned to the user who generated each event |

If Security & Compliance PowerShell authentication is unavailable during provisioning, the hook completes with an explicit degraded warning and identifies the retention policy that must be configured and validated manually. Mailbox remediation or validation failures remain fatal.

## Repository layout

| Path | Purpose |
| --- | --- |
| `azure.yaml` | azd template entry point and hook wiring |
| `infra\main.bicep` | Azure Automation infrastructure |
| `infra\main.parameters.json` | azd environment parameter mapping |
| `hooks\Common.ps1` | Shared hook helpers |
| `hooks\preprovision.ps1` | Resource naming and `jobSchedule` preparation |
| `hooks\postprovision.ps1` | Exchange bootstrap, runbook publish, and validation |
| `hooks\predown.ps1` | Automation account lock cleanup before teardown |
| `runbooks\Enable-AdvancedAuditing.ps1` | Main scheduled runbook |
| `runbooks\Validate-ExchangeManagedIdentity.ps1` | Managed identity connection validation |
| `runbooks\Validate-AdvancedAuditingConfiguration.ps1` | Mailbox auditing state validation |

## Notes on the rebuilt template

- The Bicep deployment publishes placeholder runbook content first so ARM can create the schedule and runbook linkage deterministically.
- The postprovision hook immediately replaces that placeholder content with the local runbook files from this repository.
- The main runbook is based on the current public `Enable-AdvancedAuditing.ps1` logic and adds support for pulling the Exchange organization value from an Automation variable.
- The validation flow is designed around the limited Exchange RBAC granted to the managed identity. It validates every user mailbox by default, compares the complete expected auditing action sets, checks `AuditEnabled` and the audit age limit, and reports mailbox audit bypass associations. Tenant-wide ingestion and retention settings are validated by the authenticated bootstrap hook.
- The Automation runtime is pinned to ExchangeOnlineManagement 3.10.1, and all runbooks reject older versions.
- ExchangeOnlineManagement 3.10.0 and later require PowerShell 7.6. The template therefore uses Azure Automation PowerShell 7.6 rather than the previously tested, unsupported PowerShell 7.4 and ExchangeOnlineManagement 3.10.1 combination.
- Failed Automation jobs print their available output streams and exception details before provisioning exits.

## Development validation

The repository includes Pester tests and a GitHub Actions workflow that:

- parses every PowerShell file
- runs PSScriptAnalyzer errors
- verifies runtime and azd parameter wiring
- checks remediation and validation action lists remain aligned
- builds Bicep and verifies `infra\main.json` is current

## Previously validated execution path

The recovered implementation was previously validated end-to-end in a fresh environment named `exec05180009`, which provisioned:

- Resource group: `rg-audit-05180009`
- Automation account: `aaaudit05180009`

That execution also verified the fixes now preserved in this repository for:

- dynamic schedule start times
- tenant primary-domain lookup
- PowerShell URI interpolation
- ARM job-schedule linking
- Exchange role-group membership handling

## ExchangeOnlineManagement retest status

The `exec06301350` environment was redeployed with ExchangeOnlineManagement 3.10.1. The Automation runtime reported version 3.10.1, and `Validate-ExchangeManagedIdentity` completed successfully. `Enable-AdvancedAuditing` still failed at `Set-Mailbox` with `Microsoft.Exchange.Configuration.Tasks.CmdletNeedsProxyException`.

That environment used PowerShell 7.4, but Microsoft now documents that ExchangeOnlineManagement 3.10.0 and later require PowerShell 7.6. The old result is therefore retained as historical evidence but is not a supported-platform determination. The template now deploys PowerShell 7.6 so the next end-to-end deployment can establish whether the Exchange behavior still reproduces on a supported combination. Track the result in [GitHub issue #1](https://github.com/nathanmcnulty/azd-advanced-auditing/issues/1).

References:

- Exchange Online PowerShell module requirements: https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2
- Azure Automation supported runbook runtimes: https://learn.microsoft.com/azure/automation/automation-runbook-types
- Mailbox auditing configuration: https://learn.microsoft.com/purview/audit-mailboxes
- Audit log retention policies: https://learn.microsoft.com/purview/audit-log-retention-policies
