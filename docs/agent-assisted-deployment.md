# Agent-assisted deployment

An agent may inspect prerequisites, initialize the template, explain the plan, run local validation, and summarize read-only evidence within the administrator's request.

Azure provisioning, Graph consent, Exchange or Purview changes, managed-identity grants, remediation, and cleanup require explicit administrator authority. Treat Graph consent as a separate handoff: a **Global Administrator or Privileged Role Administrator** must approve the Microsoft Graph API permissions used by the deployment client, while the feature operator supplies the Azure, Exchange, and Purview authority. Verify account, tenant, subscription, scopes, Exchange organization, exact target objects, and the supported-platform caveat before a write.

Use normal cached operating-system broker or browser authentication. Never use device-code authentication or expose tokens and credentials. Stop at authentication, consent, tenant, role, Security & Compliance, or live-validation blockers rather than bypassing them.
