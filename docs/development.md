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
