# Change Spec: automatic-git-credentials

This delta covers HTTPS and the existing HTTP compatibility included in the realized HTTPS authentication category. Only explicitly discovered scheme/host/port destinations are authorized. Artifact creation and readiness analysis do not themselves execute or verify implementation.

## MODIFIED Requirements

### Requirement: Git credential store seeded on create paths

**Target:** `core.md`, replacing this requirement and all its seeding-specific scenarios with the automatic credential behavior below. The historical heading is retained to identify the exact replacement target; token seeding is no longer the required behavior.

For managed containers with discovered HTTPS or legacy HTTP credential destinations, the product MUST automatically prepare the resolved connection user's Git credential helper for on-demand host acquisition before create-path hooks, after ownership preparation. A per-user service using the installed adevcontainer executable MUST survive the invoking CLI, activate automatically without sudo, and be supervised for restart after failure. Guest setup MUST NOT require Python, socat, a compiler, GCM, or additional package installation. New product-managed persistent guest token stores MUST NOT be created.

Discovery MUST retain the unique HTTP(S) fetch destinations of the host workspace for bind mode and the stamped Git URL for volume mode; clone MUST register its requested HTTP(S) URL. Legacy HTTP MUST retain its original scheme and existing provider policy without widening to new hosts/ports or permitting scheme downgrade. The product MUST NOT enable unsafe-HTTP overrides in a host provider. Missing host Git, no repository/remotes, or absent volume URL MUST remain silent skips without making host Git a prerequisite for up. Missing credentials from a provider MUST be a silent miss. Duplicate source URLs MUST NOT create duplicate helpers or sessions.

Setup MUST apply to fresh up, clone, rebuild replacement, real start, up start-stopped, and already-running up/start reuse. Existing healthy sessions on reuse MUST NOT be needlessly recreated or trigger provider lookup; missing or broken sessions MUST be repaired. Setup errors MUST warn with redaction and MUST NOT themselves fail up/start/rebuild, delete a container, or enter recovery. Hooks retain their own failure semantics.

#### Scenario: C01 - create and rebuild prepare before hooks
- Given bind up, bind rebuild, or volume rebuild with discovered HTTP(S) destinations and an available provider
- When the container is running and ownership is prepared
- Then the resolved connection user has a connected credential helper before any create-path hook, including when that user is root, without a persisted token seed
- And bind discovery uses host fetch remotes while volume discovery uses the stamped URL

#### Scenario: C02 - real start and running reuse
- Given either a stopped managed container or an already-running matching container
- When start or up selects it
- Then real start prepares the connection before restart postStart, running reuse repairs only missing/broken connections, and neither duplicates a healthy session nor queries credentials merely to reuse it

#### Scenario: C03 - silent skips and soft setup failure
- Given missing host Git, no HTTP(S) destinations, a non-repository workspace, an absent stamped URL, or a provider miss
- When lifecycle setup or helper lookup runs
- Then missing sources/providers do not add a lifecycle failure or warning, and an actual installation/transport setup failure produces only a redacted warning without product-triggered deletion or recovery

The product MUST preserve pre-existing global helpers and their ordering, append its non-Azure helper idempotently, and install its Azure helper exactly once at the matching registered scheme's URL-scoped helper key. HTTPS Azure MUST retain its existing helper key and `credential.https://dev.azure.com.useHttpPath=true`; explicitly discovered legacy HTTP Azure MUST receive equivalent HTTP-scoped helper/path handling without authorizing HTTP for an HTTPS-only registration. Azure configuration MUST remove legacy empty helper values, MUST NOT write an empty helper reset, and MUST NOT reset global helper lists. The automatic freshness guarantee applies when the product helper is invoked; earlier user-configured helpers MAY satisfy Git without invoking it and MUST NOT be silently disabled.

On get, the product helper MUST authorize the destination before contacting a host provider. The authorized destination set MUST remain the HTTP or HTTPS scheme plus exact normalized host and port discovered for that container, retaining sibling repository coverage across paths rather than limiting lookup to the original repository. Unknown hosts, alternative ports, unregistered schemes, and non-HTTP(S) protocols MUST be misses without provider calls. HTTP and HTTPS MUST NOT authorize each other. Queried usernames MUST NOT select a different host account/provider; responses MUST retain the queried username when supplied, otherwise the acquired username. The host MUST receive the actual validated repository path for Azure lookups; a missing organization path MUST be a miss without a pathless GCM call. It MUST NOT silently substitute a different repository path.

