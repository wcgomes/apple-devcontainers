# Tasks: automatic-git-credentials

Archive note (2026-10-21): moved to `specs/changes/archive/20261021-automatic-git-credentials/`. Isolated smoke, Linux target execution, and the complete restart matrix were not executed. The user authorized archive with those limits as non-blocking. Do not read unchecked boxes below as passed.

## Execution rules and dependencies
Spec ref: `specs/changes/archive/20261021-automatic-git-credentials/` (archived; live contract is `specs/core.md` and `specs/clone.md`). Both approval questions in proposal.md are resolved. This is the implementation handoff; no item below has been executed during spec preparation. Follow phases in order; only marked [P] items may run independently within a phase. Every product behavior change starts with its named tests and a recorded red result before implementation; toolchain/download/harness errors do not count as behavioral failures. Minimal compile scaffolding may make an absent API testable, but must not substitute a passing stub for a test. Register each newly written Swift test group in the same phase before attempting red/green verification.

Use the documented asset-preparation step before Swift builds. The suite of record remains `swift run adevcontainerTests`; add a test-runner-only focused credential aggregate invoked with `ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests` so deterministic verification cannot accidentally run existing real-container integration cases. The focused aggregate uses fake providers/runtime/launchd and never touches the user's real job. Run the full existing suite only with its runtime side effects separately authorized, or when live integration prerequisites are absent; never stop the user's runtime just to suppress integration. Smoke uses the separate test-only `ADEVCONTAINER_CREDENTIAL_SMOKE=1` opt-in and additionally requires authorization for throwaway resources. No real GCM authentication, token-cache modification, plantsuite start, or user-container mutation is included in automatic checks.

## 1. Native guest component and reproducible assets
- [x] 1.1 Write native framing/parser, Git input round-trip (@/:/Unicode), request bounds, socket ownership/symlink, EOF, timeout, concurrent out-of-order reply, get/erase, and store-no-op tests using synthetic credentials; record the expected absent/incorrect relay failure before 1.3 (path: Tests/GuestGitCredentialRelay/relay_tests.c).
- [x] 1.2 Add the native test harness runner using macOS CLT for host tests and the pinned Zig path on Linux; support executing the shipped static amd64 output rather than only linking its parser into a test executable (path: scripts/test-guest-credential-relay.sh).
- [x] 1.3 Implement the small bounded C relay/client, versioned binary framing, user-private socket, per-request IDs/generation, no-follow cleanup, no log/persistent secrets, and no implicit interpreter/package dependency; make 1.1 green (path: Guest/GitCredentialRelay/main.c).
- [x] 1.4 Write build/provisioning tests for bad toolchain checksums, no implicit installed zig requirement, ELF wrong machine/truncation/interpreter/dependencies, two clean-directory rebuilds, generated payload/manifest identity, and package/notice completeness; record red before 1.5-1.8 and 6.3 (path: Tests/GuestGitCredentialRelay/build_artifacts_tests.sh).
- [x] 1.5 Implement checksum-pinned Zig 0.15.2 bootstrap for macOS arm64 source/release and Linux x86-64 build-only CI using the URLs/hashes in design.md, verified cached archives, safe extraction, and repository-local build caches (path: scripts/bootstrap-guest-toolchain.sh).
- [x] 1.6 Implement the host Swift ELF verifier/manifest/base64-source generator using Foundation/CryptoKit; include source/toolchain/protocol identity and deterministic output, fail on invalid metadata, and avoid runtime/executable downloads (path: scripts/prepare-guest-credential-assets.swift).
- [x] 1.7 Implement static C builds for aarch64-linux-musl and x86_64-linux-musl with fixed flags, isolated output/cache roots for reproducibility tests, and an internal raw-only build-script mode for Linux CI; default macOS preparation emits the generated Swift asset file described in design.md (path: scripts/build-guest-credential-relay.sh).
- [x] 1.8 Add the applicable musl/compiler-runtime license/copyright notices from the pinned toolchain, checked by the artifact/package test (path: THIRD_PARTY_NOTICES.md).
- [x] 1.9 Ignore only the generated Swift asset source; raw binaries/toolchain/generated manifests already belong below the ignored build directory (path: .gitignore).

