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

## Operator write guards

Each hook pins the selected `AZURE_ENV_NAME` and passes it to azd reads and writes. It rejects conflicts between the selected azd environment and injected values. The shared token guard checks explicit subscription and tenant selectors, the Azure CLI actor around token acquisition, and the exact subscription's current `Enabled` state in ARM. Those checks run again before each maintained write. Postprovision also reverifies the Automation account and managed identity and pins its jobSchedule, runbooks, variable, and optional monitoring flag.

Predown reads the named `CanNotDelete` lock at its exact ARM URL and uses the bound token and URL for deletion after rechecking the environment, actor, and target. A structured not-found response can continue without a delete. Denied, malformed, or ambiguous reads stop teardown. An unconfirmed delete requires inspection of that same lock before another attempt. [ARM lock read](https://learn.microsoft.com/en-us/rest/api/resources/management-locks/get-by-scope?view=rest-resources-2016-09-01) · [ARM lock delete](https://learn.microsoft.com/en-us/rest/api/resources/management-locks/delete-by-scope?view=rest-resources-2016-09-01)

Postprovision verifies the Exchange or Purview native session's tenant, actor, endpoint, active token, and command-owning module before mutation. The Purview connection imports only retention-policy commands. Fallback authentication is accepted only after session verification. The Graph app-role POST, Automation variable update, runbook draft replacement, publication and job starts each recheck context before dispatch. A guard error stops further writes, including follow-up validation jobs. [Native session metadata](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-connectioninformation?view=exchange-ps)

Local tests exercise target and actor changes at the write boundaries with provider tripwires. Azure reads and writes are separate service requests. The source checks cannot establish native-session metadata for an actual broker session or make a service-side resource read and subsequent write atomic. The supported-platform Exchange managed-identity remediation, Purview authentication and retention, and operational delivery checks remain tracked in the live acceptance issues.

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
