# Partial implementation evidence

Status: **PARTIAL / not production-ready**. The latest continuation is at the end of this file. The first block delivered the native
slice; the continuation below adds concrete Swift policy/protocol, process,
provider/runtime adapters, registry and broker/native-channel integration.
The original twenty-three-task count below is historical. Service activation,
guest provisioning, command integration, seed retirement, and fake-adapter
acceptance now exist. Live smoke, Linux target execution, and the full
integration suite remain unverified. No outcome/spec change is proposed. The
latest continuation at the end is the current evidence.

## Test-first evidence

- `sh scripts/test-guest-credential-relay.sh`: behavioral red before the C source
  existed, exit 134 on the expected missing relay hello/read assertion. A prior
  CLT declaration error was fixed and is not counted as behavioral red.
- After implementation: the same command passes. Tests execute the native relay
  as a separate process, not a linked parser stub. They cover Git field/TLV
  fixtures with @/:/Unicode, successful synthetic answer, empty misses, inverted
  and fragmented responses, store no-op, erase, oversized/duplicate/control/NUL/
  invalid UTF-8/forged-ID/truncated requests, pending EOF, old-generation response
  rejection, a real 15-second timeout, private directories, regular/symlink socket
  refusal, ancestor symlink refusal, stale socket replacement and relay singleton.
- `sh Tests/GuestGitCredentialRelay/build_artifacts_tests.sh`: behavioral red
  before build/generator implementation: `static guest artifact preparation is
  absent`, exit 1. Final version passes with independent output/cache rebuilds,
  matching bytes/manifests/generated payloads, corrupted-cache rejection, a fake
  installed zig, wrong-machine/truncated/PT_INTERP/PT_DYNAMIC rejection and notices.
  An intermediate test-only Swift autoclosure compilation error was corrected;
  it is not counted as behavioral red.
- CLT build with `-Wall -Wextra -Werror` passes. AddressSanitizer +
  UndefinedBehaviorSanitizer execution of the same harness passes. `cc --analyze`
  reports no findings. `sh -n` passes for all four new shell scripts.

## Artifact evidence

Official macOS arm64 Zig 0.15.2 was downloaded only into the repository's ignored
`.build/toolchains/zig-0.15.2/` and SHA-256 verified against the approved pin.
No installed zig/global package or guest dependency was used.

| Variant | Size | SHA-256 |
|---|---:|---|
| linux/arm64 | 51208 | db4cfa073d085100c62ac368029c5fdb1994f4b19571fb05dd7bd71b21720822 |
| linux/amd64 | 45600 | e8733a1922800e3a3c7413f1710e111cab057a13c0df20d3c021e9d7ca99e5a1 |

Source SHA-256: `0a39134a1449a20169a8b29526d1b446fd383a5175ce4fe98651c114d97a6788`.
Protocol: 1; wire layout is documented in the C source and exercised by fixtures.
The verified ELF variants have no interpreter or dynamic segment. Deterministic
manifest/generated source are local ignored outputs, not checked-in binaries.

`sh scripts/build-guest-credential-relay.sh`, `swift build --product adevcontainer`
and `swift build -c release --product adevcontainer` succeed. Swift builds report
CLT missing-search-directory linker warnings; no C/Swift source warning was
reported. A read-only `git archive HEAD` baseline was built in an isolated source
directory (without executing its tests), followed by a rebuild of the working
tree. Both succeed and report the identical three CLT linker warnings. No new
warning was introduced; temporary baseline sources were removed.

## Scope and security review

- Relay payloads are bounded (64 KiB frames, 64 client slots); IDs are monotonic
  per generation, replies are correlated, deadlines are monotonic/end-to-end,
  and a disconnect never replays requests. No provider logic exists in C.
- No secret argv/environment/log/file output. Store is local discard; erase is a
  request only. No host credential operation or authentication was executed.
- Directory components use no-follow opens; final directory is owned/0700;
  socket and peer UID are validated. A private lock prevents competing relays.
  Cleanup checks bound socket inode/device and does not unlink unrelated files.
- No launchd job, runtime container, provider or installed CLI was touched.
  No experimental relay remains after the successful tests. Wiki files retain
  their exact approved baseline hashes.

