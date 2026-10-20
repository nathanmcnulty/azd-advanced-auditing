# Development

Key repository paths:

| Path | Purpose |
| --- | --- |
| `azure.yaml` | azd entry point and hook wiring |
| `infra/main.bicep` | Azure Automation infrastructure |
| `hooks/` | Naming, deployment, tenant bootstrap, validation, and cleanup hooks |
| `runbooks/` | Remediation and managed-identity validation runbooks |
| `tests/` | Pester contract and safety tests |

## Supported tooling

Maintained scripts, operator hooks, and runbooks require PowerShell 7.6 or later.
Pester's supported floor is 6.2; repository validation selects exactly 6.2.0 for
reproducible local and CI results. The test entrypoint logs both selected versions
and refuses a missing or different Pester version before running tests.

Install the validation dependencies in PowerShell 7.6+:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
az bicep install --version v0.46.1
./scripts/Test-Repository.ps1
```

The compiled-template tests require Bicep 0.46.1. They use the Azure CLI's installed
binary by default; set `AUD_BICEP_PATH` to the exact installed binary if it is in
another location. Missing tools are a blocked validation stage, not a passing test.
The full parse/analyzer/build/parity commands remain in
[the validation workflow](../.github/workflows/validate.yml).

Historical receipts, including the former PowerShell 7.4 native failure, retain
the versions actually tested. The immutable vendored deployment-validation
manifest retains its upstream PowerShell 7.2 declaration and hash; owned wrappers
require 7.6 and do not claim 7.2 support. Do not edit frozen evidence or vendor
files to restate the current supported baseline.

Repository validation parses every PowerShell file, runs PSScriptAnalyzer errors, verifies runtime and parameter wiring, checks remediation and validation action lists remain aligned, runs Pester, and builds Bicep. Keep generated `infra/main.json` synchronized when required by the repository workflow.

Catalog metadata is stored in `.azd/catalog.json`. Changes to metadata, `azure.yaml`, or the root README can notify `nathanmcnulty/azd-website` when the repository's `AZD_CATALOG_TOKEN` secret is configured.
