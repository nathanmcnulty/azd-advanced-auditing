# Optional operational alerts

Alerts are disabled by literal `false` in `infra/main.parameters.json`. Enabling them is an owner decision: edit that parameter file to set `operationalAlertsEnabled` and exact existing `operationalWorkspaceResourceId`, its `operationalWorkspaceLocation`, and `operationalActionGroupResourceId`. Arbitrary azd environment flags are not wired to these deployment parameters. The actual deployed `OPERATIONAL_ALERTS_ENABLED` output controls postprovision state persistence with strict boolean parsing directly from deployed azd values. Process environment values cannot override this flag; disabled output bypasses all optional state-save calls.

Disabled mode adds no optional resource or permission requirement. Enabled mode creates one nonsecret Automation variable, one account diagnostic setting (JobLogs/JobStreams), and two scheduled query rules. It creates no action group, recipient, callback, role assignment, or managed identity. The existing LAW and action group must be deliberately selected and provisioned separately; their access and delivery remain operator acceptance gates. The immutable azure-monitor-scheduled-query-notifications 0.1.0 rule module is adopted; its vendored Logic App/action-group module is deferred because this solution accepts an existing action group and does not invent receivers.

`infra/queries/failed-jobs.kql` scopes JobLogs by exact Automation resource ID and detects Failed, Stopped, or Suspended outcomes. Investigate the selected job in Automation; resolve its cause and run any remediation only with separate authority. Do not assume a notification means successful mailbox remediation.

Postprovision records only retention bootstrap `setupVerified`, `setupUnavailable`, or `setupFailed` with a timestamp and owned account ID. The unchanged daily remediation runbook reads that variable and emits bounded JSON Output metadata. `infra/queries/retention-setup.kql` parses `ResultDescription` and detects degraded, stale (older than seven days), or unknown observations. A fresh verified observation means bootstrap verified only. It does not assert current Purview policies, ingestion, mailbox settings, or retention effectiveness. Missing/invalid/future state is unknown. A stale observation requires a separately authorized audit-specific retest and bootstrap reconciliation, not automatic policy writes. The signal retains only its validated Automation account ID as resource provenance. KQL compares that ID case-insensitively to the trusted diagnostic `_ResourceId` before filtering statuses; missing or foreign IDs become unknown even if the variable claimed verified bootstrap. No raw state body or secrets enter the signal.

Both rules use a ten-minute evaluation window and manual resolution (`autoMitigate: false`). Automation diagnostic ingestion can lag, and missing logs cannot prove health. Routing metadata alone cannot prove ingestion or action-group delivery. See the [official Automation log field/ingestion contract](https://learn.microsoft.com/en-us/azure/automation/automation-manage-send-joblogs-log-analytics). Offline tests compile the actual production template, verify embedded KQL/field binding, scalar signal behavior and immutable hashes; no live Kusto execution, alerts or recipient delivery are claimed.

Existing bootstrap handlers still include historical raw exception warnings. This bounded signal/report change does not certify general bootstrap log sanitization. Permission provenance is partial in `azd-permissions.json`; unresolved effective roles, operator consent and live acceptance are explicit gaps. See [deployment validation](validation.md).

## Native qualification progress (2026-10-11)

The independently reviewed PowerShell 7.6.6 synthetic KQL qualification passed
against the unchanged production pipelines: seven failed-job fixtures produced
three expected matches and fourteen retention fixtures produced eight. This
qualifies native query semantics using synthetic rows. It does not qualify
Automation log ingestion, actual job execution or alert/action-group delivery.

A separate phase-two synthetic Automation/diagnostic-ingestion attempt failed
in resource setup after two resource write intents and zero job intents. Its
generic failure receipt does not establish the cause. The original cleanup was
incomplete, and the failed attempt and diagnostic artifacts remain preserved.
Fresh read-only diagnosis found the exact owned group empty and the target
account absent; unavailable account-dependent reads were not treated as empty.

A separately reviewed cleanup freshly verified group ownership, complete empty
resource and lock inventories, classified all returned role scopes without
changing roles, and required fourteen exact child/job IDs absent before one
intent-recorded DELETE of that empty group. Independent terminal review verified
all fifteen exact resource/job IDs returned 404, no owned workspace tombstone
remained, and the default subscription was unchanged. No jobs, grants or new
authentication were initiated. This establishes cleanup only.

AUD-003 remains proposed. Runtime/job/stream ingestion, production KQL over
actually ingested diagnostic records, scheduled alert/routing/recipient delivery,
effective permission and Exchange/Purview acceptance remain separate open gates.
The supported-platform retest in AUD-002 and issue #1 is unaffected. The canonical
[backlog evidence](backlog.md) records receipt and independent-review hashes.
A later zero-resource ARM request with `validationLevel: Provider` returned HTTP
200 for a literal template containing the original Automation account settings.
The virtual account and deployment were absent before and after; the existing
resource-group fingerprint, Registered provider state and default subscription
were unchanged. No provisioning, registration, grants or new authentication were
requested. Provider preflight is best effort and can leave Activity Log telemetry.
This qualifies present template validation only. It does not prove actual account
creation, automatic-child ownership, effective permissions, runtime or ingestion,
or explain the earlier failed setup. AUD-003 remains proposed; the canonical
backlog retains the source/request/receipt hashes and the failed attempt.