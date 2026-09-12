# Technical reference

## Components

`azd up` creates an Azure resource group, an Azure Automation account, a PowerShell 7.6 runtime with ExchangeOnlineManagement 3.10.1 or newer, a daily schedule, Automation variables, and three runbooks:

- `Enable-AdvancedAuditing`;
- `Validate-ExchangeManagedIdentity`;
- `Validate-AdvancedAuditingConfiguration`.

The post-provision hook resolves the initial `*.onmicrosoft.com` domain, enables unified audit ingestion when necessary, creates the `All Records - 1 Year` retention policy when absent and supported, grants `ExchangeManageAsApp`, creates the Exchange service-principal link, creates or repairs the limited `Mailbox Auditing` role and `Advanced Auditing Management` role group, publishes the runbooks, validates connectivity, runs remediation, and validates the final state.

The Bicep layer initially publishes placeholder runbook content so ARM can create schedule linkage deterministically. The hook replaces it with the reviewed local files immediately after provisioning.

## Permissions

The Azure/Exchange operator needs an Azure subscription where they can create Automation resources, Exchange authority to create the role, role group, service-principal link, and audit retention policy, and a Graph session with delegated consent for:

- `Application.Read.All`;
- `AppRoleAssignment.ReadWrite.All`;
- `Domain.Read.All`.

These delegated Graph permissions are a separate consent boundary. Security Administrator, Exchange Administrator, and Azure RBAC do not grant Graph consent. Route Microsoft Graph API consent for the deployment client to a **Global Administrator or Privileged Role Administrator**, then run the hook with a context that contains the scopes above. If that context is not available, Azure infrastructure may be created while publication, Exchange linking, remediation, or validation remains incomplete.

The runtime managed identity receives the limited Exchange authority required by the runbooks. Failed jobs print their available output streams and exception details before provisioning exits.

## Product coverage

| Area | Coverage |
| --- | --- |
| Unified audit ingestion | Verified and enabled tenant-wide when necessary |
| Audit retention | Creates and verifies an all-users, all-record-types, one-year custom policy when Security & Compliance authentication is available |
| Exchange mailbox actions | Configures the complete expected admin, delegate, and owner action sets on every user mailbox |
| Mailbox audit bypass | Validation fails and reports every bypass-enabled association |
| Other Microsoft 365 workloads | Covered by unified ingestion and the all-record-types retention policy; no equivalent per-mailbox action list is managed |
| Effective retention | Determined by Microsoft according to the license assigned to the user who generated each event |

## Deployment mechanics

The pre-provision hook derives the Automation account name from `AZURE_ENV_NAME`, prepares a stable schedule identifier, and handles stale Automation `jobSchedule` state so a redeployment after resource-group deletion does not fail. The pre-down hook removes the template-owned `CanNotDelete` lock.

The main runbook is based on the public [Enable-AdvancedAuditing.ps1](https://github.com/nathanmcnulty/nathanmcnulty/blob/master/ExchangeOnline/Enable-AdvancedAuditing.ps1) and reads the Exchange organization from an Automation variable. Remediation and validation use aligned mailbox-action lists and report bypass associations.

## Supported-platform retest

An older environment validated Azure deployment, schedule timing, domain lookup, URI interpolation, job-schedule linkage, and Exchange role-group handling. Its PowerShell 7.4 runtime with ExchangeOnlineManagement 3.10.1 successfully connected through managed identity but failed `Set-Mailbox` with `CmdletNeedsProxyException`.

Microsoft now documents that ExchangeOnlineManagement 3.10.0 and later require PowerShell 7.6. The old result is historical evidence, not a supported-platform determination. The template now uses PowerShell 7.6; [issue #1](https://github.com/nathanmcnulty/azd-advanced-auditing/issues/1) tracks the next authorized end-to-end retest.

References:

- [Exchange Online PowerShell module requirements](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2)
- [Azure Automation runbook runtimes](https://learn.microsoft.com/azure/automation/automation-runbook-types)
- [Mailbox auditing](https://learn.microsoft.com/purview/audit-mailboxes)
- [Audit log retention policies](https://learn.microsoft.com/purview/audit-log-retention-policies)
