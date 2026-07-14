# azd-advanced-auditing

`azd-advanced-auditing` is an Azure Developer CLI template that rebuilds the advanced auditing solution from Nathan McNulty's April 2025 guide:

- Blog article: https://nathanmcnulty.com/blog/2025/04/comprehensive-guide-to-configuring-advanced-auditing/
- Source mailbox auditing script: https://github.com/nathanmcnulty/nathanmcnulty/blob/master/ExchangeOnline/Enable-AdvancedAuditing.ps1

The template provisions an Azure Automation account, creates a PowerShell 7.4 runtime environment, publishes runbooks for advanced mailbox auditing, bootstraps the required Exchange Online permissions for the automation managed identity, and runs validation jobs after provisioning.

## What this template deploys

`azd provision` creates and configures:

- An Azure resource group named `rg-<AZURE_ENV_NAME>` by default, or a custom group if `AZURE_RESOURCE_GROUP` is already set in the azd environment
- An Azure Automation account named `aaaudit<environment-suffix>`
- A PowerShell 7.4 runtime environment with Exchange Online dependencies
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
9. Runs both validation runbooks and waits for them to complete.

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

The postprovision hook installs missing PowerShell modules for the current user when needed.

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

During `preprovision`, the template derives the Automation account name from `AZURE_ENV_NAME` and manages Automation `jobSchedule` cleanup so repeated deployments do not break after resource group deletion.

## Repository layout

| Path | Purpose |
| --- | --- |
| `azure.yaml` | azd template entry point and hook wiring |
| `infra\main.bicep` | Azure Automation infrastructure |
| `infra\main.parameters.json` | azd environment parameter mapping |
| `hooks\Common.ps1` | Shared hook helpers |
| `hooks\preprovision.ps1` | Resource naming and `jobSchedule` preparation |
| `hooks\postprovision.ps1` | Exchange bootstrap, runbook publish, and validation |
| `runbooks\Enable-AdvancedAuditing.ps1` | Main scheduled runbook |
| `runbooks\Validate-ExchangeManagedIdentity.ps1` | Managed identity connection validation |
| `runbooks\Validate-AdvancedAuditingConfiguration.ps1` | Mailbox auditing state validation |

## Notes on the rebuilt template

- The Bicep deployment publishes placeholder runbook content first so ARM can create the schedule and runbook linkage deterministically.
- The postprovision hook immediately replaces that placeholder content with the local runbook files from this repository.
- The main runbook is based on the current public `Enable-AdvancedAuditing.ps1` logic and adds support for pulling the Exchange organization value from an Automation variable.
- The validation flow is designed around the limited Exchange RBAC granted to the managed identity, so the validation runbooks focus on mailbox access and auditing values rather than broader tenant-wide cmdlets.

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