#### Scenario: C04 - Azure configuration and path compatibility
- Given an HTTPS Azure destination (or explicitly registered legacy HTTP Azure destination), a legacy empty URL-scoped helper, existing global helpers, and a lookup for a sibling repository on that host
- When setup and get run
- Then the product helper occurs exactly once at the matching scheme's Azure URL-scoped key, useHttpPath is true, empty resets are absent, global helpers/order are preserved, and the host receives that sibling's actual organization/repository path
- And a pathless Azure lookup never reaches GCM

#### Scenario: C05 - destination and username compatibility
- Given a registered HTTPS host and an acquired username X
- When Git requests another repository on that host with username Y, or requests an unregistered host, different port, unregistered scheme, or non-HTTP(S) protocol
- Then the sibling request returns the acquired password with username Y without using Y to change host account selection, while unauthorized requests produce misses without provider calls

#### Scenario: C06 - existing helper ordering
- Given a user-configured helper before the product helper
- When setup runs repeatedly and Git performs a lookup
- Then the original helper and ordering remain, the product entry is not duplicated, and an earlier complete answer is not represented as proof of product lookup or freshness

#### Scenario: C19 - legacy HTTP without implicit expansion
- Given a discovered HTTP destination and a distinct HTTPS-only destination
- When lookup requests the registered HTTP destination, another port/host, or HTTP on the HTTPS-only destination
- Then only the registered HTTP destination can reach the existing provider, its scheme/path/port are retained, an unsafe-HTTP provider refusal remains a miss, and no unsafe override or downgrade is enabled

Each product get MUST use the shared host acquisition provider rather than a product guest-token cache. Host acquisition MUST disable Git terminal prompts and provider GUI/TTY prompts, respect a finite deadline, and return a miss if interaction is required. Azure provider interaction MUST be disabled in addition to `GIT_TERMINAL_PROMPT=0`. The product MUST NOT implement OAuth renewal or claim a provider's unchanged token is evidence of renewal. Provider nil MUST permit normal Git helper fallthrough; product-managed clone/hooks MUST remain noninteractive on authentication failure and offer host-login guidance.

Store MUST consume input without persisting credentials or approving them in the host credential store. Erase MUST NOT invoke host credential reject/erase, remove account bindings, or modify the host token cache. It MUST temporarily suppress replay of a matching credential previously delivered for that session/destination, without suppressing a newer different credential or affecting other containers. Suppression MUST expire after a finite cooldown; a subsequent get MAY consult the provider again. Helper operations MUST NOT contain an unbounded internal reacquisition/rejection loop.

#### Scenario: C07 - lookup freshness and provider UI required
- Given two successive product-helper gets and a host provider that changes its answer between them
- When the gets run
- Then each obtains the current provider answer without a guest seed, and a provider requiring interaction instead results in a bounded miss with no GUI/TTY prompt or product OAuth-refresh claim

#### Scenario: C08 - store and correlated erase
- Given a credential delivered in one session and a newer different credential delivered for the same destination
- When store or a delayed erase for the older delivery arrives
- Then store persists/approves nothing, erase does not suppress the newer credential, and neither operation mutates host credential storage or another session

#### Scenario: C09 - rejection cooldown is finite
- Given a delivered credential that Git rejects and a provider that continues returning the same value
- When get occurs during suppression and after its deadline, or explicit refresh clears suppression
- Then the rejected value is not immediately replayed, the cooldown eventually permits a fresh attempt, and no single helper operation loops indefinitely

The product MUST provide private per-container channels without network listeners, bind mounts of host credential material, or guest access to host runtime control endpoints. Session identity and destination authorization MUST derive from host-established context, not guest-asserted container identity. Guest connection endpoints MUST be accessible only to the resolved connection user, subject to guest root's existing authority. Product-owned helper/session directories MUST be private and correctly owned; stale sockets MUST be safely replaced without following attacker-controlled symlinks or deleting unrelated files.

Secrets MUST remain in confidential pipes/socket payloads and process memory, never new persistent token files, process argv, product-created environment variables, labels, progress, success JSON, or diagnostics. Reading the existing explicit host token escape hatch is retained; the product MUST NOT propagate it through a new child environment or persist it for supervision. Any per-session explicit override MUST be lost on service restart and MUST require registration by an invoking CLI to restore it; service recovery MUST NOT silently substitute a different credential source for that session until re-registration. No provider/helper command text or local filesystem path supplied by the guest MUST be executed.

#### Scenario: C10 - session isolation and malicious input
- Given two registered containers and an untrusted guest request claiming the other container's identity or carrying an unauthorized destination, malformed fields, oversized payload, or command text
- When the broker processes it
- Then identity remains bound to the established channel, invalid requests do not reach the provider, unrelated sessions remain usable, and no arbitrary host command runs