## Checkpoint: native delivery
Implementation evidence and remaining boundaries: [implementation.md](implementation.md). Task 1.4 now includes passing release-package/relocation completeness checks as well as toolchain/reproducibility/ELF/payload/notices. No Linux executable has been run on this macOS host. Checkmarks above cover implementation plus local verification, not cross-platform CI or the final A01/A02 outcome.
- [ ] Run native harness and artifact build tests; retain red/green evidence. A01 must show both deterministic static ELF variants, correct hashes/protocol identities, no loader/dependencies, and no reliance on installed zig or guest packages. Wrong/corrupt binaries must fail verification for A02. Linux-target execution is still pending phase 6 and is not inferred from a macOS/ELF-only result.

## 2. Pure policy, protocol, and embedded artifact selection
Depends on phase 1 generated assets. Protocol/policy tests are independent of launchd/runtime/provider execution.
- [x] 2.1 Write deterministic destination authorization, scheme/port binding, sibling/username compatibility, no guest account override, finite rejection cooldown, late erase/new credential, explicit reset, bounded fairness, and generation tests for C05/C08/C09/C10/C14/C19; record red before 2.3 (path: Tests/adevcontainerTests/GitCredentialBrokerPolicyTests.swift).
- [x] 2.2 Register this phase's written tests and add the test-only focused credential aggregate without changing default production CLI behavior or adding public flags; extend registration as later phases add groups (path: Tests/adevcontainerTests/main.swift).
- [x] 2.3 Implement policy with injected monotonic time, bounded recent-delivery fingerprints keyed in memory, no provider store/reject, fair admission and generation fencing; make 2.1 green (path: Sources/ADevContainerLib/Git/GitCredentialBrokerPolicy.swift).
- [x] 2.4 Write host codec tests matching native frame fixtures, fragmented/oversized/truncated messages, duplicate/conflicting fields, newline/NUL injection and out-of-order IDs; record red before 2.5 (path: Tests/adevcontainerTests/GitCredentialProtocolTests.swift).
- [x] 2.5 Implement the bounded binary codec and typed safe outcomes, sharing protocol identity with generated assets and matching native wire fixtures; make 2.4 green (path: Sources/ADevContainerLib/Git/GitCredentialProtocol.swift).
- [x] 2.6 Write embedded bytes/hash/ELF/protocol selection tests for arm64, amd64, unsupported guest platform, corrupted payload, relocatable release use, and read-back mismatch; record red before 2.7 (path: Tests/adevcontainerTests/GuestGitCredentialArtifactTests.swift).
- [x] 2.7 Implement verified embedded artifact access and actual-guest-platform selection, not host-architecture fallback; generated source is an output, not a hand-edited second source of truth (path: Sources/ADevContainerLib/Git/GuestGitCredentialArtifacts.swift).

## Checkpoint: pure behavior
- [x] Run the focused aggregate after asset preparation; C05/C08/C09/C10/C14/C19/A02 pass without launchctl, container execution, secrets, sleeps, or real providers. Native/Swift framing fixtures agree. Confirm all newly written tests are registered and actually executed, not just compiled.

## 3. Runtime duplex and bounded noninteractive host acquisition
- [x] 3.1 Write process tests for duplex fragmentation/EOF, inverted replies, stderr drainage without tee, bounded queues, hung child plus descendant cancellation/reaping, safe errors and no secret argv/environment; record red before 3.2 (path: Tests/adevcontainerTests/CredentialDuplexProcessTests.swift).
- [x] 3.2 Implement duplex child lifetime, nonblocking pipe drainage and cancellation with process-group ownership established at spawn; do not redesign unrelated buffered/TTY execution (path: Sources/ADevContainerLib/Runtime/CredentialDuplexProcess.swift).
- [x] 3.3 Write machine-JSON credential-context and exec-argv tests for incarnation creationDate, managed identity, actual guest platform, missing/invalid metadata, resolved user, no TTY, and stdin transfer/read-back; record red before 3.4 (path: Tests/adevcontainerTests/GitCredentialRuntimeTests.swift).
- [x] 3.4 Add the dedicated credential duplex/context adapter, using optional credential-only metadata parsing and existing runtime boundaries; ensure the current buffered exec/other commands retain their contracts (path: Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift).
- [x] 3.5 Write provider tests for existing precedence, actual Azure path/no pathless GCM, scheme/port, disabled Git/GCM GUI/TTY prompts, nil versus safe failure, bounded hangs, and no approve/reject/store; record red before 3.6-3.8 (path: Tests/adevcontainerTests/AutomaticHostGitCredentialTests.swift).
- [x] 3.6 Implement the deadline-aware provider process adapter with safe structured failure, bounded output, process-group cancellation and no leaked secrets; use the lifetime primitives from 3.2 rather than duplicate them (path: Sources/ADevContainerLib/Runtime/CredentialProviderProcessRunner.swift).
- [x] 3.7 Reuse shared host acquisition with deadline/cancellation and provider-interaction suppression; keep explicit token precedence without propagating it to children and retain nil fallthrough, no OAuth implementation (path: Sources/ADevContainerLib/Git/HostGitCredential.swift).
- [x] 3.8 Preserve actual HTTP(S) scheme/nondefault port in credential fields, keeping normalized hostname separate from Git's host-with-port to retain Azure recognition; forbid field/control injection and retain SSH classification while applying broker authorization separately (path: Sources/ADevContainerLib/Git/GitURLKind.swift).

