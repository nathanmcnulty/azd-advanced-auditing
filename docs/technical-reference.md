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

## Operator target checks

Set `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` in the selected azd environment
before running the hooks, including teardown. Operator hooks require public-cloud,
user-account context. They validate explicit selectors, scoped token metadata and
fresh ARM subscription identity, tenant and case-sensitive `Enabled` state. The
first successful target and actor are pinned for that hook invocation; context
drift, failed reads and malformed metadata stop subsequent writes. Cached
`az account show` state alone is not accepted. No global CLI default is changed.

Each persistent azd value, Graph request, Automation variable/content/publication/
job mutation and lock deletion checks the selected target. Exchange and Purview
mutation boundaries additionally verify native session identity, active state and
public-cloud endpoint and command-to-session module ownership, including after the existing normal browser/organization
fallbacks. Purview imports only the two retention commands so its shared role
commands cannot replace the Exchange commands. Authentication unavailability still leaves retention degraded; target
or session mismatch is a fatal safety failure rather than an authentication
workaround. Hosted managed-identity runbooks are unchanged and require no new
subscription Reader grant.

The small solution-owned `hooks/AuditOperatorTarget.ps1` adapts the reviewed
[canonical operator guard](https://github.com/nathanmcnulty/azd-reference/blob/59522c4ebeb5b8fda8bc53c59959dd825ddfa4be/components/powershell/security-automation-runtime/Azd.SecurityAutomation.psm1).
No unrelated runtime/host component or cross-repository runtime fetch is added.
The existing immutable component pins, permissions and deployment defaults remain
unchanged. Native session fields follow Microsoft's
[Get-ConnectionInformation contract](https://learn.microsoft.com/powershell/module/exchangepowershell/get-connectioninformation).
Offline tripwire tests establish source behavior only; the supported-platform
Exchange/Purview acceptance gates and prior failed probe evidence remain open.

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

The pre-provision hook derives the Automation account name from `AZURE_ENV_NAME` and verifies an existing account against the account ID, managed-identity principal ID, and template schedule association stored in the local azd ownership receipt. It reuses the verified jobSchedule GUID without deleting the live linkage before ARM deployment, so a failed redeployment leaves the previous schedule connected. A fresh account gets a new GUID, including after resource-group deletion. The pre-down hook removes the template-owned `CanNotDelete` lock.

An existing account without a receipt stops before deployment. For a legacy template account, an operator must inspect the live account and set `AUTOMATION_ADOPT_ACCOUNT_ID` and `AUTOMATION_ADOPT_PRINCIPAL_ID` to its exact IDs. If the template schedule `advanced-auditing-daily` is already linked to `Enable-AdvancedAuditing`, the operator must also set `AUTOMATION_ADOPT_JOB_SCHEDULE_ID` to that linkage's GUID. Unrelated schedules remain untouched; multiple matching links, a changed principal, a mismatched schedule/runbook, or an incomplete listing stop deployment for manual reconciliation. After ARM provisions the exact association, postprovision records `AUTOMATION_OWNED_ACCOUNT_ID`, `AUTOMATION_OWNED_PRINCIPAL_ID`, and `AUTOMATION_OWNED_JOB_SCHEDULE_ID` in the local azd environment. A later failed postprovision step can be retried only after all three receipt values were persisted. If receipt writing was interrupted, verify and reconcile the exact live account and linkage before retrying.

The main runbook is based on the public [Enable-AdvancedAuditing.ps1](https://github.com/nathanmcnulty/nathanmcnulty/blob/master/ExchangeOnline/Enable-AdvancedAuditing.ps1) and reads the Exchange organization from an Automation variable. Remediation and validation use aligned mailbox-action lists and report bypass associations.

## Supported-platform retest

An older environment validated Azure deployment, schedule timing, domain lookup, URI interpolation, job-schedule linkage, and Exchange role-group handling. Its PowerShell 7.4 runtime with ExchangeOnlineManagement 3.10.1 successfully connected through managed identity but failed `Set-Mailbox` with `CmdletNeedsProxyException`.

Microsoft now documents that ExchangeOnlineManagement 3.10.0 and later require PowerShell 7.6. The old result is historical evidence, not a supported-platform determination. The template now uses PowerShell 7.6; [issue #1](https://github.com/nathanmcnulty/azd-advanced-auditing/issues/1) tracks the next authorized end-to-end retest.

A [PowerShell 7.6.6 operator read probe](operator-read-validation-20261018.md)
passed four Exchange reads for the lab operator, but Purview token authentication
returned `UnAuthorized`. Managed-identity remediation and the end-to-end retest
remain open.

References:

- [Exchange Online PowerShell module requirements](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2)
- [Azure Automation runbook runtimes](https://learn.microsoft.com/azure/automation/automation-runbook-types)
- [Mailbox auditing](https://learn.microsoft.com/purview/audit-mailboxes)
- [Audit log retention policies](https://learn.microsoft.com/purview/audit-log-retention-policies)