## Original native-block continuation (superseded by the progress below)

1. Finish 1.4 package-completeness coverage with phase 6 packaging tests. Linux
   x86-64 bootstrap/harness execution and arm64 guest execution are unverified.
2. Implement phases 2–5 in order, test-first: host policy/codec/artifact access,
   process-group lifetime/provider/runtime adapters, registry/broker/LaunchAgent/
   private IPC/provisioning, internal dispatch, all lifecycle call sites and
   migration. **No existing seeded credential behavior has been replaced yet.**
3. The generated constants currently compile but have no artifact accessor;
   optimized binaries may dead-strip them. Embedded retention/selection/hash/
   read-back/hello and relocated-release completeness are not established.
4. Implement phase 6 CI/release packaging/Homebrew/docs and isolated smoke
   harness. Product/source build documentation must be integrated there; native
   development instructions are in `Tests/GuestGitCredentialRelay/README.md`.
5. The Swift focused credential aggregate does not exist yet (task 2.2). Neither
   it nor the full real-runtime-capable suite was run. Real smoke and real
   authentication remain outside this handoff's authorization.

No claim is made that C01–C19/L01–L03/A01/A02/V01 pass at product boundaries.

## Swift continuation: phases 2–3 and phase 4 core

### Implemented and locally exercised

- `GitCredentialProtocol.swift`: bounded binary encoder/stream decoder matching
  the C header/TLV fixtures, safe typed failures, fragmentation, duplicate/conflict,
  injection and truncation rejection. No public CLI flags.
- `GitCredentialBrokerPolicy.swift`: exact discovered scheme/hostname/effective
  port authorization, sibling paths, Azure path requirement, queried username
  response compatibility without provider account selection; keyed in-memory
  delivery fingerprints, finite rejection cooldown/reset, generation/request
  fencing and bounded fair admission. Canceled active work retains its capacity
  until its worker exits, preventing unbounded replacement jobs.
- `GuestGitCredentialArtifacts.swift`: generated embedded payload selection by
  explicit guest platform, digest/ELF verification and read-back checks. No host
  architecture fallback. Relocated release retention remains unverified.
- `CredentialDuplexProcess.swift`: atomically creates a process group with
  `posix_spawn`, exact environment, bounded write queue, nonblocking duplex pipes,
  stderr discard (never tee), deadline/group cancellation and leader reaping.
  Tests verify a synthetic sleeping descendant is no longer running.
- `CredentialProviderProcessRunner.swift`, `HostGitCredential.swift` and
  `GitURLKind.swift`: the **existing production host provider now defaults to
  the bounded runner**; explicit override precedence, nil/gh fallthrough, actual
  HTTP(S) scheme/port/path, disabled Git/GCM/gh prompts and no propagated explicit
  token/tracing environment. No OAuth implementation or new provider.
- Dedicated optional credential-only runtime context/exec/duplex ports in
  `AppleContainerRuntime.swift`: running/managed identity, real creationDate,
  guest platform and connection user are required. Existing ContainerInfo and
  general buffered/TTY exec contracts stay unchanged. Fake buffered runners
  cannot accidentally select real duplex/container execution.
- `GitCredentialBrokerRegistry.swift`: bounded, nonsecret, owner-private atomic
  registry with no-follow component/file validation, permissions/link checks,
  same-directory rename/fsync and strict registration validation. Override
  values/rejection state are never serialized.
- `GitCredentialBroker.swift` and `GitCredentialRelayChannel.swift`: policy,
  provider/runtime/transport ports, request correlation, ephemeral override
  restart fence, immutable-context revalidation, bounded-backoff reconciliation,
  generation fencing, fair workers, native hello validation and secret-safe
  channel lifetime. A real native macOS relay/client is integrated with the Swift
  broker/policy/codec through synthetic ports, including sibling path lookup.

### Red/green and registration evidence

All new groups are registered in `Tests/adevcontainerTests/main.swift`; both
default registration and the test-only focused selection are retained. The
focused selection includes four existing fake host-provider regression cases.