#### Scenario: C11 - secret containment and private endpoints
- Given successful lookup, provider/transport errors, or endpoint provisioning against a stale or symlinked path
- When the operation finishes
- Then secrets appear only in intended credential-channel responses, endpoints have private ownership/permissions, no host credential/control endpoint is mounted or published, and unsafe paths fail without deleting unrelated files

#### Scenario: C12 - explicit token override restart
- Given a CLI registration with the existing explicit host token override
- When the service restarts
- Then the override was not persisted or put in child environment, its session cannot silently switch credential source, and re-registration restores that override through private IPC

Only one service instance per macOS user MUST own the session registry. Simultaneous activations MUST be idempotent. Concurrent requests MUST have bounded admission, payload size, deadlines, and independent response correlation. Service/channel failure MUST terminate pending waits within their deadlines. Recovery MUST reject messages from prior service/container session generations and MUST not authorize a new container solely because it reuses an old name.

The supervisor MUST restart a crashed service. The restarted service MUST reconcile saved nonsecret registrations against managed container identity/state before recreating channels. Transport loss while a container remains running MUST trigger bounded-backoff reconnection; failed requests MUST NOT be replayed automatically. Stopped/removed containers MUST have no live relay or usable session; stop/delete/purge and failed-clone cleanup MUST invalidate registrations without acquiring tokens. Runtime changes outside the CLI MUST be reconciled within a finite interval. Service idleness MUST NOT cause provider polling.

#### Scenario: C13 - activation races and process exit
- Given concurrent lifecycle invocations and a prepared container
- When the invocations finish or one service instance crashes
- Then only one service owns the registry, credential lookup remains available after the invoking CLIs exit, and launchd restarts a crashed service without sudo or another installed host executable

#### Scenario: C14 - out-of-order concurrency and overload
- Given multiple concurrent gets whose provider replies complete out of order and requests beyond admission bounds
- When requests complete or time out
- Then every reply reaches only its own waiter, capacity is bounded, overload fails within the request deadline, and other sessions are not starved indefinitely

#### Scenario: C15 - transport failure, restart, and generation fence
- Given pending requests and a stale guest socket
- When the relay/container or broker restarts, including a rebuild reusing the name
- Then pending requests fail within their deadline, stale endpoints are safely replaced, nonsecret registrations are revalidated, old-generation replies/identities are rejected, and a fresh lookup succeeds after connection recovery without replaying the old request

#### Scenario: C16 - stop, removal, and external reconciliation
- Given a registered container and an idle supervised service
- When stop, delete, purge, failed-clone cleanup, or an external runtime stop/removal occurs
- Then sessions/relays and pending requests are cleaned up or invalidated within bounded waits/reconciliation, no tokens are polled, and workspace/volume deletion semantics remain unchanged

On existing containers, setup MUST migrate the product-owned seeded helper to on-demand operation and remove the legacy product-owned token store without reading or logging its contents. It MUST NOT delete unidentified user credentials, reset user helper chains, or fall back to a legacy product seed if the host is unavailable. Legacy clone store files without trustworthy ownership/provenance MUST be preserved; user/legacy helpers that answer before the product remain outside the automatic freshness guarantee. Migration MUST be idempotent.

#### Scenario: C17 - migration without destructive credential cleanup
- Given an existing product helper/store, user helper configuration, and an unmarked legacy clone store file
- When up/start reuse or refresh performs migration twice
- Then the product helper becomes on-demand, the product-owned store is removed without exposing its content, unmarked/user credential files and helper ordering remain, and host failure does not replay the removed product seed

`adevcontainer refresh-credentials [--name]` MUST retain managed selection and running-only behavior. On a running target it MUST ensure/recover the service/helper/channel, update authorization from the same discovery sources, clear that session's rejection suppression, and validate acquisition for discovered credential sources without persisting tokens in the guest. No credentials available MUST remain a silent skip; setup/exec failure MUST fail this explicit command with a redacted structured error. It MUST NOT fetch/pull/push, write the workspace, start/stop the container, or promise provider token renewal.

#### Scenario: C18 - explicit refresh and stopped target
- Given a running managed target with a broken channel and suppressed credentials, or a stopped target
- When refresh-credentials selects it
- Then the running target is repaired/revalidated without token persistence or repository operations, with setup failure reported rather than soft-failed; a stopped target is refused with a start hint and no start/stop/exec

### Requirement: In-container full clone populate (auth by URL scheme)

**Target:** `clone.md`. Replace only the HTTPS authentication row (including its existing HTTP compatibility), shared-acquisition paragraph, and the credential-specific scenarios named below. All other populate steps, SSH/other rows, verification, volume reuse, and failure cleanup remain unchanged. The superseded scenarios are `HTTPS uses host credential fill one-shot`, `create-path seeding reuses the shared acquisition contract`, and `clone keeps a single populate mechanism (regression)`; public/private fallback and no-GCM-in-guest scenarios remain applicable with the new helper.

