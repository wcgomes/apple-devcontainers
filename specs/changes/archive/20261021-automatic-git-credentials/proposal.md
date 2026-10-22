# Proposal: Automatic Git credentials

## Intent
Keep managed containers connected to the host's current HTTPS Git credential provider after lifecycle commands exit, without persisting new copies of host tokens in the guest. Remove the need to restart a container or manually reseed it when the host provider changes its credential.

## Scope
Replace the credential-seeding requirement in `../../core.md` and the HTTPS authentication portions of the full-clone-populate requirement in `../../clone.md`. Integrate automatic setup/recovery with clone, up, start, reuse, rebuild, stop, delete, purge, and refresh-credentials; retain existing SSH and unrelated lifecycle behavior. The change includes supervision, private transport, guest helper provisioning, authorization, migration, concurrency, rejection handling, and tests.

## Non-goals
Implementing OAuth refresh, forcing GCM renewal, installing GCM or packages in the guest, changing remote URLs, adding providers or user-facing flags, exposing a TCP endpoint, changing user credential helpers, archiving the change, or implementing product code during this drafting phase.

## Approach
Use a per-user launchd-supervised mode of the existing adevcontainer executable. Establish a private non-TTY exec channel to a guest relay serving a user-private Unix socket. The Git helper requests credentials on demand through this channel; the host reuses the existing acquisition provider. Expanded flow, alternatives, migration risks, and the unresolved guest-delivery decision are in [design.md](design.md).

## Decision index
- **Host supervision:** one LaunchAgent per macOS user, registered automatically without sudo; no separate host executable. A detached child does not provide crash recovery. See [supervision](design.md#supervision-and-session-lifecycle).
- **Transport:** private per-container `container exec -i` streams and a guest Unix socket; no network listener or mounted host credential store. See [flow](design.md#flow).
- **Acquisition:** reuse the host provider noninteractively; no provider erase/approve, no new guest token store, and no claim that another lookup proves OAuth renewal.
- **Compatibility:** preserve host-based sibling coverage, queried-username behavior, existing helper ordering, Azure URL-scoped helper/path rules, and independent SSH forwarding. Existing earlier helpers remain outside the product's freshness guarantee.
- **Failure:** finite waits, generation fencing, bounded concurrency, and redacted failures; lifecycle setup remains best-effort except the explicit refresh command.
- **Guest relay delivery:** ship one small static C relay/client for each of linux/arm64 and linux/amd64, embedded in the existing CLI; build reproducibly with checksum-pinned Zig 0.15.2, not an assumed local cross-toolchain. See [delivery](design.md#guest-delivery-decision).
- **Legacy HTTP:** retain explicitly discovered HTTP destinations using their original scheme/host/port and existing provider policy; do not permit HTTPS-to-HTTP downgrade or introduce new HTTP destinations. Removing HTTP support is outside this change.

## Clarifications
- **Q:** Is a background host component acceptable after considering foreground-only operation?
  **A:** Yes. Use the existing executable supervised by a per-user LaunchAgent, with automatic activation and no sudo.
- **Q:** Does the previous runtime/GCM experiment prove real OAuth renewal?
  **A:** No. The supplied evidence demonstrates exec duplex/concurrency and successful Azure authentication through the channel, not changed tokens or refresh-token use. plantsuite was stopped before and after that experiment.
- **Q:** How is the dependency-free Linux socket relay delivered for release and source builds?
  **A:** The user approved shipping a small static Linux helper together with the CLI, including build/distribution changes, without installing guest runtime packages. Embed both architecture variants in generated Swift source to preserve a relocatable single host executable; source/CI builds explicitly prepare the checksum-pinned toolchain and assets first.
- **Q:** Does the new strict HTTPS boundary intentionally change existing plain-HTTP credential behavior?
  **A:** No. The user explicitly approved preserving legacy HTTP compatibility without expanding its reach. Only destinations discovered through the existing source rules are authorized, with scheme binding; provider refusal of unsafe HTTP is not overridden.

## Archive verification

Archived 2026-10-21 (`specs/changes/archive/20261021-automatic-git-credentials/`) by explicit user authorization. This record does not certify production readiness and does not claim that unchecked tasks were executed.

Inspected before archive, without re-running suites, containers, authentication, or services:

- `GitCredentialDiag.event` does not write `diag.log`. The optional `traceDirectory` argument exists only so a temporary test can target an existing broker directory; production calls and that test must not create `diag.log`, including `~/.adevcontainer/git-broker/diag.log`.
- Each broker get calls host acquisition again. `GitCredentialBrokerPolicy.deliver` returns the password just acquired and does not substitute a previous guest token. `credentials.broker.secondGetReturnsChangedProviderPassword` requires the second get to return `second-synthetic` after two provider queries. That matches C07 at the synthetic broker boundary.

User-reported evidence accepted for this archive and not re-executed here: 87 focused credential tests passed, and `swift build` debug passed. Earlier real evidence, also not re-run here: the helper returned a credential in plantsuite, and concurrency plus a partial restart were observed. OAuth refresh was not proven and is not required.

Not executed, and not claimed as executed. The user authorized archive with these limits as non-blocking:

- Isolated supervised smoke (task 6.11 / live V01), including a unique temporary LaunchAgent against an exclusively created guest.
- Linux target execution of the shipped relay, including linux/amd64 CI execution.
- The complete restart matrix: full service-crash, generation, and reconciliation coverage beyond the previously observed partial restart.

Unchecked task and checkpoint boxes for those items remain unchecked. The author-identity non-regression in `specs/core.md` still uses historical "credential seeding" and `[DIAG]` wording scoped to that earlier change ("This change"); this archive did not rewrite it.

## Readiness and baseline
Ready; analyze result is PASS after resolving both user decisions and completing the test-first dependency plan and scenario coverage in tasks.md. This is readiness for later implementation, not a claim that product tests, native compilation, supervision, or real authentication have passed.

Repository baseline: `6a8dde568e5d1ada3aa1aefe7be6f323fb724163`. No active change folders or legacy nested source specs existed when inspected. Pre-existing modifications, each one line added/removed, are retained unchanged:

| Path | Baseline SHA-256 |
|---|---|
| `wiki/architecture.md` | `a017d9e7044ffe722e3c2cefb0857e43418b9acc754be9cbd2ef431cf05a49fb` |
| `wiki/conventions/cli-runtime-boundary.md` | `0d3dfe39f30a0c328540fbd89f9356b4e19347fece0d89b9b9c31e36bb7092d8` |
| `wiki/domain/devcontainer-apple-gaps.md` | `4064d3272968e514463c401cd0a41059da4ac04ec949e91cab3d106d63afd441` |