| Check | Behavioral red | Green |
|---|---|---|
| Phase 2 focused group | 0 passed / 6 failed | 6 / 0 |
| Duplex process additions | 6 / 3 | 9 / 0 |
| Provider additions | 9 / 3 | 12 / 0 |
| Runtime context additions | 12 / 2 | 14 / 0 |
| Registry additions | 15 / 1 | 16 / 0 |
| Broker additions | 16 / 1 | 17 / 0 |
| Real native channel addition | 17 / 1 | 18 / 0 |
| Obsolete channel forging new generation | reply ID 999 instead of 2 | fixed; regression passes |

Compile/harness errors encountered while introducing groups are not counted as
behavioral red. Final focused command:

```sh
ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests
```

Final aggregate: **24 passed, 0 failed, 0 skipped** (synthetic/local only).
`swift build --product adevcontainer` also succeeds. Only the previously confirmed
CLT linker search-path warnings are emitted; no introduced source diagnostics.
No large native/release rebuild was repeated for this continuation.

### Concrete remaining dependency

The next implementation dependency is **task 4.4**, not a real-provider smoke:
implement/test the injected per-user LaunchAgent adapter, singleton lock, private
same-UID host control IPC, executable repair and internal entry dispatch (4.7/4.8).
The broker is currently driven by its library/test ports; **there is no activated
production daemon or automatically scheduled reconciliation loop yet**.

Then implement 4.5/4.6: guest artifact provisioning/read-back/ready-socket checks,
helper migration and discovery/registration. Only afterwards move lifecycle and
clone call sites in phase 5 and retire `GuestGitCredentialSeed`. Its existing
guest-persistence behavior has **not** been replaced by this continuation.

Phase 6 remains entirely pending: release retention/relocation tests, packaging,
CI, Homebrew, product docs and isolated smoke harness/authorized execution. Task
1.4 package completeness and 2.6 relocation coverage remain partial. Tasks 4.1
and 4.3 remain unchecked because their full service/concurrency/cancellation
acceptance is not demonstrated, despite the implemented and tested core.

No C/build-script change was made while the parallel phase-1 security review was
in progress. No LaunchAgent, existing container, authentication, token store,
installed CLI or wiki was changed. No final product/scenario conformance claim
is made; this record is implementation evidence, not a DONE certificate.

## Earlier resume inventory (superseded by the continuation below)

Both mandatory phase-1 fixes are present: bounded stdout backpressure handling
without changing caller flags, and a fresh private extraction from the verified
Zig archive for every invocation. Native tests include backpressure/saturation;
artifact tests include executable and auxiliary-tree tampering. Service/IPC,
internal entry and initial provisioning files also exist, but normal lifecycle
call sites still use legacy seeding. Earlier notes above are historical.

Current priority is provider lifetime after broker crash, shared-HOME endpoint
isolation and serialized provisioning, followed by lifecycle/clone integration
and distribution. No real job/container/authentication is authorized. Checkboxes
remain acceptance evidence, not a count of files that exist.

Provider-crash hardening: a synthetic subprocess regression reproduced a live
provider/sleeping descendant after its broker received SIGKILL. A same-executable
internal guardian now owns the provider's process group, watches a dedicated
parent-liveness pipe and kills the whole group on parent EOF/deadline/completion.
A separate byte-only status pipe preserves the provider exit status without
mixing metadata into credential stdout. The actual provider inherits that group;
it never inherits the guardian's liveness/status descriptors. Guarded runtime
relay processes use the same parent-death protection. No new installed binary,
credential argv/env, provider, public flag or real service was introduced.

## Current continuation: lifecycle regression and bounded setup

Status remains **PARTIAL / not production-ready**, not DONE. Actual source now
contains per-user LaunchAgent activation/repair, singleton and provisioning locks,
private same-UID framed control IPC, the hidden internal entry, verified guest
provisioning/migration, and lifecycle setup/teardown including clone. The obsolete
one-shot clone credential acquisition/ASKPASS/approve/store path was removed;
shared setup precedes the full clone or reused-tree hooks. These are implementation
facts, not proof that every phase-4/5 scenario is covered.

This continuation replaced the obsolete up/start/refresh command assertions with
the injectable automatic connection boundary. The formerly crashing fresh-up
assertion now verifies ownership → setup → create-hook order and source forwarding,
not a fabricated token seed. Running reuse, soft failure versus explicit refresh
hard failure, stopped refusal, volume source selection and redaction remain tested.
The focused aggregate now includes these updated deterministic command cases.

