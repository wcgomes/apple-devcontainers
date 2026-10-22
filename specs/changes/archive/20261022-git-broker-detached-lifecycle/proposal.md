# Proposal: Detached Git credential broker lifecycle

## Intent
At proposal time, the per-user Git credential broker implementation used a LaunchAgent with `RunAtLoad`/`KeepAlive` (not a released installation). That tied credential availability to a persistent launchd job and a plist that outlives the binary, invited upgrade/cleanup machinery, and kept crash recovery coupled to a supervisor. This change replaces it with a demand-started broker process spawned by the same `adevcontainer` executable, so the product owns its lifetime without any installed host service.

## Scope
Change the core credential-supervision contract only: on-demand detached start before clone/hooks, one instance per user, reuse of a matching running broker, graceful replacement when a different executable must take over, preserved 5-second idle retirement, no automatic crash restart with recovery by the next eligible lifecycle activation, private socket/state cleanup on exit, and no LaunchAgent/plist/launchd/`brew services` surface. Managed containers only. The superseded `homebrew-git-broker-lifecycle` draft was deleted after explicit confirmation during execution. Distribution behavior is explicitly unchanged: the Formula stays as-is because there is no plist or job to remove.

## Non-goals
The proposal-only dispatch did not implement code or edit root specs, archives, or wiki; subsequent implementation and archive are recorded in [tasks.md](tasks.md). No Formula, Cask, tap, release, or packaging change; no uninstall hook; no `brew services`; no manual broker-uninstall command; no `zap`-based cleanup; no migration or deletion of pre-existing LaunchAgent artifacts (this broker has no released installation, and the user confirmed no agent was created). No cross-user cleanup, privileged installation machinery, login item, XPC service, or auxiliary resident helper. No change to credential acquisition precedence, authorization scope, helper installation, guest relay protocol, rejection cooldown, soft-failure behavior, container/workspace ownership, or public CLI surface. Earlier archives remain immutable; wiki changes are outside this change.

## Approach
`ensure()` becomes a serialized activation transaction: take the existing activation lock, probe the private control socket for the broker's authenticated executable identity, reuse it when the identity matches the invoking executable, otherwise retire it gracefully and spawn a successor with `posix_spawn` in a new session, detached stdio, and a sanitized environment. The broker owns the same singleton lock, registry, control socket, reconciliation loop, and 5-second idle exit; it simply exits the process instead of settling into a dormant loaded job. Crash recovery follows from the next activation, not from a supervisor. Replacement is identity-based (executable device/inode and protocol/build identity), never from plist bytes or socket liveness alone. The Homebrew draft's durable upgrade insight survives as identity-based replacement; its launch-path, receipt, teardown, Cask, and account-scope machinery becomes obsolete.

## Decision index
- **Execution model:** a detached process from the same executable replaces launchd supervision. No plist, job, `brew services`, login item, or installed launcher is created. This is the only model that needs neither migration nor uninstall teardown under an unchanged Formula. See [design.md](design.md) **Alternatives**.
- **Start trigger:** only credential-dependent managed lifecycle setup (fresh up, clone, rebuild replacement, real start, up start-stopped, running up/start repair) may start the broker. Install, login, list, inspect, exec, stop, delete, purge, unregister, and no-destination/SSH-only paths never start it.
- **Single instance:** the existing activation lock serializes CLI activation; the broker keeps the exclusive `broker.lock`. A spawned loser exits successfully without touching the winner's endpoint, and setup converges on the single owner.
- **Identity and upgrade:** the broker reports an authenticated, nonsecret identity over the private control socket (process plus executable device/inode and protocol/build identity). Matching identity reuses the process with no restart; differing identity triggers one bounded graceful retirement followed by a successor spawn. Registrations survive replacement and are revalidated. See [design.md](design.md) **Identity handshake**.
- **Crash semantics:** no supervisor and no self-restart. A crash leaves credential lookups failing normally and a stale socket; the next eligible setup starts a successor that reconciles saved nonsecret registrations. Explicit overrides and pending requests are not recovered or replayed.
- **Idle and exit:** retain the implemented 5-second continuous zero-demand grace with a recheck interval no greater than 2 seconds. Healthy local retirement completes within 7 seconds. Graceful exit removes only a still-owned control socket, cancels channels/pending work, and preserves registrations and lock inodes.
- **Unregister without a broker:** must be a no-op success, never an activation. Stop/delete/purge therefore cannot resurrect the service; a later broker reconciles any stale saved intent before use.
- **Uninstall/packaging:** the product creates no persistent service registration, so ordinary package removal leaves no job or plist and needs no hook. The Formula source and rendered output remain unchanged. A detached process alive at removal exits under the 5-second grace once its last demand ends and cannot be restarted.
- **Supersession:** the `homebrew-git-broker-lifecycle` draft was deleted after explicit confirmation; earlier archives were untouched. Durable upgrade behavior moved to the new spec as identity-based replacement; stable-opt launch paths, loaded-definition receipts, automatic teardown, and Cask migration become obsolete because no host service is installed. The manual-uninstall command remains rejected; there is simply nothing for it to clean.
- **Core integration:** the delta replaces only the listed spans of **Git credential store seeded on create paths** (supervision sentence, token-persistence sentence, supervisor-restart paragraph, C16 Given line, scenario C13), removes the LaunchAgent-based verification requirement, and adds detached-process verification plus the new lifecycle requirements. At proposal time, the realized `specs/core.md` lacked the archived `git-broker-idle-shutdown` requirements; this delta therefore restates the durable 5-second demand/idle semantics without reintroducing launchd supervision. After the merge, `specs/core.md` contains no launchd supervision requirement for this broker; launchd references prohibit service installation or use during verification. See [spec.md](spec.md).
- **Verification:** delete the separately authorized real-launchd probe and its 94-test surface; verify detached behavior with a test-owned executable under a private context. No `launchctl`, plist, production state, real container, or real provider. The synthetic suite remains the main regression net.

