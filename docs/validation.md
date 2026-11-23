# Deployment validation

Use PowerShell 7.6 or later. `scripts/Test-Deployment.ps1` adopts the hash-locked deployment-validation 1.1.1 report/plan engine. It preserves the existing audit-specific runbooks as separate acceptance gates rather than running them automatically.

On 2026-10-11, an independently reviewed private harness qualified the production failed-job and retention KQL pipelines against the selected lab's existing Log Analytics query engine. Synthetic `datatable` input replaced the diagnostic table; the remaining production pipelines were unchanged and bound to source `371af1841167f952118c337f56688c80f2df453b`, with identical query bytes at reviewed revision `76d126691c7558924a5a09e54cff808c17602b4d`. Failed-job fixtures matched the expected 3 of 7 cases, and retention fixtures matched the expected 8 of 14. The sanitized native receipt SHA-256 is `F1DD7E15A1EF3758A5E96C057D5E286785993C5EB69BFD3CD30114B3521C6DAD`.

This proves synthetic query semantics in the native engine. It does not prove diagnostic ingestion, real runbook logs, deployment report readiness, scheduled alert execution, action-group routing, delivery, or Exchange/Purview behavior. The harness queried no actual workspace log data, created no resources or grants, initiated no authentication, and verified the default subscription remained unchanged. AUD-003 remains proposed pending the remaining native acceptance gates; the separate supported-platform Exchange retest remains open.

A later disposable synthetic test qualified native job/stream ingestion, exact production-query results, and one zero-receiver failed-job scheduled alert reaching Fired. It used the Azure 7.6 preview runtime and did not run Exchange/Purview operations or send notifications. See [operational qualification](operational-alerts.md#native-diagnostics-and-scheduled-evaluation-2026-10-16-utc) for its precise scope and remaining gates.

Create a private target JSON file with `subscriptionId`, `tenantId`, `account` (cached user's UPN), `principalId` (Automation managed identity), `resourceGroup`, `automationAccount`, and boolean `alertsEnabled`. When enabled, add exact same-subscription `workspaceId` and `actionGroupId` resource IDs. No tokens belong in this file. Unknown fields and invalid identifiers are refused.

```powershell
./scripts/Test-Deployment.ps1 -TargetPath <private-target.json> -Plan
./scripts/Test-Deployment.ps1 -TargetPath <private-target.json>
```

Plan performs no CLI dispatch. The default command reads the explicitly selected subscription using the existing cached Azure CLI user, refuses a different returned subscription, tenant, account or account type, and reads explicitly subscription-bound ARM metadata. It does not switch the CLI default subscription. It checks the account's exact returned resource ID and managed identity, all three published PowerShell 7.6 runbooks, daily schedule metadata, and selected optional diagnostic destinations. Provider exceptions/bodies are excluded from reports. A failed foundation blocks dependent reads; unavailable later metadata is a warning, never invented readiness. Independent definition sets retain independent target snapshots.

Metadata proves neither scheduled-job linkage/execution nor ingestion, notification delivery, effective Exchange authority, mailbox auditing, bypass state, or actual Purview retention. The retention observation is explicitly bootstrap-only. Keep `Validate-ExchangeManagedIdentity.ps1`, `Validate-AdvancedAuditingConfiguration.ps1`, and the [supported-platform retest](technical-reference.md#supported-platform-retest) as separate authorized gates. AUD-002 and [issue #1](https://github.com/nathanmcnulty/azd-advanced-auditing/issues/1) remain open.

Offline checks are registered in `.github/workflows/validate.yml`: PowerShell parsing, Error-severity ScriptAnalyzer, all Pester tests, exact Bicep 0.46.1 compilation and checked-in ARM parity. Tests use wire JSON and fail-closed CLI/HTTP/auth/Exchange guards. They do not execute native deployment or Exchange acceptance.
