# Backlog: nathanmcnulty/azd-advanced-auditing

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-advanced-auditing
- **Source revision:** `8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc`
- **Captured:** 2026-10-04
- **Items:** 6

## AUD-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- 2026-10-04 read-only reconciliation against current main 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc&colon; inspected canonical dirty state, remotes, worktrees and environment-path presence without reading values; active/unowned branches remain untouched. Reviewed current issue/PR inventory, roadmap/TODO task sources and .github/workflows/validate.yml; kept live and optional-feature gates proposed.
- Invoke-Pester ./tests -CI&colon; 21/21 passed; jobSchedule ownership fixtures exercise preservation and fail-closed behavior. Validation used offline fixtures only; no cloud, tenant, recipient or endpoint action was performed.

**Review and authorization note:**

Review AUD-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## AUD-004: Preprovision deletes all Automation job schedules without proving template ownership

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open report captured 2026-10-03 during execution reconciliation. Another code-quality task may own an active fix; inspect its PR and current source before dispatch.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/issues/13

**Evidence:**

- Source implementation is present in current main 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc; resolved revision 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc via merged https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/pull/17.
- Invoke-Pester ./tests -CI&colon; 21/21 passed; jobSchedule ownership fixtures exercise preservation and fail-closed behavior. This completes only the bounded source/fixture acceptance; live-service, recovery, release and endpoint gates remain separate.

**Review and authorization note:**

Review AUD-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## AUD-005: Stop runbook publication after Azure CLI failures

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Read-only reconciliation identified a resolved current-main defect missing from the captured task inventory.

**Scope:**

- hooks/Common.ps1
- tests/Template.Tests.ps1

**Acceptance:**

- Record exact merged source and regression coverage for the linked issue.
- Preserve live-service and deployment acceptance as separate gates.

**Validation:**

- Invoke-Pester ./tests -CI

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/issues/14
- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/pull/15

**Evidence:**

- Merged PR &num;15 resolves issue &num;14 at be62ab0de41358d9f682d4e6930404071ece1fd1; implementation is present in current main 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc.
- Invoke-Pester ./tests -CI&colon; 21/21 passed; jobSchedule ownership fixtures exercise preservation and fail-closed behavior. This is source/fixture evidence only; no live authentication, deployment, tenant mutation, device action or delivery is claimed.

**Review and authorization note:**

Review AUD-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## AUD-006: Use normal cached or browser authentication without device-code fallback

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Read-only reconciliation identified a resolved current-main defect missing from the captured task inventory.

**Scope:**

- hooks/Common.ps1
- tests/JobScheduleOwnership.Tests.ps1

**Acceptance:**

- Record exact merged source and regression coverage for the linked issue.
- Preserve live-service and deployment acceptance as separate gates.

**Validation:**

- Invoke-Pester ./tests -CI

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/issues/16
- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/pull/17

**Evidence:**

- Merged PR &num;17 resolves issue &num;16 at 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc; implementation is present in current main 8957d5b89ee52c043ccc2a4215b7f5ec52fad2fc.
- Invoke-Pester ./tests -CI&colon; 21/21 passed; jobSchedule ownership fixtures exercise preservation and fail-closed behavior. This is source/fixture evidence only; no live authentication, deployment, tenant mutation, device action or delivery is claimed.

**Review and authorization note:**

Review AUD-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## AUD-002: Prepare and execute the supported Exchange/Purview compatibility retest

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** tenant-write
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The documented PowerShell 7.6 / ExchangeOnlineManagement 3.10.1 retest remains a production-readiness gap.

**Scope:**

- docs/technical-reference.md
- docs/validation.md
- scripts/
- runbooks/

**Acceptance:**

- Record operator and managed-identity outcomes for audit ingestion, retention, mailbox audit actions and bypass checks.
- Distinguish unavailable Purview retention setup from fatal mailbox remediation failure.
- Preserve previous settings and prove rollback; never mark local syntax checks as live Exchange success.

**Validation:**

- Use the offline commands in the registered validation workflow; record the exact commands, revision and results before implementation is complete.
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md
- docs/technical-reference.md
- https&colon;//github.com/nathanmcnulty/azd-advanced-auditing/issues/1

**Evidence:**

- _none_

**Review and authorization note:**

