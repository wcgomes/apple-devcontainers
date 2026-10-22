# Change Spec: git-broker-detached-lifecycle

Target domain: core. The requirements below replace LaunchAgent supervision for the per-user Git credential broker with a demand-started detached process from the same executable. They supplement **Git credential store seeded on create paths** in [core.md](../../../core.md); existing acquisition, authorization, privacy, guest-helper migration, cooldown, soft-failure, discovery, and managed-container cleanup requirements remain in force except where explicitly replaced below. The superseded `homebrew-git-broker-lifecycle` draft was deleted after explicit confirmation and is not part of the live contract.

## ADDED Requirements

### Requirement: Demand-started detached Git credential broker

For a managed container with discovered HTTP(S) destinations, the first eligible credential lifecycle setup MUST ensure exactly one per-user broker process is serving, starting it from the currently invoking `adevcontainer` executable when none is acceptable, without sudo, a public command, a LaunchAgent plist, a launchd job, a `brew services` entry, or a login item. The process MUST be detached from the invoking CLI so it survives CLI exit, and it MUST complete the connection before HTTP(S) full clone or applicable create-path hooks when setup succeeds. Existing silent-skip, redacted soft-failure, and hook/clone failure semantics remain unchanged.

Broker demand MUST exist only for credential-dependent managed-container lifecycle work: fresh up, clone, rebuild replacement, real start, up start-stopped, and running up/start repair. Installation, login, list, inspect, exec, stop, delete, purge, unregister, and setup with no HTTP(S) destination or SSH-only sources MUST NOT start a process or create an endpoint. When a broker is running, unregister MUST remove the registration without provider access. Unregister without a running broker MUST succeed as a no-op without starting one; saved intent is not usable until a successor revalidates it.

The broker MUST be a single instance per macOS user. Concurrent CLI activations MUST serialize and MUST start at most one process; every successful registration MUST reach that owner. A losing spawn attempt MUST exit without replacing or unlinking the owner's endpoint. No second process may serve the same registry or control socket.

After the last registration is definitively invalidated or unregistered and no admitted work remains, the broker MUST exit successfully after a continuous 5-second zero-demand grace, rechecked at intervals no greater than 2 seconds. Under healthy, promptly responding local adapters, exit MUST complete no later than 7 seconds after demand reaches zero and MUST leave no running broker and no stale control socket. A later eligible setup MUST start a successor. SIGTERM and SIGINT MUST perform the same bounded cleanup as idle exit.

A crash MUST NOT be restarted automatically, and the product MUST NOT install or rely on any supervisor that restarts it. Until the next eligible lifecycle activation, credential lookups fail as ordinary misses and any stale control socket is not usable. The next activation MUST start a successor that loads saved nonsecret registrations, reconciles them against authoritative managed-container identity and state before recreating channels, and reconnects eligible running containers. A crash MUST NOT resurrect an explicit token override or replay pending requests.

#### Scenario: D01 - first demand starts a detached broker before consumers
- Given no broker process exists and a managed container has discovered HTTPS destinations
- When fresh up, clone, rebuild replacement, real start, or up start-stopped prepares the connection
- Then exactly one broker process from the invoking executable is serving before HTTP(S) full clone or applicable hooks, the setup connects, and that same process still serves lookups after the invoking CLI exits
- And no product-created LaunchAgent plist, launchd job, brew service, login item, or separate installed launcher exists

#### Scenario: D02 - no lifecycle demand creates no broker
- Given no broker process exists
- When install, login, list, inspect, exec, stop, delete, purge, unregister, or SSH-only/no-destination setup runs
- Then no broker process, control socket, or new registration intent is created, and stop/delete/purge still report success
- And no launchd or `brew services` operation is attempted, and saved intent is not usable until a successor revalidates it

#### Scenario: D03 - concurrent CLIs converge on one instance
- Given no broker process exists and two CLIs run eligible setup concurrently
- When both activations and registrations complete
- Then only one broker process and one control socket exist, both registrations reach that owner, neither registration is acknowledged by a losing instance, and no duplicate process survives
- And a later eligible activation reuses the same owner without spawning another

#### Scenario: D04 - idle exit removes the process and a later demand starts a successor
- Given a broker whose last registration was invalidated or unregistered and which has no admitted work
- When the 5-second grace elapses without new demand
- Then the process exits within the healthy bound, its owned control socket is removed, no automatic replacement starts, and a later eligible setup starts a successor before its consumers

