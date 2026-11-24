# Development

## Supported validation toolchain

Maintained PowerShell entry points and runbooks target PowerShell 7.6 or later. Use Pester 6.2.0 or later for the offline test suite; CI installs Pester 6.2.0. The validation workflow also runs PowerShell parsing and PSScriptAnalyzer at Error severity, builds Bicep with CLI 0.46.1, and compares the generated ARM template with `infra/main.json`.

For a local Pester run, use PowerShell 7.6 or later and import a supported Pester version before running the suite:

Before the full suite, make Bicep CLI 0.46.1 available through `$env:AUD_BICEP_PATH` or `$HOME/.azure/bin/bicep.exe` (Windows) / `$HOME/.azure/bin/bicep` (Linux/macOS); the template tests compile `infra/main.bicep`.

```powershell
$PSVersionTable.PSVersion
Import-Module Pester -MinimumVersion 6.2.0 -Force
(Get-Module Pester).Version
Invoke-Pester -Path .\tests -CI
```

## Operator token context

Postprovision reads the expected `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` from the selected azd environment or process environment and rejects conflicting values. Before persisting ownership receipts, it verifies the selected account's subscription-to-tenant mapping. Each supported Azure CLI `account get-access-token` request uses only `--subscription`, which binds token acquisition to that selected account without changing the global Azure CLI default. The hook validates both returned token metadata fields and suppresses raw CLI stderr in favor of fixed diagnostics.

Preprovision and predown bind azd reads to the `AZURE_ENV_NAME` supplied to the hook by passing `--environment`; preprovision writes use the same explicit environment, so a changed azd default cannot redirect them. The hooks reject process/store target drift. They use the shared token guard to read the exact subscription resource from ARM and require its subscription ID, tenant ID, and `Enabled` state to match. Preprovision repeats the check immediately before persisting the final schedule ID. Predown verifies the lock response's exact ID, then rechecks the same azd environment, resource names, subscription state, and CLI operator identity immediately before deletion. These are live service-side checks, not cached CLI state; no global CLI or azd environment default is changed.

This token-context check does not validate native Exchange or Purview session tenant, actor, state, or endpoint. It does not qualify the existing cached/browser fallback or the outstanding live acceptance gates.

Key repository paths:

| Path | Purpose |
| --- | --- |
| `azure.yaml` | azd entry point and hook wiring |
| `infra/main.bicep` | Azure Automation infrastructure |
| `hooks/` | Naming, deployment, tenant bootstrap, validation, and cleanup hooks |
| `runbooks/` | Remediation and managed-identity validation runbooks |
| `tests/` | Pester contract and safety tests |

Repository validation parses every PowerShell file, runs PSScriptAnalyzer errors, verifies runtime and parameter wiring, checks remediation and validation action lists remain aligned, runs Pester, and builds Bicep. Keep generated `infra/main.json` synchronized when required by the repository workflow.

Catalog metadata is stored in `.azd/catalog.json`. Changes to metadata, `azure.yaml`, or the root README can notify `nathanmcnulty/azd-website` when the repository's `AZD_CATALOG_TOKEN` secret is configured.