## Clarifications
- **Q:** Is an automatic uninstall transaction still required?
   **A:** No. The user rejected a manual uninstall command and a Cask migration. With a detached process there is no plist/job to clean, so the Formula stays unchanged; the superseded draft was removed after confirmation.
- **Q:** Must an existing LaunchAgent be migrated or removed?
  **A:** No. The user confirmed no agent was created; the broker has no released installation. Migration and post-uninstall job cleanup are out of scope.
- **Q:** Should crash recovery remain automatic?
  **A:** No. The user chose recovery by the next `up`/`start` (or other eligible activation), which also removes the need for `KeepAlive` and any supervisor.

## Inventory of LaunchAgent-dependent surfaces

The following inventory records the proposal-time baseline and planned actions, not outstanding work; completion is recorded in [tasks.md](tasks.md).

| Path | Proposal-time LaunchAgent dependency | Planned action |
| --- | --- | --- |
| `Sources/ADevContainerLib/Git/GitCredentialBrokerService.swift` | plist generation, `RunAtLoad`, `KeepAlive`, `launchctl print/kickstart/bootout/bootstrap`, loaded-definition receipt, migration | Replace with detached spawn, identity handshake, reuse/retire logic |
| `Sources/ADevContainerLib/Git/GitCredentialBrokerEntry.swift` | launch-context file for launchd; signal handling only terminates the loop | Keep private entry, add detached-session behavior; no plist |
| `Sources/ADevContainerLib/Git/GitCredentialControl.swift` | control loop has no identity/retire operation | Add private `hello`/`retire` operations and owned-socket exit |
| `Sources/ADevContainerLib/Runtime/CredentialProcessGuardian.swift` | comment says launchd/init reaps orphans | Wording review only; reaping by launchd as PID 1 remains true |
| `Tests/adevcontainerTests/GitCredentialBrokerServiceTests.swift` | `CredentialConcurrentLaunchctl`, `CredentialMigrationLaunchctl`, plist bytes, receipts, bootout/bootstrap failures | Replace with fake launcher/identity tests; delete migration tests |
| `Tests/adevcontainerTests/GitCredentialBrokerIdleLaunchdTests.swift` | real isolated launchd job, plist, bootout, KeepAlive migration | Delete; replace with detached-process probe |
| `Tests/adevcontainerTests/GitCredentialBrokerSmokeHarness.swift` | plist path, `launchctl bootout`, production-plist guard, launchd cleanup instructions | Replace with process/socket manifest and termination cleanup |
| `Tests/adevcontainerTests/GitCredentialBrokerSmokeTests.swift` | `SmokeLaunchctl`, plist assertions, "No LaunchAgent" refusal text | Rewrite around detached process and no-launchctl assertions |
| `Tests/adevcontainerTests/main.swift` | launchd probe dispatch and suite registration | Point probe at detached broker; register replacement suite |
| `Tests/GuestGitCredentialRelay/SMOKE.md` | LaunchAgent label, plist, `launchctl bootout`, launchd lifetime gates | Rewrite for detached process verification; no launchd |
| `Tests/GuestGitCredentialRelay/README.md` | states smoke does not run launchd; mentions isolated launchd smoke | Update wording |
| `Tests/GuestGitCredentialRelay/build_artifacts_tests.sh` | comment only | Comment update or no functional change |
| `Tests/adevcontainerTests/GitCredentialRelayChannelTests.swift` | comment only | Comment update or no functional change |
| `README.md` | documents the per-user LaunchAgent and supervised restart | Document demand-started detached broker |
| `CONTRIBUTING.md` | launchd smoke instructions | Replace with detached-process instructions |
| `specs/core.md` | supervision and launchd restart contract; LaunchAgent verification requirement | Apply the delta spans on archive |
| `specs/changes/homebrew-git-broker-lifecycle/` | draft built on plist/job/Cask teardown | Delete after confirmation; archive untouched |
| `scripts/render-homebrew-formula.sh` | no broker lifecycle content | No change; assert unchanged |
| `.github/workflows/ci.yml` | runs the synthetic suite only; launchd test is env-gated | No change expected |

## Baseline
Recorded on 2026-10-21 before creating these artifacts, branch `main`, HEAD `6a8dde5`: 79 porcelain entries (35 modified, 2 deleted, 42 untracked entries), 53 untracked files, 90 distinct changed paths, tracked diff 37 files with `+838 / -2824`. Porcelain SHA-256: `c70145901d9b2d65cf0bcdf9251900d35dfa87bbd3fdfce1eb4c2697ef1ccfda`. This dispatch created only this change folder. The superseded draft recorded 318 files / 87 entries; that figure does not match the current tree and was not reconciled or altered here.

## Readiness
Analyze and post-remediation verification passed with no unresolved clarification marker; implementation and the confirmed Homebrew-draft deletion are complete. The user explicitly authorized the final documentation updates and archive on 2026-10-22. [tasks.md](tasks.md) records the synthetic verification, separately authorized plantsuite smoke, evidence limits, and archive completion. No release publication or Homebrew change is claimed.
