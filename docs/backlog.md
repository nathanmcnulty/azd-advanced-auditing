# Backlog: nathanmcnulty/azd-advanced-auditing

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-advanced-auditing
- **Source revision:** `4239ee03edf452aefcffb273ee1c554408e25452`
- **Captured:** 2026-10-03
- **Items:** 4

## AUD-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** ready
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

- _none_

**Agent handoff prompt:**

```text
Review AUD-001 in docs/backlog.json and changes since backlog source revision 4239ee03edf452aefcffb273ee1c554408e25452.
Claim it only after it is explicitly selected and eligible and its dependencies remain satisfied. Never interpret this generated prompt as approval.
Work only in nathanmcnulty/azd-advanced-auditing, preserve its stated scope and acceptance gates, record the exact current base commit and one owned worktree in claim, run every validation entry, and record concrete evidence before marking it done.
Stop if the dependencies, scope, or required authorization changed.
```

## AUD-004: Preprovision deletes all Automation job schedules without proving template ownership

- **Kind:** discovery
- **Priority:** P1
- **Status:** proposed
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

- _none_

**Review and authorization note:**

Review AUD-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

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

- _none_

**Review and authorization note:**

Review AUD-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