## Checkpoint: adapters
- [x] Focused tests prove C04/C05/C07/C10/C11/C14/C15/C19/A02, including cancellation of a synthetic hung provider/descendant. No raw stderr or credential payload is teed. Malformed/missing creationDate/platform fails closed only for unattended credential recovery; no guessed host-platform fallback is accepted.

## 4. Supervision, registry, recovery, and guest migration
- [x] 4.1 Write tests with fake launchctl/process/clock/control peers for simultaneous bootstrap, singleton lock, immutable identity revalidation, private host IPC, corrupt/unsafe registry, ephemeral override restart, no token polling, fair requests, reconnect/backoff and teardown; record red before 4.2-4.4 (path: Tests/adevcontainerTests/GitCredentialBrokerServiceTests.swift).
- [x] 4.2 Implement the nonsecret, atomic owner-private registry and safe paths; retain override-required metadata but no token/rejection values; make registry cases in 4.1 green (path: Sources/ADevContainerLib/Git/GitCredentialBrokerRegistry.swift).
- [x] 4.3 Implement broker orchestration over policy/provider/runtime ports, request correlation, bounded acquisition, ephemeral overrides, identity reconciliation, generation fences, no replay and bounded-backoff reconnection (path: Sources/ADevContainerLib/Git/GitCredentialBroker.swift).
- [x] 4.4 Implement the per-user LaunchAgent adapter/control IPC/singleton lock, installed-executable path repair and supervisor restart policy; dependency-inject job label/state/executable/launchctl for tests, never expose the control socket to guests (path: Sources/ADevContainerLib/Git/GitCredentialBrokerService.swift).
- [x] 4.5 Write provisioning/migration tests for connection-user ownership, asset read-back/hello, Azure exactly-once helper/useHttpPath/empty-reset removal at HTTPS scope and at HTTP scope only for registered legacy HTTP, preserved helper order, old product-store removal, untouched unmarked legacy clone stores, no secret seed fallback, skip/soft errors, and healthy reuse; record red before 4.6 (path: Tests/adevcontainerTests/GitCredentialConnectionTests.swift).
- [x] 4.6 Implement shared setup/discovery/registration/migration and bounded teardown, including session metadata and the product-owned wrapper/native binary; only product-owned seeded files may be removed and no contents logged/read for migration (path: Sources/ADevContainerLib/Git/GitCredentialConnection.swift).
- [x] 4.7 Explicitly build the CLI product and write safe subprocess internal-entry dispatch tests using invalid/isolated contexts, ensuring default CLI/help/plugin behavior stays unchanged and no test selects the production job; record red before 4.8 and rebuild after entry changes (path: Tests/adevcontainerTests/GitCredentialBrokerEntryTests.swift).
- [x] 4.8 Route the internal broker mode through the existing executable entry with secret-free arguments and injected private test context support, without public credential-service flags (path: Sources/adevcontainer/AdevcontainerMain.swift).

## Checkpoint: service policy and provisioning
- [x] C01/C02/C03/C04/C06/C08/C09/C10/C11/C12/C13/C14/C15/C16/C17/A02 pass at the connection/service boundary with fake adapters; command call-site ordering remains for phase 5. Validate lost explicit overrides do not switch source after restart, failed sessions cannot authorize a new same-named incarnation, and stale-socket cleanup cannot delete unrelated paths. Keep legacy seed APIs until phase 5 moves their callers/tests; this checkpoint does not claim that real launchd restart or Linux execution has passed.