A new single-budget test first failed with `invalid runtime identity` after a slow
synthetic context operation instead of stopping at the expired budget (49 passed,
1 failed; `.build/credential-budget-red.log`). The implementation now propagates
one monotonic setup deadline through discovery's bounded host runner, runtime
inspect/exec, provisioning/read-back/ready checks, control activation, lock waits,
launchctl subprocesses and IPC transfer/connect. Unregister uses a separate bounded
two-second cleanup budget. The mock adapter also checks expiry after returning,
so tests cannot hide a multiplied budget. Budget green: **50/0/0**.

Help regression first failed on the missing rejection-reset/on-demand semantics
(`.build/credential-help-red.log`, 49/1/0). Up/start/clone/refresh help now describes
automatic repair versus explicit validation/reset, HTTP(S), host login and no guest
token stores; it no longer promises the superseded seed route or OAuth renewal.

Additional sandbox migration coverage executes the production installation shell
against an isolated Git config, adapting only Linux stat formatting to macOS. No
credential lookup/provider is called. It verifies repeated migration's helper order,
Azure exactly-once insertion/empty-reset removal/useHttpPath, untouched unregistered
HTTP scope, explicit legacy-HTTP migration, deletion of the private old product
store, and byte-preservation of the unmarked user clone store. This is additional
verification of existing code, not invented pre-implementation red evidence.

### Latest locally executed commands

- `swift build --product adevcontainer`: succeeds; only independently confirmed
  baseline CLT linker-search-path warnings, no new source diagnostic.
- `ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests`: **51 passed,
  0 failed, 0 skipped** (`.build/credential-migration-tests.log`). No real runtime,
  LaunchAgent or host credential provider selected.
- `sh scripts/test-guest-credential-relay.sh`: passes, including stdout
  backpressure/saturation (`.build/credential-resume-native.log`).
- `sh Tests/GuestGitCredentialRelay/build_artifacts_tests.sh`: passes pinned
  archive/fresh extraction, executable and auxiliary-tree tampering, deterministic
  static target/ELF/generated identity/notices (`.build/credential-resume-artifacts.log`).
- `swift build -c release --product adevcontainer`: succeeds
  (`.build/credential-resume-release.log`).
- `sh Tests/GuestGitCredentialRelay/build_artifacts_tests.sh --package .build/release/adevcontainer`:
  passes notice/archive/relocated embedded-target verification
  (`.build/credential-resume-package.log`). This hidden verifier has no service,
  runtime or provider side effects.

### Remaining dependencies (not a DONE certificate)

Retire the old seed API and its superseded AllUnitTests group while retaining
discovery/compatibility coverage; extend remaining clone/rebuild/failure-cleanup
and service/concurrency tests; inspect full scenario conformance and registration.
The full suite is deliberately **not executed**: runtime integration effects lack
authorization. Its remaining obsolete seed assertions must not be hidden by focused
selection. Isolated smoke harness/tests/documentation (6.8–6.10) are still absent;
live launchd/arm64 smoke and actual Linux target execution remain unverified and
must not be marked passed. Neither user authentication nor real-resource mutation
is authorized. CodeGraph CLI was unavailable on this host, so targeted file reads
were used after the attempted indexed lookup. Wiki files were not edited.

### Additional regressions in this continuation

- Simultaneous activation: eight concurrent isolated service activations with a
  thread-safe fake launchctl produce exactly one bootstrap and zero failures.
- Helper-path escaping: migration with a home containing spaces/single quotes
  first failed the expected helper-command assertion
  (`.build/credential-helper-path-red.log`, 51/1/0). Product helper values now
  shell-quote non-simple absolute paths, retaining raw simple paths. Azure removes
  duplicate old/new product values while retaining user helper order. A fixture
  helper invoked by isolated Git proves the quoted command works; this uses only
  synthetic values, a private config and a fixture executable, not host providers.