#### Scenario: D05 - crash is recovered only by the next activation
- Given a broker with a running managed-container registration
- When the broker dies abnormally
- Then no replacement process starts during an observation window longer than the idle bound, the stale socket is not usable, and the next up/start or other eligible activation starts a successor that preserves the nonsecret registration, revalidates the running container, and reconnects before its consumers
- And the successor does not restore an explicit token override or replay a pending request

### Requirement: Executable-identity broker reuse and replacement

A running broker MUST expose a private, same-user-authenticated identity to CLI activation containing at least its process identity, the executable device and inode captured when it started, and its build/protocol identity. A broker whose identity matches the invoking executable MUST be reused without restart, without a reload, and without provider lookup. A broker whose executable or protocol identity differs MUST be retired gracefully before a successor from the invoking executable serves registrations. Replacement MUST preserve nonsecret registrations, remain bounded by the existing activation deadline, and MUST NOT leave two owners, a second registry writer, or a successor-unlinked endpoint.

Identical on-disk definition bytes, equal path strings, a live socket, or a successful liveness probe MUST NOT alone establish identity match. Concurrent activations observing the same stale instance MUST replace it at most once and MUST all converge on the successor. A broker that cannot be identified, or that accepts retirement but does not exit within the bound, MUST fail activation with the existing redacted soft-failure behavior rather than kill a process or unlink an endpoint it cannot authenticate, or start a competing owner.

#### Scenario: E01 - matching executable is reused
- Given a running broker started from the invoking executable and a healthy registration
- When repeated setup/reuse runs, including concurrent activations
- Then the same process remains, no new process is spawned, no restart or reload occurs, and provider lookup is not triggered merely by reuse

#### Scenario: E02 - upgraded executable replaces the running broker
- Given a broker running from an older executable, for example a replaced Homebrew keg or a rebuilt development binary, with saved nonsecret registrations
- When a CLI from the new executable activates credentials
- Then the old process exits gracefully, the new executable becomes the only owner, the registrations survive and are revalidated, and a subsequent lookup succeeds without re-registration or credential persistence
- And repeating the activation does not repeatedly kill the healthy successor

#### Scenario: E03 - replacement failure is bounded and recoverable
- Given a running broker that reports an unrecognized identity, refuses to exit, or becomes unreachable after accepting retirement
- When activation attempts reuse or replacement
- Then setup fails within its existing deadline using the existing redacted warning semantics, no second registry owner is created, no process or endpoint that cannot be authenticated is killed or unlinked, and a later retry can converge

### Requirement: Broker exit cleanup and package removal without service registration

On graceful exit the broker MUST cancel its channels and pending work, remove its control socket only when it still owns the same private socket inode, and MUST NOT unlink lock inodes or delete saved nonsecret registrations. Old-instance cleanup MUST NOT remove or replace a successor's endpoint. A successor MUST safely replace a stale, privately owned socket left by an abnormal exit without following symlinks or deleting unrelated files; a foreign or unsafe endpoint MUST fail closed.

The product MUST NOT install, load, or depend on a LaunchAgent plist, launchd job, `brew services` entry, login item, or other persistent host service. Ordinary package removal MUST therefore leave no product-created broker job or plist and MUST NOT require an uninstall hook, `zap`, a manual cleanup command, or a later login. Formula packaging, install, test, and caveats remain unchanged. A detached broker still running when the package is removed MUST exit under the existing 5-second grace once its last demand ends, MUST NOT be restarted, and MUST NOT recreate broker state after it exits.

#### Scenario: F01 - graceful exit cleans only owned runtime state
- Given a broker with active channels, pending work, and saved registrations
- When it exits for idleness or receives SIGTERM/SIGINT while a successor is binding
- Then channels and pending work terminate within their deadlines, the old cleanup removes only its owned socket, never a successor's socket or a lock inode, and any remaining saved registrations are preserved for successor reconciliation

#### Scenario: F02 - package removal leaves no job or plist
- Given a normal Formula install, upgrade, or removal, with or without a running detached broker
- When the operation completes
- Then no product-created LaunchAgent plist, launchd job, brew service, or login item exists, no uninstall hook or manual cleanup is required, and a running broker exits under the normal grace once its last demand ends and is not restarted

#### Scenario: F03 - stale or unsafe endpoint is handled safely
- Given an abnormal exit left a privately owned stale socket, or the expected socket path is a symlink or foreign object
- When the next activation starts a successor
- Then the owned stale socket is replaced safely, while a symlink or foreign endpoint fails closed without deleting unrelated files

### Requirement: Verification isolates detached broker state