## 5. Command integration and regression coverage
- [x] 5.1 Write command tests for all lifecycle setup/teardown ordering, setup soft errors versus explicit refresh hard error, identity replacement, running reuse, sources, missing Git/remotes/volume URL, no provider lookup on healthy reuse, stopped refresh refusal and no fetch/push/workspace writes; record red before 5.3-5.9 (path: Tests/adevcontainerTests/AutomaticGitCredentialsCommandTests.swift).
- [x] 5.2 Replace obsolete seeding command assertions with automatic connection behavior while retaining managed selection, secret redaction, lifecycle recovery and existing unrelated command coverage (path: Tests/adevcontainerTests/AllCommandTests.swift).
- [x] 5.3 Connect fresh/start-stopped/running-reuse setup at the agreed before-hook boundary with soft errors (path: Sources/ADevContainerLib/Commands/UpCommand.swift).
- [x] 5.4 Connect real-start setup before postStart and healthy/broken running reuse handling without changing attach/settings behavior (path: Sources/ADevContainerLib/Commands/StartCommand.swift).
- [x] 5.5 Use new replacement identity/registration before hooks for bind and volume rebuild, invalidating old pending requests without changing volume retention/recovery semantics (path: Sources/ADevContainerLib/Commands/RebuildCommand.swift).
- [x] 5.6 Preserve running-only selection; ensure/recover/re-register, clear session suppression and validate discovered acquisition without seeding or repository operations, returning safe structured setup failure (path: Sources/ADevContainerLib/Commands/RefreshCredentialsCommand.swift).
- [x] 5.7 Unregister/cancel sessions around stop using bounded cleanup without masking the existing primary runtime error (path: Sources/ADevContainerLib/Commands/StopCommand.swift).
- [x] 5.8 Unregister/cancel sessions around container removal without changing foreign-resource protections (path: Sources/ADevContainerLib/Commands/DeleteCommand.swift).
- [x] 5.9 Unregister/cancel the selected container's sessions while retaining shared-volume preservation and deletion rules (path: Sources/ADevContainerLib/Commands/PurgeCommand.swift).
- [x] 5.10 Write clone tests for Azure/non-Azure/legacy HTTP, helper before populate/hooks, public miss/private failure, reuse-populated setup, no new store/approve/secret env, SSH unchanged, and failed-clone session/volume cleanup; record red before 5.11 (path: Tests/adevcontainerTests/CloneInVolumeTests.swift).
- [x] 5.11 Replace the HTTPS/legacy HTTP one-shot guest seed/store route with shared automatic setup, including populate/failed-clone cleanup; retain host config-only fetch and SSH behavior, with no second full-clone mechanism (path: Sources/ADevContainerLib/Commands/CloneCommand.swift).
- [x] 5.12 Replace superseded seeded-helper expectations with automatic-helper/migration expectations, preserving input escaping, queried username, provider fallthrough, private files, and redaction regressions; remove only obsolete changed behavior (path: Tests/adevcontainerTests/AllUnitTests.swift).
- [x] 5.13 Extend the focused aggregate to all new credential groups and updated relevant legacy groups; retain normal suite registration, including clone/rebuild regressions, and register the phase 6 smoke when its test file lands. Ensure mock-runtime command tests cannot accidentally reach the production broker/launchctl and all new groups execute (path: Tests/adevcontainerTests/main.swift).
- [x] 5.14 After 5.3-5.12 move callers/tests, retire obsolete token seed/write/store helper code; retain/move only still-used discovery/compatibility logic and remove references made dead by this change (path: Sources/ADevContainerLib/Git/GuestGitCredentialSeed.swift).

## Checkpoint: command conformance
- [x] C01-C19 and L01-L03 pass through fake command/runtime/service integration, not direct policy tests alone. Confirm no new literal token files, product seed fallback, GCM-in-guest integration, public flags, or user helper resets. Full clone still verifies .git and respects reused-volume/SSH behavior. Re-run existing up/start/rebuild recovery tests under fake dependencies before authorizing a real smoke.

