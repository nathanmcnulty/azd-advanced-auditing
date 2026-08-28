# Agent guidance

Read [docs/agent-assisted-deployment.md](docs/agent-assisted-deployment.md) and the [supported-platform retest status](docs/technical-reference.md#supported-platform-retest) before assisting.

- Never use or recommend device-code authentication.
- Separate read-only validation from Azure, Graph, Exchange, Purview, remediation, and cleanup writes.
- Verify account, tenant, subscription, scopes, organization, exact targets, and live-validation status before an authorized write.
- Do not expose tokens or credentials, and do not present local tests as proof of the outstanding live Exchange retest.