Review AUD-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## AUD-003: Add bounded deployment-validation and optional operational alerting

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 2
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Automation output should separate configured resources, job failures, degraded retention and actual audit state.

**Scope:**

- scripts/
- infra/
- docs/
- azd-components.lock.json
- azd-permissions.json

**Acceptance:**

- Compare existing validation with deployment-validation and adopt only where it preserves the audit-specific checks.
- Optional Azure Monitor alerts expose job failures and degraded state while KQL and remediation remain solution-owned.
- Disabled alerts add no resource or permission delta; new component copies are immutable and hash-locked.

**Validation:**

- Use the offline commands in the registered validation workflow; record the exact commands, revision and results before implementation is complete.
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.

**Dependencies:**

- _none_

**Components:**

- deployment-validation
- azure-monitor-scheduled-query-notifications

**Sources:**

- README.md

**Evidence:**

- 2026-10-10 bounded source implementation based on edd48cd5ac3866b13ddbe3640ae6181b7871975c&colon; adopted hash-locked deployment-validation 1.1.1 and scheduled-query-notifications 0.1.0 at reference 6dc5841a3156b904b89f0f4ff8d97207a26ec15a. Read-only target-bound plan/report retains audit-specific Exchange gates; optional existing LAW/action-group routing adds job failures and qualified bootstrap-only degraded/stale/unknown retention signals. Literal disabled mode adds zero optional resources/permission delta.
- PowerShell 7.6.6 offline validation&colon; 46/46 registered Pester tests passed, including guarded actual adapter wire JSON, target snapshots, actual postprovision retention dispatch, scalar signal negatives and actual compiled production template/embedded KQL/hash locks. PowerShell parsing, Error-severity analyzer, permission/backlog schema and Bicep 0.46.1 checked-in ARM parity passed. No native deployment, live Kusto/ingestion, alert/recipient delivery, grants, jobs or Exchange/Purview outcome is claimed. Independent review and publication reconciliation remain pending; AUD-003 stays proposed and AUD-002/issue &num;1 remains separate.
- Independent review identified cross-account bootstrap-state provenance loss. R2 retains the validated accountId in the bounded signal and compiled solution KQL converts missing/mismatched signal account IDs to unknown against trusted diagnostic &lowbar;ResourceId before filtering. Actual decoder foreign-ID and compiled binding/order regression fixtures pass; no API/resource/permission/default delta was introduced.
- R3 independent-review repair&colon; optional retention persistence reads only the exact deployed azdValues output with strict boolean parsing, bypassing the common process-first environment helper. Actual postprovision branch fixtures prove conflicting process true/deployed false causes zero optional save calls and missing/malformed deployed output fails closed before persistence. Prior R1/R2 source/evidence snapshots remain preserved.
- R5 selected-subscription repair based on published 371af1841167f952118c337f56688c80f2df453b&colon; the cached context read explicitly passes --subscription and still refuses returned subscription/tenant/user/type mismatches before any ARM request. PowerShell 7.6.6 guarded offline validation passed 50/50 registered tests, including exact argv, all four zero-ARM refusals, two distinct selected-subscription snapshots, and Plan zero CLI. No native context/deployment/Exchange/alert delivery is claimed; AUD-003 remains proposed pending separate review/reconciliation.
- 2026-10-11 independently reviewed private native KQL harness on PowerShell7.6.6 qualified unchanged production pipelines from371af1841167f952118c337f56688c80f2df453b, identical at reviewed76d126691c7558924a5a09e54cff808c17602b4d&colon; synthetic FailedJobs7fixtures matched expected3; Retention14fixtures matched expected8. Receipt SHA256 F1DD7E15A1EF3758A5E96C057D5E286785993C5EB69BFD3CD30114B3521C6DAD. Existing selected-lab workspace authority and unchanged default subscription were verified. No actual workspace log data, resources, grants or authentication initiation. This proves synthetic native query semantics only; ingestion, real logs/report readiness, scheduled alerts/routing/delivery and Exchange/Purview acceptance remain open. Source R5 independent review and all five hosted checks passed; AUD-003 remains proposed.
- 2026-10-11 phase-two inert synthetic Automation/diagnostic-ingestion qualification failed during resource setup after two resource write intents and zero job intents. The original cleanup was incomplete; the preserved failed receipt SHA256 is 1A0AE68876F4F36FBA5115D0AC4A961213A2E8EDCF77FB999D3894127F1948D1. The generic failure receipt does not establish the setup cause. No runtime, job execution, stream ingestion, production-pipeline ingestion, scheduled alert, delivery, effective permissions or Exchange/Purview outcome is qualified.
- Separate independently reviewed read-only diagnosis verified an exact owned empty resource group, absent target account and five other target children, and complete empty group resource/lock inventories. Subsequently an independently reviewed narrow cleanup freshly classified every returned role scope without modifying roles, required fourteen exact child/job IDs absent, persisted deletion intent, and performed one exact empty-group DELETE. Final receipt SHA256 B01712CBB1F582A7DE03C3F0B3DB69835F6967F68E4CC59E1F15E999EB124EE5 and independent result review SHA256 507530184064B9FA5EBED548AC7FB630540549E2864096F66A8C2F7E6E72CC7C prove all fifteen exact resource/job IDs returned 404, no owned workspace tombstone remained, and default subscription was unchanged. No jobs, grants or new authentication were initiated. All failed attempts and diagnostic evidence are preserved; cleanup completion does not qualify ingestion or delivery. AUD-003 remains proposed and AUD-002/issue &num;1 stays separate.
- 2026-10-11 a separately frozen PowerShell 7.6.6 zero-resource ARM Provider validation request returned HTTP200/ProviderValidationSucceeded for the original Automation account settings in a literal single-resource template. Receipt SHA256 AD4BDA5177603FA584F8F7A7F9766AB67A63A1FC477A3C09D6A35CD0B2B890CC binds request SHA256 B81EBB58784A7A21494FE9B33DA1DBA80AB71E7B386D7DCABE6AD08E17611C64 and harness freeze0F293C0B00EDC5EE3EC13A15D911DB5CB670E465AB9BA1C4AB2029BD3CE5B7F7. One validation POST; zero provisioning requests, grants or new authentication. The virtual account and deployment were404 before/after, the existing group fingerprint and Registered provider state were unchanged, and the default subscription stayed unchanged. Provider preflight is best effort and may leave Activity Log telemetry; this proves present template validation only, not actual Account PUT, default-child ownership, effective permissions, runtime/ingestion/delivery, or the historical setup failure cause. AUD-003 remains proposed and the failed attempt is preserved. Independent terminal evidence review SHA256465A16F04A5956CAE8E2D3AD5ADDC6837DE36EF9F57782343719EA3F7A76C855 passed; these are reviewed harness observations, not additional reviewer API readbacks.
- 2026-10-16 UTC independently reviewed disposable lab retry at source 217135e00b0047381dcd661d1b9278a3203e5756 proved actual Automation account creation with production account settings &lpar;Basic, SystemAssigned only, disableLocalAuth=true, publicNetworkAccess=true, state Ok&rpar;. Account receipt SHA256 15E0B148F69EFC2A1C9F5A3C945F817C39F0CCAD44A2C84E948E93C746FC000A. One inert synthetic runbook completed with exact draft readback and nonce-bound output reporting 7.6.0-preview.5; runtime receipt SHA256 1B198E6C0234DFAA82FDD5C52C7BA90BE778BFD92AE8B27DB2BC6F39A8EE913C. This qualifies selected Azure 7.6 preview execution, not stable/GA availability or production modules/runbooks. Two private-harness readback/parsing failures were preserved and reviewed repairs continued the same draft/job with no resubmission. The synthetic runbook performed no downstream service authentication or Exchange/Purview operations. The retry added no packages, schedules, diagnostics, alerts, roles or grants; the harness reused cached Azure CLI authentication for ARM and Graph. Cleanup receipt SHA256 32F3555F7F9917AB8C1E49E3A45354C74D1A6FB9607990F7C20F13CD2A5910A1 verifies exact group/account ARM 404s, captured MSI Graph 404 and unchanged default subscription. The earlier setup failure remains unexplained. AUD-003 stays proposed; native diagnostic ingestion, production KQL over those records, scheduled alert/routing/recipient delivery, effective permissions and Exchange/Purview acceptance remain open; AUD-002/issue &num;1 unchanged.

**Review and authorization note:**

Review AUD-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