## 6. Distribution, documentation, isolated smoke, and final verification
- [x] 6.1 Extend the artifact/package tests from 1.4 to fail on missing embedded targets/notices, a relocated binary requiring its source/generated tree, or archive layout drift; record red before 6.3-6.5 (path: Tests/GuestGitCredentialRelay/build_artifacts_tests.sh).
- [x] 6.2 Run preparation/native tests before the existing macOS test/build job, and add a Linux x86-64 native-only job using the pinned compiler/raw artifacts to exercise the actual static amd64 binary; Linux does not build the macOS CLI or require Apple container (path: .github/workflows/ci.yml).
- [x] 6.3 Implement repeatable release packaging of the single embedded host binary and applicable notices with COPYFILE_DISABLE, preserving tarball naming/checksum behavior; assert artifact completeness rather than downloading anything during packaging (path: scripts/package-release.sh).
- [x] 6.4 Prepare/verify native assets before tests and release Swift build, use the tested packaging script, and preserve tag/version/Homebrew publishing behavior (path: .github/workflows/release.yml).
- [x] 6.5 Keep installing the single CLI and install accompanying notices as documentation; no separately installed guest executable or sudo step (path: scripts/render-homebrew-formula.sh).
- [x] 6.6 Document source preparation/toolchain checksum/cache/network prerequisites, production automatic LaunchAgent behavior, HTTP/sibling/Azure scope, earlier-helper limitations, refresh semantics and host-login guidance without claiming OAuth renewal (path: README.md).
- [x] 6.7 Document native red/green commands, generated-source handling, supported guest architectures, reproducibility/ELF checks and the safe focused test command; distinguish full suite runtime authorization from fake tests (path: CONTRIBUTING.md).

Distribution checkmarks record local implementation, syntax validation and passing
release-package relocation checks; they do not claim execution of GitHub Actions,
Homebrew installation, Linux target execution or live arm64/launchd smoke. Those
remain explicitly unchecked below. Phase-4/5 fake-adapter acceptance is locally
verified; it does not include real launchd, a guest container, or Linux execution.
- [x] 6.8 Write isolated smoke harness tests first: unique job/context, production hashes untouched, synthetic provider, cleanup on success/failure/handled signals, and targeted cleanup manifest for unhandleable termination; record red before enabling live smoke (path: Tests/adevcontainerTests/GitCredentialBrokerSmokeTests.swift).
- [x] 6.9 Implement the opt-in smoke harness around the tested library adapters/internal executable mode; use a unique temporary launchd label/state/socket root and exclusively created containers, with an isolated host Git config/local fixture helper for credential-smoke.invalid and sanitized provider environment. Exclude user config/credential stores/explicit tokens/traces and real network authentication; never use the production job or an existing user container (path: Tests/adevcontainerTests/GitCredentialBrokerSmokeHarness.swift).
- [x] 6.10 Document the real-smoke authorization prerequisites, approved temporary root, synthetic credential-only assertions, unique job/resource manifest, and exact targeted cleanup/absence checks, including SIGKILL recovery and unchanged production-job baseline; no broad launchctl/container cleanup commands (path: Tests/GuestGitCredentialRelay/SMOKE.md).
- [ ] 6.11 After authorization and prerequisite checks, execute the opt-in smoke on an exclusively created arm64 guest with an approved Git-containing image (no package installation), testing native get/erase, CLI-exit survival, real launchd crash restart, stale socket repair, pending cancellation and out-of-order concurrency; inject a failure to verify cleanup and record the production baseline after both runs (path: Tests/adevcontainerTests/GitCredentialBrokerSmokeTests.swift).

## Checkpoint: release and safety
- [ ] A01/A02/V01 and C07/C10-C16 pass with real supervised synthetic-provider smoke and the shipped arm64 relay; Linux CI separately executes the shipped amd64 relay. Missing runtime/image/permission is an explicitly blocked smoke, not a passing/skipped claim of target execution.
- [ ] Run asset build/native tests, the focused credential aggregate, release build/package relocation checks, and (when separately authorized or no real-runtime prerequisites exist) `swift run adevcontainerTests`. Fix warnings/lint findings introduced by the change; suppressing them is not a fix. Confirm generated binaries/Swift source are not staged and no unrelated files/wiki changes were made.
- [ ] Review scenario-to-test conformance against the persisted spec, inspect secret-flow/IPC/generation/cancellation and supervision failure paths, and report actual evidence versus untested scope. Real provider authentication/OAuth renewal remains out of this automatic smoke. Do not archive without separate confirmation.

## Scenario-to-task coverage

Every scenario below maps to tests and implementation; phase checkpoints exercise the group. Repeated test registration is mandatory through 2.2/5.13. All rows are planned coverage, not a claim of passing product tests.

