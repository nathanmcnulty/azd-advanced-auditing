# Deployment validation

Use PowerShell 7.6 or later. `scripts/Test-Deployment.ps1` adopts the hash-locked deployment-validation 1.1.1 report/plan engine. It preserves the existing audit-specific runbooks as separate acceptance gates rather than running them automatically.

Create a private target JSON file with `subscriptionId`, `tenantId`, `account` (cached user's UPN), `principalId` (Automation managed identity), `resourceGroup`, `automationAccount`, and boolean `alertsEnabled`. When enabled, add exact same-subscription `workspaceId` and `actionGroupId` resource IDs. No tokens belong in this file. Unknown fields and invalid identifiers are refused.

```powershell
./scripts/Test-Deployment.ps1 -TargetPath <private-target.json> -Plan
./scripts/Test-Deployment.ps1 -TargetPath <private-target.json>
```

Plan performs no CLI dispatch. The default command uses the existing cached Azure CLI user, refuses a different account/tenant/default subscription, and reads explicitly subscription-bound ARM metadata. It checks the account's exact returned resource ID and managed identity, all three published PowerShell 7.6 runbooks, daily schedule metadata, and selected optional diagnostic destinations. Provider exceptions/bodies are excluded from reports. A failed foundation blocks dependent reads; unavailable later metadata is a warning, never invented readiness. Independent definition sets retain independent target snapshots.

Metadata proves neither scheduled-job linkage/execution nor ingestion, notification delivery, effective Exchange authority, mailbox auditing, bypass state, or actual Purview retention. The retention observation is explicitly bootstrap-only. Keep `Validate-ExchangeManagedIdentity.ps1`, `Validate-AdvancedAuditingConfiguration.ps1`, and the [supported-platform retest](technical-reference.md#supported-platform-retest) as separate authorized gates. AUD-002 and [issue #1](https://github.com/nathanmcnulty/azd-advanced-auditing/issues/1) remain open.

Offline checks are registered in `.github/workflows/validate.yml`: PowerShell parsing, Error-severity ScriptAnalyzer, all Pester tests, exact Bicep 0.46.1 compilation and checked-in ARM parity. Tests use wire JSON and fail-closed CLI/HTTP/auth/Exchange guards. They do not execute native deployment or Exchange acceptance.
