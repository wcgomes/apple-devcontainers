# Proposal: Automatic SSH forwarding for local workspaces

## Intent
Local SSH Git remotes should work in a newly created bind-mode dev container without requiring users to add `runArgs: ["--ssh"]`. Forward the existing host agent through Apple's create flag, not keys or a new credential service.

## Scope
Add a core-domain requirement for automatic SSH forwarding on fresh bind `up` and explicit bind `rebuild`, with safe discovery, explicit-runArgs compatibility, and honest reuse/start guidance. The existing [core lifecycle](../../../core.md), [runArgs allowlist](../../../runargs-host.md), and [clone contracts](../../../clone.md) remain in force.

## Non-goals
No public flags, guest SSH-agent emulation, key copying, authentication/keychain/key queries, broker/service or Homebrew changes. No changes to clone/volume forwarding policy (including its current HTTPS behavior), HTTP(S) credential connections, workspace identity, config drift rules, or wiki. Preserve pending documentation edits; only a concise user-facing README note is in scope. No automatic recreation or reconfiguration of existing containers.

## Approach
Read local Git fetch and push remote URLs before bind creation, classify SSH without network access, and add the typed SSH runArg once when a host socket is present. Share that decision between bind `up` and bind `rebuild`; keep automatic forwarding separate from resolved config/hash material. Existing containers retain their create-time settings.

## Decision index
- **Eligibility:** Any SSH fetch or push remote enables consideration, including mixed HTTPS/SSH repositories, `user@host:path`, `host:path`, and `ssh://` forms. HTTPS-only, local-path, missing-remotes and failed discovery do not enable automatic forwarding. Extend classification only in the bind policy if necessary; do not broaden clone behavior.
- **Availability:** For this bounded change, an available endpoint means a nonblank `SSH_AUTH_SOCK` in the invocation's `localEnv` resolving to a Unix-domain socket on the host. Follow socket symlinks. This metadata check does not establish liveness, loaded keys, authorization, or successful authentication; do not connect to/query the agent. Missing/stale/non-socket endpoints disable automatic forwarding with a nonfatal actionable warning when SSH is discovered.
- **Environment:** Use the injected invocation environment for both the decision and the host `container create` subprocess when forwarding automatically; never substitute the ambient process socket or inject the host socket path as guest `containerEnv`. Preserve the legacy runtime behavior of explicit-only `--ssh` even without an agent.
- **Explicit intent:** Preserve admitted `runArgs --ssh` regardless of remotes/socket availability and emit only one effective flag. Do not add a new automatic-missing-agent warning or reject an explicit-only request.
- **Existing containers:** A nonsecret internal create-time forwarding marker records the bind request's effective flag. For eligible existing bind containers whose marker is absent/false, emit conditional rebuild guidance rather than claiming inspection proves SSH is disabled. No flag repair on `up` reuse/start-stopped or bare `start`; already-marked forwarded containers need no rebuild hint. Agent/remote changes alone do not change the config hash.
- **Runtime limit:** Read-only installed CLI help confirms `container create --ssh` and no SSH option on `container start`; synthetic tests must lock down the no-create/no-mutation start/reuse behavior. This is not real SSH authentication validation.
- **Artifact size:** Proposal decisions and concrete tasks suffice; no design overflow document is needed.

## Clarifications
- **Q:** Which local workspaces automatically expose the agent?
  **A:** The accepted policy is SSH remotes plus an available host endpoint only; missing endpoint warns without copying keys, HTTPS-only does not automatically forward, and explicit `runArgs --ssh` remains respected.
