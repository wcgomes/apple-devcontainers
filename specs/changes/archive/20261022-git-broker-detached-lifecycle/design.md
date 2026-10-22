# Design: git-broker-detached-lifecycle

This document is non-normative. Guarantees live in [spec.md](spec.md); this file explains the selected mechanism, alternatives, and how the pieces interact.

## Approach
The CLI becomes the broker's only launcher. `GitCredentialBrokerService.ensure()` runs a serialized activation transaction and starts the same binary as a detached child in a new session when no acceptable owner exists. The broker keeps today's responsibilities unchanged: exclusive `broker.lock`, private registry, control socket, reconciliation, generation fences, and 5-second idle retirement. The difference is that retirement means process exit, not a dormant launchd job, and the next activation starts a fresh process.

```
CLI setup ──► activation.lock ──► control.hello ──► identity match? ──yes──► reuse
                    │                                   │
                    │                                   no
                    │                                   ▼
                    │                          control.retire + wait for exit
                    │                                   │
                    └──────────────► spawn(setsid, /dev/null) ──► wait for hello ──► register
```

## Alternatives

| Model | Advantage | Why rejected |
| --- | --- | --- |
| Previous LaunchAgent (`RunAtLoad`, conditional `KeepAlive`) | login activation, crash restart without a CLI | persistent plist/job outlives the keg, requires upgrade receipts and teardown machinery; homebrew draft dead-ends at uninstall |
| `SMAppService` agent | supported registration API | still a persistent login item with a plist-like registration and the same uninstall/upgrade problem; more platform surface, not less |
| XPC/Mach service | on-demand launchd activation | still launchd-managed and requires a bundled service target; overkill for one per-user socket |
| `brew services` | packaging convention | explicitly rejected; adds persistent state and a packaging dependency |
| Detached process from the same executable (chosen) | no installed state, no plist, trivial uninstall, one lifecycle owner | no login-time activation and no automatic crash restart; both are accepted product decisions |
| Fork+exec without `setsid` | simpler | child remains in the CLI's process group/session and can receive terminal signals; not reliably detached |

The chosen model trades automatic login/crash continuity for the absence of persistent host state. That is the user's decision: demand-driven availability, recovery by the next `up`/`start`, and an unchanged Formula.

## Identity handshake
The control socket is the authority for liveness because it already enforces same-user peer credentials and private inode ownership. Two private operations extend the host-only control protocol:

- `hello`: returns the broker's process identity, resolved executable path, executable device/inode captured at startup, and protocol/build identity.
- `retire`: asks the authenticated owner to stop gracefully; the reply is sent before the loop exits.

The CLI computes its own identity from the executable selected by the launch context (production: the invoking CLI; tests: the test-owned wrapper), using `realpath` plus `stat` device/inode, its Mach-O build UUID when present (or equivalent build identifier), and its protocol version, then compares. Matching device and inode means the same file, even through a different symlink path. The build UUID catches an in-place relink that keeps the inode; reading it costs a small header parse, not a full executable hash. Non-Mach-O test wrappers fall back to device/inode plus protocol. A Homebrew opt repoint or replacement keg resolves to a new inode, and a versioned development rebuild normally changes both; either forces replacement. Path equality, identical plist/definition bytes, or a connectable socket do not participate in the decision.

Why not a pid/identity file? A file is stale after SIGKILL and invites pid-reuse and TOCTOU bugs. The `hello` handshake is authenticated by the socket itself and carries the process identity of the responder. Why not SIGTERM directly? The CLI would need a trustworthy pid; the authenticated `retire` reply is simpler and testable, and same-user processes can already signal each other, so no security boundary is weakened.

## Activation flow
1. Validate the context; no plist path remains in the production context.
2. Take `activation.lock` with the caller's deadline. This is the same serialization point used today, so concurrent CLIs cannot race into two spawns.
3. Send `hello` with a 2-second bound for this pre-spawn identity check, so a connected but silent endpoint fails closed instead of consuming the deadline and inviting a spontaneous successor spawn. Readiness polling after a spawn keeps the remaining activation deadline: a new broker may still be reconciling before it answers.
   - Match: reuse, release lock, proceed to register.
   - Mismatch: send `retire`, wait for the socket to disappear or the owner to become unreachable within the replacement bound, then continue.
   - No listener (absent or stale socket): continue.
   - Connected but unrecognized/unsafe: fail closed with redacted setup warning. A connect failure is absence; after a successful connect, a `hello` timeout is `unrecognized`, while an immediate close remains the owner-exit race (`absent`).
4. Spawn the detached broker. The child receives the production context implicitly; a test context is passed through the existing private `launch-context.json` mechanism under the temporary root. The child inherits no token environment and no CLI file descriptors beyond the private context.
5. Poll `hello` until the identity matches or the deadline expires. If a mismatched owner appears during the wait, retire it once and continue polling rather than accepting it. A losing spawn that cannot take `broker.lock` exits successfully without touching the socket, so the poll converges on the winner.
6. Release the lock and issue the original registration/refresh request.

Failure at any step maps to today's soft setup warning except spawn/readiness errors that indicate a broken installation; the command still does not fail, delete a container, or enter recovery.