Verification of a development build MUST use a unique private broker context and test-owned executable or executables under the approved temporary root. It MUST NOT touch production state or production broker identity, execute `launchctl`, write a plist, use a real launchd domain, authenticate with a real provider, run installed CLI code, or start user containers without separate authorization. Success, failure, and handled interruption MUST terminate only test-owned detached processes and remove their control sockets, registrations, endpoint directories, helper configuration, and exclusively created container resources. Abrupt unhandleable termination MUST have a narrowly targeted residual-cleanup procedure using only recorded test paths and process identity.

#### Scenario: V01 - isolated detached broker verification and cleanup
- Given a development build, a pre-existing user installation/state, authorized throwaway runtime resources, and a synthetic provider
- When isolated verification starts, replaces, crashes, retires, fails midway, and receives a handled termination signal
- Then CLI-exit survival, single-owner concurrency, idle exit, identity replacement, and no-automatic-crash-restart are demonstrated without any launchctl command, plist, production state, or real credential acquisition
- And production installation/state remains unchanged, cleanup removes only test-owned processes and paths, and abrupt termination has a documented targeted cleanup procedure

## MODIFIED Requirements

### Requirement: Git credential store seeded on create paths

**Delta-only:** the realized requirement in [core.md](../../../core.md) keeps its heading, all other paragraphs, and all other scenarios. This delta replaces only the spans below; on archive they replace exactly those spans in the current requirement.

**Replacement for the supervision sentence in the opening paragraph:**

A per-user broker process using the currently invoking adevcontainer executable MUST survive the invoking CLI and activate on demand without sudo. It MUST NOT install, load, or depend on a LaunchAgent plist, launchd job, brew service, or login item, and MUST NOT be restarted automatically after a crash (see **Demand-started detached Git credential broker**).

**Replacement for the token-persistence and override-recovery sentence in the secret-containment paragraph:**

Reading the existing explicit host token escape hatch is retained; the product MUST NOT propagate it through a new child environment or persist it across processes. Any per-session explicit override MUST be lost on broker restart and MUST require registration by an invoking CLI to restore it; successor recovery MUST NOT silently substitute a different credential source for that session until re-registration.

**Replacement for the paragraph beginning "The supervisor MUST restart a crashed service.":**

A crashed broker MUST NOT be restarted automatically. The successor started by the next credential-dependent lifecycle activation MUST reconcile saved nonsecret registrations against managed container identity/state before recreating channels. Transport loss while a container remains running MUST trigger bounded-backoff reconnection; failed requests MUST NOT be replayed automatically. Stopped/removed containers MUST have no live relay or usable session; stop/delete/purge and failed-clone cleanup MUST invalidate registrations without acquiring tokens. Runtime changes outside the CLI MUST be reconciled within a finite interval: an external stop or removal MUST invalidate that registration's session and pending replies within 2 seconds and retirement MUST complete no later than 9 seconds after the event, comprising the 2-second invalidation, the 5-second zero-demand grace, and at most one recheck interval, without provider polling. A failed, timed-out, unparseable, or ambiguous runtime observation MUST NOT be treated as absence: it MUST preserve the nonsecret registration and its recovery intent, MUST NOT cancel an admitted request solely for that reason, MUST NOT start idle retirement or deliver credentials to an unvalidated identity, and MUST NOT replay a request; existing request deadlines remain in force, and a later valid observation MUST either reconnect the same identity or definitively invalidate it and start a fresh grace. Registration and the final no-demand retirement decision MUST be serialized: a registration MUST either cancel retirement and connect on that owner or retry against an activated successor within its existing setup deadline, and it MUST never be acknowledged and then discarded by idle shutdown. Only one owner may exist, late old-generation results MUST NOT remove a newer session, and old-instance cleanup MUST NOT unlink a successor's endpoint. Broker idleness MUST NOT cause provider polling.

**Replacement for the Given line of scenario C16:**

- Given a registered container and an idle broker process

**Replacement for scenario C13:**

#### Scenario: C13 - activation races and process exit
- Given concurrent lifecycle invocations and a prepared container
- When the invocations finish or one broker instance crashes
- Then only one process owns the registry, credential lookup remains available after the invoking CLIs exit, no LaunchAgent or other persistent service is installed, a crash is not restarted automatically, and the next credential-dependent invocation starts a successor without sudo or another installed host executable

## REMOVED Requirements

### Requirement: Verification isolates supervised installation state
**Rationale:** The requirement mandates a temporary LaunchAgent identity, plist isolation, job bootout, and launchd-based survival/crash-recovery evidence. No installed service remains, so the verification contract is replaced by **Verification isolates detached broker state**.
