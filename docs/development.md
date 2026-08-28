# Development

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