For HTTPS and legacy HTTP clone, the product MUST establish the same on-demand credential connection used by up/start before the in-container full clone and subsequent create-path hooks. The shared host acquisition contract MUST retain existing provider precedence (explicit host token, Git credential fill with protocol/host/path, optional existing GitHub CLI fallback), with host interactivity disabled and bounded waits. Clone MUST NOT configure new credential.helper store entries, approve/persist token seeds, or pass credential values through guest environment variables. All non-Azure and Azure HTTP(S) clones MUST use the same connection mechanism; Azure MUST retain the URL-scoped helper and organization path behavior defined above. No GCM installation/detection in the guest or mounting of host credential stores is permitted.

If host credentials are unavailable, an anonymous in-container clone MUST still be possible. A private authentication failure MUST produce a structured host-login/SSH hint without a new token CLI flag. On a reused populated volume, clone MUST skip populate as before but prepare the automatic connection before hooks. Clone failure cleanup MUST invalidate its session and retain the existing created-versus-reused volume deletion rules.

#### Scenario: L01 - one automatic HTTPS mechanism before populate
- Given a fresh HTTPS or legacy HTTP clone for Azure or a non-Azure host and an available host provider
- When clone populates the volume
- Then the resolved connection user's automatic helper is connected before the single in-container full clone and hooks, verification still checks .git, no host full-clone/tar path runs, and no token store/approve/secret environment mechanism is installed

#### Scenario: L02 - public/private fallback and volume reuse cleanup
- Given no host credentials, or a reused populated workspace volume
- When HTTPS clone runs
- Then public anonymous clone can succeed, private authentication fails noninteractively with a redacted host-login hint, and populated reuse skips clone while preparing the connection before hooks
- And any failed-clone session is invalidated, newly created workspace volumes follow existing cleanup, and reused volumes are preserved

#### Scenario: L03 - SSH regression
- Given an SSH clone URL and either a present or absent host SSH agent
- When clone runs
- Then existing --ssh injection/missing-agent behavior is unchanged and no HTTPS credential session is created for that SSH URL

## ADDED Requirements

### Requirement: Self-contained guest credential artifacts

The distributed macOS CLI MUST contain version-matched static Linux relay/client artifacts for linux/arm64 and linux/amd64. Runtime selection MUST use the actual guest platform rather than the host architecture. The product MUST verify artifact integrity and protocol/platform compatibility before allowing credential delivery, and MUST fail closed on unsupported/missing/corrupt artifacts using existing soft lifecycle versus explicit-refresh error semantics. It MUST NOT install a translator, enable Rosetta, download executable artifacts at runtime, or fall back to Python/socat. Release and source builds MUST have a documented pinned, checksum-verified build path and reproducible guest outputs; relocation of the distributed executable MUST NOT lose its guest artifacts. Applicable linked-runtime license notices MUST accompany distribution.

#### Scenario: A01 - source and release artifact completeness
- Given a clean source checkout with the documented build prerequisites or an unpacked release
- When the source preparation/build is repeated in independent build directories and the release executable is relocated without the source tree
- Then both Linux variants have matching source/protocol identity, deterministic per-variant hashes, no dynamic loader or shared-library dependency, and the relocated CLI retains both verified artifacts without guest package installation or runtime downloads

#### Scenario: A02 - platform selection and tampering
- Given arm64 or amd64 guests, an unsupported guest platform, or an altered/truncated artifact
- When the product provisions and handshakes the relay
- Then supported guests receive their own variant, invalid/unsupported artifacts fail before credential delivery, read-back/handshake verifies the installed bytes and protocol, and no host-architecture substitution or translator installation occurs

### Requirement: Verification isolates supervised installation state

Credential-service smoke verification of a development build MUST use a unique temporary LaunchAgent identity and private state paths without replacing or booting out the user's production job, modifying its plist/registry, or permanently pointing it at a development executable. Success and failure paths MUST remove their temporary job, relay processes, endpoints, registrations, and exclusively created container resources. Tests MUST NOT authenticate with real providers or start user containers without separate authorization.

#### Scenario: V01 - temporary LaunchAgent smoke cleanup
- Given a development build and a pre-existing user installation, with authorized throwaway runtime resources and a synthetic provider
- When isolated smoke succeeds, fails midway, or receives a handled termination signal
- Then temporary supervision demonstrates CLI-exit survival and crash recovery, production installation/state remains unchanged, and cleanup bootouts only the unique test job and removes only test-owned resources
- And the smoke verifies no matching temporary job, relay, container, or endpoints remain; abrupt unhandleable termination has a documented targeted cleanup procedure
