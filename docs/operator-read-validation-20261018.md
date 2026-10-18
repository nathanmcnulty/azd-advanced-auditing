# Supported-platform operator read validation

On 2026-10-18, a bounded read-only probe tested ExchangeOnlineManagement 3.10.1
on PowerShell 7.6.6 against the commercial lab. Source was fixed at commit
`861780938a14be831a955c1657714d4909aba78e`.

The approved target was subscription `a80941e8-c2b9-4bc9-83ad-117cc40d0bea`
(`sub-mvp`), tenant `847b5907-ca15-40f4-b171-eb18619dbfab`, and operator
`nathan@sharemylabs.com`. Fresh scoped subscription identity, tenant and Enabled
checks passed before and after both probes. The global CLI default was preserved.

## Observed Exchange results

The native Exchange connection reported the expected tenant and operator, an
active token and Connected state before these reads:

| Read | Observed result |
| --- | --- |
| `Get-AdminAuditLogConfig` | Unified audit ingestion enabled |
| `Get-OrganizationConfig` | `AuditDisabled` false |
| `Get-Mailbox` for the operator | Audit enabled; age limit 365 days |
| `Get-MailboxAuditBypassAssociation` for the operator | Bypass disabled |

The captured mailbox action lists contain all entries required by the maintained
validation runbook: 26 admin, 22 delegate and 23 owner actions, with no missing
entries. This is evidence for one mailbox, not a tenant-wide mailbox or bypass
enumeration.

## Purview blocker and evidence limits

The actual `Connect-ComplianceForBootstrap` function was extracted from the fixed
source without running the full postprovision hook. Its ambient-context token
helpers were replaced by explicitly subscription-bound cached CLI token reads;
returned token metadata had to match the approved subscription and tenant.
Consequently, this does not qualify the full hook's context-selection behavior.

The helper returned Boolean false. A separate diagnostic repeated only the
Purview connection path and captured sanitized provider errors: both
`AccessToken` plus `UserPrincipalName` and the `Organization` fallback returned
`UnAuthorized`. No retention-policy query ran. The error alone does not identify
a consent, role, license, token-client or service cause. No roles or consent were
changed to work around it.

Both probes confirmed disconnection and final approved context. They made no
tenant configuration changes and created no Azure resources. Managed-identity
execution, `Set-Mailbox`, remediation, retention-policy mutation, rollback and
operational alert delivery remain unproved; AUD-002, AUD-003 and issue #1 remain
open.

## Private evidence receipts

The original probe ran from 11:49:15 to 11:49:50 UTC; its JSON receipt SHA-256 is
`C6D4417345C92553B750410930FBDABEA2748CD72E90B392E3F9593548A2057C`.
The diagnostic ran from 11:55:22 to 11:55:40 UTC; its receipt SHA-256 is
`A2418B829A26E1AC00F9211E6B453655E0E93309B4873D6DFAD946BD3EFEBB6D`.
The mailbox action comparison SHA-256 is
`19A6CD5AD76D778DF6CCD9FE0C210249EBA4AC80A56E2117CC31C3E5BD8F9B38`.
Private probes use local validation infrastructure and are not deployment inputs.
