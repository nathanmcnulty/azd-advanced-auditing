# Operations

## Verification

Review the managed-identity validation, remediation, and complete auditing-validation jobs after every deployment. Confirm ingestion, the retention policy, all expected mailbox action sets, `AuditEnabled`, audit age limits, and the absence of bypass associations.

The validation runbooks report aggregate failure counts and do not include mailbox SMTP addresses or bypass identities in their own success or validation-failure messages. Treat job output as sensitive because diagnostics returned by Exchange can still contain identifiers.

**Enable-AdvancedAuditing.ps1 -WhatIf** is a client-side inventory preview: it connects to Exchange, reads the matching mailbox list, and reports only its count. It skips **Set-Mailbox** entirely; it does not validate whether Exchange will accept the server-side updates or simulate those updates on the service.

If Security & Compliance authentication is unavailable, the hook completes with an explicit degraded warning. Configure and validate the identified retention policy manually; mailbox remediation and validation failures remain deployment failures.

Reruns reuse the prepared Automation account name and stable job-schedule identifier. Review current job output before repeating a failed tenant operation.

## Cleanup

`azd down --purge` removes the Azure resources after the pre-down hook removes the Automation account's template-owned delete lock. It does not restore tenant audit ingestion, retention policies, Exchange service-principal links, roles, role groups, or mailbox state. Inventory exact tenant objects and settings before separately reverting any of them.