- Clone failure ordering: a new assertion reproduced `setup → runtime.delete →
  unregister` instead of fencing before deletion
  (`.build/credential-clone-cleanup-red.log`, 55/1/0). Clone now unregisters once
  before deletion after populate/reuse/overlay failures, retaining deferred cleanup
  for later failures and existing volume-retention rules. Legacy HTTP forwarding,
  populated reuse before hooks, SSH unchanged, public success, private failure and
  single full-clone mechanism are included in focused tests. Combined green:
  **57/0/0**, `.build/credential-cleanup-green.log`.
- Hook behavior: two new regressions reproduced enabled authentication prompts
  and delete-before-unregister for failed create hooks
  (`.build/credential-hooks-red.log`, 57/2/0). Lifecycle hook exec now overrides
  terminal/GCM/ASKPASS interaction settings with noninteractive values and
  unregisters before its create-path deletion. Final verification is recorded below
  after rebuilding; no success is inferred from compilation alone.

Shell syntax, rendered Homebrew Ruby syntax and both workflow YAML syntax checks
pass. `git diff --check` passes. The three preserved wiki SHA-256 values still
exactly match the supplied baseline. Full suite/real smoke restrictions above
remain unchanged; task checkmarks distinguish implemented local distribution from
unexecuted GitHub Actions/Homebrew/target smoke.

Final verification after all edits above: `swift build --product adevcontainer`,
the focused aggregate (**59 passed, 0 failed, 0 skipped**),
`swift build -c release --product adevcontainer`, and release-package relocation
all pass. Logs: `.build/credential-hooks-build.log`,
`.build/credential-hooks-green.log`, `.build/credential-hooks-release.log`,
`.build/credential-hooks-package.log`. Only the known baseline CLT missing-search-
directory linker warnings remain; no new source warning/error is reported.
The intermediate `.build/credential-final-*` attempt overlapped introduction of
the intentionally red hook regressions and failed; it is not claimed as green.
Final `git diff --check` and the preserved wiki hashes pass, and generated assets
remain ignored/unstaged. No commits, installed executable replacement, production
LaunchAgent, existing runtime/container mutation or real authentication occurred.

Next concrete implementation dependency remains 5.12/5.14: replace the legacy
`guestGitCredentialSeedTests` block (AllUnitTests.swift, preserving the following
compatibilityContractTests), retain discovery tests/helpers still used by commands,
then remove the unused seed/install/store implementation. This is unfinished
implementation, not a request for runtime authorization. Separately complete
phase-4/5 scenario coverage and isolated smoke harness/docs before any production
readiness claim. Live smoke execution remains separately unauthorized.

## Current continuation: seed retirement and fake acceptance

Status remains **PARTIAL / not production-ready**. `GuestGitCredentialSeed.swift`
is removed. Discovery lives in `GitCredentialDiscovery`; `compatibilityContractTests`
remains. No lifecycle command writes a guest token store, `credential approve`,
or `ADEV_CLONE_PASS`. The install script deletes only the product-owned
`$HOME/.adevcontainer/git-credentials` file and does not read it. Rebuild, start,
clone, and purge tests now assert the injected connection boundary instead of a
seed exec. A same-named incarnation does not inherit an explicit override.

Isolated smoke harness tests pass with a fake launchctl and a fixture helper for
`credential-smoke.invalid`. `ADEVCONTAINER_CREDENTIAL_SMOKE=1` exits before any
job bootstrap unless a separate authorization variable is also set, and even then
this process does not execute live smoke. `Tests/GuestGitCredentialRelay/SMOKE.md`
documents the operator procedure. Task 6.11 was not run.

### Local checks this continuation

- `ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests`: **78 passed, 0 failed, 0 skipped**.
- `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1 swift run adevcontainerTests`: **1173 passed, 0 failed, 0 skipped**. The runner printed `Excluded 18 live integration tests`. Those 18 were not executed.
- `swift build --product adevcontainer`: succeeds. Only the previously known CLT missing-search-directory linker warnings. No new source diagnostic.
- `git diff --check`: passes. Wiki files were not edited.

Not run, and not claimed: native harness, artifact/package relocation, release build, `swift run adevcontainerTests` without the synthetic exclusion, Linux amd64 execution, GitHub Actions, Homebrew install, real LaunchAgent, plantsuite, keychain, or provider authentication. Phase 1 and the release/live-smoke checkpoints stay unchecked for that reason.