| Scenario | Test-first tasks | Implementation / verification tasks |
|---|---|---|
| C01 create/rebuild before hooks | 4.5, 5.1, 5.2 | 4.6, 5.3, 5.5 |
| C02 start/reuse | 4.5, 5.1 | 4.3, 4.6, 5.3, 5.4 |
| C03 skips/soft failures | 3.5, 4.5, 5.1 | 3.7, 4.6, 5.3-5.5 |
| C04 Azure helper/path | 3.5, 4.5, 5.10 | 3.7, 3.8, 4.6, 5.11 |
| C05 scope/username | 2.1, 3.5 | 2.3, 3.7, 3.8, 4.3 |
| C06 earlier-helper order | 4.5, 5.12 | 4.6, 5.14, 6.6 |
| C07 fresh lookup/noninteractive | 3.1, 3.5, 5.10 | 3.2, 3.6, 3.7, 4.3, 5.11, 6.11 |
| C08 store/correlated erase | 1.1, 2.1 | 1.3, 2.3, 4.3 |
| C09 finite rejection/reset | 2.1, 5.1 | 2.3, 4.3, 5.6 |
| C10 hostile messages/isolation | 1.1, 2.1, 2.4, 4.1 | 1.3, 2.3, 2.5, 4.3, 4.4, 6.11 |
| C11 secrets/private endpoints | 1.1, 3.1, 4.1, 4.5 | 1.3, 3.2, 3.6, 4.2, 4.4, 4.6 |
| C12 ephemeral override restart | 3.5, 4.1 | 3.7, 4.2, 4.3 |
| C13 supervised singleton | 4.1, 4.7, 6.8 | 4.4, 4.8, 6.9, 6.11 |
| C14 correlation/overload | 1.1, 2.1, 2.4, 3.1, 4.1 | 1.3, 2.3, 2.5, 3.2, 4.3, 6.11 |
| C15 recovery/fence | 1.1, 3.1, 3.3, 4.1, 6.8 | 1.3, 3.2, 3.4, 4.3, 4.6, 6.11 |
| C16 stop/remove/reconcile | 4.1, 5.1, 5.10, 6.8 | 4.3, 4.6, 5.7-5.9, 5.11, 6.11 |
| C17 safe migration | 4.5, 5.12 | 4.6, 5.14, 5.3, 5.4, 5.6 |
| C18 refresh running/stopped | 5.1, 5.2 | 4.6, 5.6 |
| C19 legacy HTTP binding | 2.1, 3.5, 5.10 | 2.3, 3.7, 3.8, 4.6, 5.11 |
| L01 one HTTP(S) clone mechanism | 5.10 | 4.6, 5.11 |
| L02 fallback/reuse/cleanup | 5.10 | 4.3, 4.6, 5.11 |
| L03 SSH unaffected | 5.10 | 5.11 |
| A01 pinned reproducible distribution | 1.4, 2.6, 6.1 | 1.5-1.9, 2.7, 6.2-6.7 |
| A02 guest variant/integrity | 1.4, 2.6, 3.3, 4.5 | 1.6, 1.7, 2.7, 3.4, 4.6, 6.2, 6.11 |
| V01 isolated smoke cleanup | 4.1, 6.8 | 4.4, 6.9-6.11 |

## Analyze: PASS

- User approvals: bundled static Linux delivery/build footprint and preserved legacy HTTP are recorded in proposal.md; zero unresolved clarification markers remain.
- Live-contract routing: core's complete seeded-store requirement/scenarios are explicitly replaced; clone's HTTP-inclusive HTTPS row/shared paragraph and three named credential scenarios are replaced, preserving other populate, SSH, verification, author identity and cleanup contracts. No other active deltas were present at baseline.
- Normative coverage: both modified requirements and both added requirements have testable scenarios; all 25 scenarios map above to test-first tasks, implementation paths and phase checkpoints. Design guarantees are represented in the spec rather than introduced only as rationale.
- Executability: toolchain is not assumed installed; official fixed archive/checksums, two guest targets, source preparation, generated output, integrity checks, single-binary packaging and target execution paths are specified. Source build/CI preparation precedes Swift tests; pure tests precede adapters, service and commands; production supervision is never used as a development test fixture.
- Scope: no product implementation, artifact build/download, authentication, runtime start, wiki edit, realized-spec edit, archive or test execution occurred during this planning phase. PASS is a documentation/readiness result, not production certification or approval to mutate user installation state.
- Preservation: the three wiki modifications and baseline commit recorded in proposal.md remain unchanged; only this active change directory is edited. Implementation handoffs must retain the Spec ref and obtain runtime/auth authorization before effects beyond fake tests.
