# Optional operational alerts

Alerts are disabled by literal `false` in `infra/main.parameters.json`. Enabling them is an owner decision: edit that parameter file to set `operationalAlertsEnabled` and exact existing `operationalWorkspaceResourceId`, its `operationalWorkspaceLocation`, and `operationalActionGroupResourceId`. Arbitrary azd environment flags are not wired to these deployment parameters. The actual deployed `OPERATIONAL_ALERTS_ENABLED` output controls postprovision state persistence with strict boolean parsing directly from deployed azd values. Process environment values cannot override this flag; disabled output bypasses all optional state-save calls.

Disabled mode adds no optional resource or permission requirement. Enabled mode creates one nonsecret Automation variable, one account diagnostic setting (JobLogs/JobStreams), and two scheduled query rules. It creates no action group, recipient, callback, role assignment, or managed identity. The existing LAW and action group must be deliberately selected and provisioned separately; their access and delivery remain operator acceptance gates. The immutable azure-monitor-scheduled-query-notifications 0.2.0 pilot rule module is vendored at reviewed immutable revision 2948cdbaf9497b69dd7b288b028b6b84dc2fb23b (reference draft PR #101; no release tag is claimed); its vendored Logic App/action-group module is deferred because this solution accepts an existing action group and does not invent receivers.

`infra/queries/failed-jobs.kql` scopes JobLogs by exact Automation resource ID and detects Failed, Stopped, or Suspended outcomes. Investigate the selected job in Automation; resolve its cause and run any remediation only with separate authority. Do not assume a notification means successful mailbox remediation.

Postprovision records only retention bootstrap `setupVerified`, `setupUnavailable`, or `setupFailed` with a timestamp and owned account ID. The unchanged daily remediation runbook reads that variable and emits bounded JSON Output metadata. `infra/queries/retention-setup.kql` parses `ResultDescription` and detects degraded, stale (older than seven days), or unknown observations. A fresh verified observation means bootstrap verified only. It does not assert current Purview policies, ingestion, mailbox settings, or retention effectiveness. Missing/invalid/future state is unknown. A stale observation requires a separately authorized audit-specific retest and bootstrap reconciliation, not automatic policy writes. The signal retains only its validated Automation account ID as resource provenance. KQL compares that ID case-insensitively to the trusted diagnostic `_ResourceId` before filtering statuses; missing or foreign IDs become unknown even if the variable claimed verified bootstrap. No raw state body or secrets enter the signal.

Both rules use a thirty-minute query window, five-minute evaluation, and unchanged `autoMitigate: false`. Microsoft's [Automation log field/ingestion contract](https://learn.microsoft.com/en-us/azure/automation/automation-manage-send-joblogs-log-analytics) documents that records can appear fifteen minutes after event emission. A ten-minute window can miss such records; thirty minutes leaves practical margin for ingestion and the next evaluation. Longer lookback also keeps matching records visible for longer, so recipient deduplication and delivery behavior require separate acceptance. Missing logs cannot prove health, and routing metadata alone cannot prove ingestion or action-group delivery. Offline tests compile the actual production template and verify embedded KQL/field binding, scalar signal behavior, immutable hashes, and both selected windows. See the native qualification evidence below for the scope of live proof.

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

## Account and synthetic runtime retry (2026-10-16 UTC)

A fresh, independently reviewed lab retry created one disposable Automation
account with the production account settings: Basic SKU, system-assigned identity,
local authentication disabled, and public network access enabled. Readback verified
those settings, no user-assigned identities, and account state `Ok`. This proves
present account creation; it does not explain the earlier setup failure.

One synthetic runbook then completed in an explicitly selected PowerShell `7.6`
runtime environment. Exact draft-content readback and a unique output marker bound
the job to the inert test script. Its reported version was **`7.6.0-preview.5`**.
This qualifies execution of the selected Azure 7.6 preview runtime, not stable/GA
PowerShell 7.6 availability or production runbook/module compatibility. The synthetic
runbook performed no downstream service authentication or Exchange/Purview
operations. The retry added no packages, schedules, diagnostics, alerts, roles,
or grants. The harness reused cached Azure CLI authentication for ARM and Graph.

Two private-harness readback/parsing failures were preserved: binary draft-content
readback and semantic prerelease-version parsing. Reviewed repairs resumed the
existing draft and polled the same job; no setup or job was resubmitted.

Cleanup verified the exact disposable group and account absent through ARM 404
readbacks, and its captured managed-identity service principal absent through a
Graph 404 readback. The default subscription was unchanged. No workspace or other
top-level resource was created. The canonical backlog records the receipt hashes.

That account/runtime checkpoint did not qualify diagnostic ingestion or alerts.
The subsequent test below addresses those gates. AUD-002 and issue #1 are unchanged.

## Native diagnostics and scheduled evaluation (2026-10-16 UTC)

A fresh disposable account and workspace exported JobLogs and JobStreams. One
synthetic runbook contained the exact production retention-signal converter,
with no Exchange code or downstream service authentication. Five jobs completed
and one intentionally failed, all on Azure's `7.6.0-preview.5` runtime.

Native ARM job metadata binds each resource name to its separate execution GUID;
diagnostic `JobId_g` uses the execution GUID. Exact account, execution-ID, time,
and output-marker checks qualified all six ingested outputs. The unchanged
production failed-job pipeline matched only the intentional failure. The retention
pipeline matched degraded, stale, unknown, and foreign-account signals; the healthy
signal was excluded, and the foreign-account signal became unknown. This proves
the native converter/diagnostic/query path for synthetic inputs, not actual mailbox
or Purview state, production module compatibility, or stable PowerShell 7.6.

The actual canonical Automation fixture then deployed one enabled failed-job rule
with the production query, `PT30M` window, `PT5M` evaluation, unchanged
`autoMitigate: false`, and the selected disposable workspace. ARM readback verified
the full rule policy and its exact action group. Azure Monitor reported **Fired**
for that rule and workspace. The action group had zero receivers throughout; no
notification was sent. This qualifies one failed-job scheduled evaluation, not the
retention rule's scheduled evaluation, routing delivery, recipient acceptance, or
deduplication behavior. Both production rules select the reviewed thirty-minute
window, and alerts still default off.

Cleanup verified the rule, zero-receiver action group, workspace, Automation
account, resource group, and captured managed-identity service principal absent.
The forced workspace deletion left no recoverable workspace tombstone, and the
default subscription remained unchanged. Private receipts preserve the native
job bindings, query results, fired-rule observation, failed harness attempts, and
cleanup evidence; their hashes are recorded in the canonical backlog.

AUD-003 remains proposed pending the remaining alert/delivery and effective
permission acceptance. Exchange/Purview acceptance stays in AUD-002 and issue #1.