## Detached spawn
`posix_spawn` with `POSIX_SPAWN_SETSID` gives the broker its own session with no controlling terminal. File actions map stdin/stdout/stderr to `/dev/null`; `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps unrelated descriptors closed; the environment is filtered of `ADEVCONTAINER_GIT_TOKEN`. The parent does not wait for the child and does not retain a pipe, so CLI exit cannot terminate or signal it. It opportunistically reaps a spawn that exits during the readiness window; a live broker is re-parented to launchd when the CLI exits. The broker ignores SIGHUP in addition to handling SIGTERM/SIGINT gracefully.

## Single ownership and races
- `activation.lock` serializes CLI activation. It is held only for the probe/replace/spawn/readiness window, never for the broker lifetime.
- `broker.lock` remains the lifetime singleton. A spawned child waits briefly for it (bounded by its startup deadline); if another owner holds it, the child exits 0. This covers a successor spawned while a retiring broker is still cleaning up.
- Idle retirement and registration admission already share the broker state lock (`retireIfIdle`). A registration that loses that race gets a transport failure and retries activation against the successor, which is the existing tested behavior.
- Old cleanup unlinks `control.sock` only if the current inode still matches the one it bound. Lock inodes are never unlinked: removing a lock file while a waiter holds it creates two independent locks.
- A crash leaves the lock released by the kernel and the socket stale. The successor's existing safe-replace logic validates type, owner, mode, and symlink status before unlinking, so an attacker-controlled path fails closed.

## Crash and idle behavior
No process watches the broker. After SIGKILL nothing runs, the socket is stale, and in-flight helper gets fall through as misses. The next eligible setup starts a successor; the registry makes recovery possible without credentials on disk. `hello` is not attempted by `unregister` (`activate: false`), so stop/delete/purge cannot start a broker; if none is running they are no-ops and any saved intent is revalidated by a future successor before use. Idle exit keeps the 5-second grace and 2-second recheck already implemented; because there is no loaded job, exit has no restart tail. Channel teardown is bounded: process reaping uses a non-blocking deadline, and shutdown cancels all channels concurrently with an overall 1.5-second cap, so one slow local adapter cannot extend the 7-second healthy exit bound.

The replacement paragraph for the supervisor-restart span also restates the archived `git-broker-idle-shutdown` I05–I07 guarantees: external stop/removal invalidation within 2 seconds and retirement within 9 seconds, unknown runtime observations preserving demand, and the registration-versus-retirement race. This is traceability only: before this change was archived, the realized `specs/core.md` requirement had not received those archived behaviors. The earlier archive stays immutable; this delta carries the behaviors into the source spec on archive.

## Supersession of the Homebrew draft
| Draft content | Disposition |
| --- | --- |
| Stable opt launch path and loaded-target identity | Obsolete as a launch path; the durable idea survives as executable device/inode + build UUID + protocol identity comparison at activation |
| Loaded-definition receipt and interrupted bootstrap migration | Obsolete; no loaded definition exists to migrate |
| Automatic teardown of plist/job/state | Obsolete; no plist or job is created, so uninstall has nothing to unload |
| Cask migration, `zap`, account/coexistence analysis | Obsolete; no distribution change is required or authorized |
| Manual uninstall command rejection | Retained as a product constraint, now trivially satisfied |
| No login-time broker demand | Retained and strengthened: no login item at all |
| Synthetic temporary-label verification | Superseded by the detached-process probe; no launchd label exists |

The draft was deleted from the active set after explicit confirmation, as recorded in [tasks.md](tasks.md). Earlier archives remain immutable and untouched. The Formula generator and rendered Formula remain unchanged by this detached-lifecycle change; no `post_install`, `services`, or uninstall hook is added.

## Test strategy
The planned test-first strategy was not captured as red-before-green: the detached implementation had replaced launchd before the new assertions first ran. The following coverage passed after review remediation; [tasks.md](tasks.md) records the runs and separately authorized real smoke:

- `Tests/adevcontainerTests/GitCredentialBrokerServiceTests.swift`: fake detached launcher and fake broker status to prove one spawn, identity reuse, mismatch retirement, bounded failure, and unregister-without-spawn. The launchctl mocks, plist byte assertions, and receipt/migration tests are deleted.
- `Tests/adevcontainerTests/GitCredentialBrokerDetachedTests.swift` (new): real test-owned executable under `$TMPDIR/opencode`, synthetic ports, and the production service/control/entry code. Covers CLI-exit survival, two-CLI convergence, idle exit, crash without restart, upgrade replacement using two executable copies, and owned-socket cleanup.
- `Tests/adevcontainerTests/GitCredentialBrokerIdleLaunchdTests.swift`: deleted with its probe entry.
- `Tests/adevcontainerTests/GitCredentialBrokerSmokeHarness.swift` and `SmokeTests.swift`: process/socket manifest, termination cleanup, no `launchctl` calls, no plist paths.
- `Tests/adevcontainerTests/main.swift`: probe dispatch moved to the detached suite; launchd suite removed.
- `Tests/GuestGitCredentialRelay/SMOKE.md`, `Tests/GuestGitCredentialRelay/README.md`, `README.md`, `CONTRIBUTING.md`: document detached verification and remove launchd gates.

The synthetic suite remains the primary regression suite. Timing assertions reuse the existing 5–7 second retirement window with tolerance for CI scheduling; deterministic barrier tests cover the registration/retirement boundary. No test selects production state, runs `launchctl`, boots a job, uses a real provider, or starts a user container.

## Security considerations
The control socket stays owner-private and peer-checked. `hello` exposes only nonsecret identity metadata. `retire` is available to the same user who could already send SIGTERM; it does not add a privilege boundary. Spawn arguments contain no secrets, and the child environment excludes the explicit token override so it cannot be inherited across the process boundary. The broker never runs as root or adopts another user's registry. Replacement refuses to act on an endpoint it cannot authenticate rather than guessing from a pid or path.
