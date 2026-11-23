# Release attestation boundary

## What the push event binds

For a GitHub Actions push event, GITHUB_SHA is the tip commit pushed to the ref. The webhook push payload's after value is also the most recent commit on the ref after the push. Neither value identifies the annotated-tag object SHA.

This workflow verifies the currently observed remote annotated tag, GitHub's signature-verification result, the local tag object and peeled commit, the event commit, checkout HEAD, and default-branch ancestry. It then archives the verified commit SHA directly. Its claim is that the source bundle is for the commit identified by the push event and the currently observed GitHub-verified tag. It does not bind the annotated-tag object SHA to the original event.

If someone replaces the annotated tag with a different signed annotation pointing to the same commit before the workflow reads the remote and local refs, the commit-only event values cannot distinguish that replacement from the object that caused the event. The bundle remains bound to the same source commit; the workflow cannot claim to attest the exact tag-object identity from the event.

## Required v* tag protection

Before relying on this workflow for a v* release tag, an active tag ruleset must target refs/tags/v* and enable Restrict updates and Restrict deletions. Tag creation must remain allowed. Configured bypass actors are part of the trust boundary: a bypass can mutate or delete a protected tag, so any such use is an explicit trusted override and does not preserve an immutable event-tag-object claim.

The workflow fails closed unless GITHUB_REF_PROTECTED is true. That is only a coarse signal that some protection or ruleset applies; it does not prove the exact update/deletion rules or bypass list. Before the first release, verify the effective tag ruleset and its bypass actors. Recheck it before relying on each release. Do not describe this workflow as proving the original tag-object SHA.

GitHub documents push-event commit semantics in [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#push) and [Webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads#push). Ruleset update and deletion protections are documented under [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
