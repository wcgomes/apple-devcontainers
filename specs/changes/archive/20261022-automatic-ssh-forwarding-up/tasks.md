# Tasks: automatic-ssh-forwarding-up

Spec ref: `specs/changes/archive/20261022-automatic-ssh-forwarding-up/` ([delta](spec.md), [proposal](proposal.md), [realized core](../../../core.md)). Implementation dispatched after analyze PASS. Each test phase must demonstrate a relevant failure before implementation, then pass. Run tests with `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1` (and optionally `ADEVCONTAINER_SSH_TESTS_ONLY=1` for focused coverage). Use synthetic remotes, injected host runners/environment and temporary unconnected Unix sockets only; no actual containers, network Git, agent/keychain/key queries, or authentication claims.

## 1. Policy tests first
- [x] 1.1 Add policy tests for S01–S06: fetch/push remote parsing, deduplication, mixed and push-only SSH, all SSH URL forms, local/other URL exclusions, missing Git/nonrepo/nonzero/timeout, and credential-bearing remote output never appearing in warnings/metadata. Cover absent/blank/nonexistent/file/directory/socket/symlink endpoints and ambient-vs-injected environment disagreement. (path: Tests/adevcontainerTests/SSHForwardingPolicyTests.swift)
- [x] 1.2 Register the new test collection and record expected red failures before implementation. (path: Tests/adevcontainerTests/main.swift)

## Checkpoint
- [x] S01–S06 have deterministic tests; the new policy is not inferred from nonempty environment strings or real agent access.

## 2. Implement bounded bind policy after red
- [x] 2.1 Add the shared bind-only decision/discovery helper. Invoke host Git argv `-C <workspace> remote -v` through an injected bounded process runner using `localEnv`, parse fetch and push entries without logging raw output/errors, and classify with `GitURLClassifier` plus narrowly scoped userless SCP handling. Missing Git/discovery failure returns no automatic request. Resolve socket metadata without connecting; return automatic decision, warning, and nonsecret forwarding-marker/hint helpers. Do not change HTTPS fetch-only discovery or global clone classification. (path: Sources/ADevContainerLib/Git/SSHForwardingPolicy.swift)

## Checkpoint
- [x] S01–S06 policy tests pass; discovery invokes no guest exec, SSH, credential provider, shell, or network operation.

## 3. Integration tests before runtime/lifecycle edits
- [x] 3.1 Add synthetic command/runtime tests for S01–S09: final argv count, effective-marker true/false, host create environment matching injected endpoint and not guest env, explicit-only legacy behavior, bind rebuild parity, warnings before hooks, running/stopped/legacy reuse and bare start with no create/delete/reconfigure, config-hash stability, forwarded-container hint suppression, prefix-aware hints and clean JSON stdout. Foundation fake-executable coverage also checks host environment and redacted failures. (path: Tests/adevcontainerTests/AutomaticSSHForwardingCommandTests.swift)
- [x] 3.2 Register the integration collection and record expected red failures before integration edits; add a focused synthetic SSH selector. (path: Tests/adevcontainerTests/main.swift)
- [x] 3.3 Add regression assertions for existing clone SSH missing/present-agent handling, explicit deduplication and current HTTPS-with-socket behavior; no stricter socket metadata requirement may leak into clone. Allow only read-only discovery in existing bind-start assertions. (path: Tests/adevcontainerTests/CloneInVolumeTests.swift)
- [x] 3.4 Extend volume rebuild socket/no-socket coverage and adjust bind host-discovery assertions without changing credential acquisition expectations. (path: Tests/adevcontainerTests/RebuildCommandPhaseTests.swift)
- [x] 3.5 Assert the image-copy-up helper does not inherit SSH exposure and allow read-only discovery, not initialization/acquisition, on existing bind containers. (path: Tests/adevcontainerTests/AllCommandTests.swift)
- [x] 3.6 Keep start/open/hook assertions while admitting only the new read-only SSH eligibility discovery. (path: Tests/adevcontainerTests/VSCodeOpenTests.swift)

## Checkpoint
- [x] Command tests initially fail on missing bind behavior, not external dependencies. Existing clone/volume regressions passed in the policy baseline; expanded regressions pass in the final suite.

## 4. Integrate after red
- [x] 4.1 Add optional bind forwarding input to `CreateRequest.from`, retaining explicit runArgs and deduplicating `.ssh`; stamp a boolean-only internal `devcontainer.ssh_forwarded` marker for bind creates from the effective flag. Do not mutate resolved config/hash or volume policy. (path: Sources/ADevContainerLib/Runtime/CreateRequest.swift)
- [x] 4.2 Add narrow optional host-environment plumbing for the main create subprocess in streaming/nonstreaming paths, leaving defaults and helper requests unchanged. The automatic bind caller supplies `localEnv`; explicit-only calls preserve inherited behavior. Never translate host socket selection into guest `-e` flags. Capture automatic-create diagnostics and redact the selected endpoint before reporting a failure. (path: Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift)
- [x] 4.3 Evaluate shared policy on fresh bind create and pass its result/environment to the runtime; warn once before create-path hooks. On matching-hash running/stopped reuse, issue conditional guidance only for eligible unmarked/false-marker containers; do not run repair, affect hashes, or bypass existing drift errors. (path: Sources/ADevContainerLib/Commands/UpCommand.swift)
- [x] 4.4 Resolve bind policy from stamped host workspace and current `localEnv` before the delete boundary; apply it to replacement bind creation with the same environment and warning behavior. Keep volume branch, preflight/delete sequencing, recovery and volumes unchanged. (path: Sources/ADevContainerLib/Commands/RebuildCommand.swift)
- [x] 4.5 Add host-only conditional guidance for selected bind containers, both stopped and already running, using shared eligibility/marker logic. Start still has no SSH flag and never repairs forwarding or runs guest SSH probes. (path: Sources/ADevContainerLib/Commands/StartCommand.swift)

## Checkpoint
- [x] S01–S09 command tests pass; ambient/injected environment disagreement is covered at the recorded runtime process boundary and a Foundation-launched fake executable, not only the decision helper.

## 5. Verify and hand off
- [x] 5.1 Run debug/release-product builds and the full synthetic suite of record; map S01–S09 to passing tests and inspect the diff. See evidence and safety incident below; no real forwarding/authentication validation is claimed. (path: specs/changes/archive/20261022-automatic-ssh-forwarding-up/tasks.md)
- [x] 5.3 Add only a short user-facing automatic SSH/rebuild note while preserving pending README edits; detailed wiki ingestion belongs to the coordinator after review. (path: README.md)
- [x] 5.2 Converge implementation against persisted proposal/spec/tasks, obtain independent conformance review, and return to the coordinator for the authorized archive step only after verification. Independent re-review APPROVE was supplied in the archive handoff. (path: specs/changes/archive/20261022-automatic-ssh-forwarding-up/spec.md)

## Analyze
PASS (planning readiness): source core/clone/runArgs contracts consulted; no active delta folders existed at planning time; no legacy nested source specs found. Additive core requirements preserve drift/reuse semantics, explicit runArgs, clone/volume policy and HTTP(S) credentials. S01–S06 map to phases 1–4; S07 maps to 3.1/3.4/4.4; S08–S09 map to 3.1/4.3/4.5; security/environment constraints map to 1.1/2.1/3.1/4.2. No unresolved clarification markers or design overflow. This PASS is artifact readiness, not implementation/test verification.

Analyze rerun: PASS before the documentation addition; the subsequent handoff authorizes only a concise README note. It changes no forwarding outcome. The explicit synthetic-only test command corrects execution safety, not product scope. Automatic create diagnostics are captured/redacted to avoid leaking the selected host socket endpoint; explicit-only/volume runtime behavior stays unchanged.

Review-correction analyze: PASS before the helper-classification fix. Git `<transport>::<address>` is a remote-helper transport, not an SSH remote merely because it contains a colon. Excluding it refines existing SSH-only S03/S05 coverage, while S06 preserves explicit `--ssh`; it adds no normative outcome and does not change the clone classifier. New synthetic RED coverage fails for `hg::/synthetic/repository` and also checks helper addresses containing user/host syntax, missing/present sockets, explicit requests, bracketed IPv6 and colons inside valid SCP paths. Selectors are asserted before launching every Swift test.

## Review correction: remote-helper exclusion
- [x] RC1 Add helper-negative, explicit-request and valid IPv6/SCP regression cases; reproduce the reviewer failure before changing product code. (path: Tests/adevcontainerTests/SSHForwardingPolicyTests.swift)
- [x] RC2 Exclude the leading Git helper `::` separator before SSH/SCP classification without rejecting IPv6 literals or valid SCP path contents. (path: Sources/ADevContainerLib/Git/SSHForwardingPolicy.swift)
- [x] RC3 Verify focused/full synthetic suites, debug/release-product builds and whitespace; record evidence without runtime actions. (path: specs/changes/archive/20261022-automatic-ssh-forwarding-up/tasks.md)

Review-correction evidence (supersedes the earlier nine-group/1212-test totals): `ssh-helper-red.log` reproduces the blocker before the fix (nine groups pass; `ssh.policy.remoteHelpersNeverAutomaticallyForward` fails on `hg::/synthetic/repository`). After the four-line bind-policy guard, `ssh-helper-focused-green.log` records **10 groups passed**, and `ssh-helper-synthetic-green.log` records **1213 passed, zero failures/skips, 18 live integration cases explicitly excluded**. The new table checks five helper forms, both fetch/push entries, present/absent synthetic sockets and explicit `--ssh`, including final create-argv counts; positive coverage preserves SSH URLs, SCP, bracketed IPv6 and `::` inside SCP paths. `ssh-helper-debug-build.log` and `ssh-helper-release-build.log` record successful `swift build --product adevcontainer` and `swift build -c release --product adevcontainer`. All logs are under the same approved external `opencode/` directory. The launcher asserts `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1` before every Swift invocation, verifies the SSH selector for the focused suite, and unsets only the SSH selector for the full synthetic suite. Existing CLT linker-path warnings remain; no new SSH-code warning was reported. No runtime command, real container/image pull, authentication, host-key/config access, incident-cache action, README/wiki change, or outcome-spec edit occurred during this correction. At that stage, independent security re-review and task 5.2 were pending and no archive had been performed; see the final archive record below.

| Scenario | Test tasks | Implementation tasks |
|---|---|---|
| S01 | 1.1, 3.1 | 2.1, 4.1–4.3 |
| S02 | 1.1, 3.1 | 2.1, 4.3–4.4 |
| S03 | 1.1, 3.1 | 2.1, 4.3–4.4 |
| S04 | 1.1, 3.1 | 2.1, 4.3–4.4 |
| S05 | 1.1, 3.1 | 2.1 |
| S06 | 1.1, 3.1, 3.3 | 2.1, 4.1–4.4 |
| S07 | 3.1, 3.4 | 4.4 |
| S08 | 3.1 | 4.3, 4.5 |
| S09 | 3.1 | 4.1, 4.3, 4.5 |

## Execution evidence and limitations
- Policy RED: `ssh-policy-red.log` records the missing `SSHForwardingPolicy` compile failure before implementation. Synthetic baseline after policy implementation: 1205 passed, zero failures.
- Command RED: `ssh-commands-red.log` records three behavioral failures (missing bind marker/forwarding, rebuild forwarding, existing-container hint), with the three original policy cases passing. Later safety RED tests caught relative local-path misclassification, inherited Git tracing/token environment, and unredacted create diagnostics; these were corrected before GREEN.
- Final focused command: `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1 ADEVCONTAINER_SSH_TESTS_ONLY=1 swift run adevcontainerTests` — nine test groups passing, exercising S01–S09 through table-driven cases plus real local Git config, bounded synthetic executable timeout, unconnected Unix sockets and Foundation-launched fake runtime payloads.
- Full synthetic command: `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1 swift run adevcontainerTests` — 1212 passed, zero failures/skips; 18 live integration tests explicitly excluded. Existing lifecycle tests were adjusted only to admit read-only `git -C ... remote -v` discovery, retaining no-initialize/no-acquisition/no-create assertions.
- Build: `swift build` passed. `swift build -c release --product adevcontainer` passed. Bare `swift build -c release` also attempts the executable test product and failed to resolve its `@testable import ADevContainerLib` against the non-testing release library; no package/testability changes were made outside scope.
- Warnings: existing CLT linker search-path warnings and existing captured-variable warnings at `CredentialDuplexProcessTests.swift:67–68` remain; no warning points to changed/new SSH code. `git diff --check` passed.
- Logs reside in the approved external temporary directory under `opencode/`: `ssh-policy-red.log`, `ssh-policy-synthetic.log`, `ssh-commands-red.log`, `ssh-safety-red.log`, `ssh-boundary-red.log`, `ssh-focused-final.log`, `ssh-synthetic-final.log`, `ssh-debug-build.log`, `ssh-release-build.log`, `ssh-release-product.log`.
- **Safety incident:** An early invocation mistakenly omitted `ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1`. Its log (`ssh-policy-green.log`) shows live integration fixtures and real image pulls. The initial report incorrectly treated SIGTERM attempts as proof that execution stopped: later forensic reading shows that this run reached its final summary. Subsequent test executions explicitly selected synthetic tests. No real SSH authentication was validated. The restricted cleanup follow-up below records actual resources and remaining uncertainty; this execution does not claim the original no-live-runtime constraint was met.
- New synthetic fixture directories, local Git configuration, unconnected sockets and fake executables are confined to their temporary roots with deferred cleanup. No agent keys, external SSH or production broker state are used by the new test groups. No runtime cleanup or fixture deletion outside those owned roots was added.
- At the initial implementation handoff, independent review was pending and task 5.2 was intentionally unchecked. No archive, commit, branch operation, realized/archived spec edit, or wiki edit had occurred. Pending README/wiki content was preserved; README gained only the short local-SSH note.

## Incident inventory and restricted cleanup — 2026-10-22

### Execution established from evidence
- Original command: `swift run adevcontainerTests > <approved-temp>/opencode/ssh-policy-green.log 2>&1`, without the synthetic selector. Log birth/last-write bracket: **12:40:34–12:45:36 UTC** (09:40:34–09:45:36 UTC−03:00). These are file timestamps, not per-test start/end timestamps. SHA-256: `3fa7e84453c8bb53f0e29c0e9b9df2103247f6a905f8222ae9563fee1c1ff80a`.
- Observed original processes were test runner PID `8338` and its image-pull child PID `8963`. SIGTERM was attempted, but successful termination at that time was not verified. Neither PID exists now, and the current process inventory contains no `adevcontainerTests` runner. No new tests or production workloads were launched during cleanup.
- Final original-run summary: **1217 passed, zero failed, six skipped**. The integration group contains five mock-only passing cases, seven real passing container fixtures, one image-pull skip, and five feature/recovery opt-in skips. The two feature opt-in cases perform public `ghcr.io/v2/` reachability probes before their skip gate; no opt-in feature/recovery container flow ran.

| Real passing fixture | Exact container id | Logged temporary workspace basename | Disposition |
|---|---|---|---|
| smoke | `smoke` | `adev-int-9C17CA30-B4E4-447D-B50D-1A7BA4FE6DCA` | Log line 1546 confirms deletion |
| mounts/ports | `mounts-ports` | `adev-int-915F36F6-9483-40D1-9DB6-8F197ADE53D9` | Log line 1555 confirms deletion |
| lifecycle | `lifecycle` | `adev-int-772FA0C8-1850-4292-A122-5725E8558D4E` | Log line 1568 confirms deletion |
| lifecycle hooks | `lifecycle-hooks` | `adev-int-1BFA0370-4654-4550-B354-796D61F3DA7A` | Log line 1578 confirms deletion |
| runArgs/host requirements | `runargs-hostrequirements` | `adev-int-86F82C42-D3FB-40E7-BF18-6F8B143F6B60` | Log line 1601 confirms deletion |
| bare Debian | `debian` | `adev-int-BFDD01EA-B6FE-4756-BA74-BB68C4AC39B7` | Log line 1720 confirms deletion |
| local Features | `features-local-sample-a-sample-b` | `adev-int-42C91F27-6753-4285-A5B6-B17FC9930810` | Log line 1727 confirms deletion |

- Current runtime inventory confirms none of these seven containers exists. All seven exact logged workspace paths are absent. The `envUser` fixture skipped after the dotnet image-pull failure; no successful container creation for it is logged. The pull output includes `unknown command 'images'`; its cause is not established from the log.
- Image-transfer output and fixture definitions establish real use of `mcr.microsoft.com/devcontainers/base:ubuntu`, `mcr.microsoft.com/devcontainers/dotnet:10.0` (initial failed attempt, later fixtures succeeded), and `ghcr.io/bare-devcontainer/debian:trixie`. Local Features performed a real image build, executed both sample installers and hooks, and exported manifest-list digest `sha256:4502a3697b82ab001f54ba7f492b387d7501661a6a9f4772cbff19131c41e598` (log line 1709). Registry image creation dates do not prove prior local-cache absence.
- **Preexisting host-directory exposure escalated:** `mounts-ports.json` binds host `~/.kube` read-only and the passing fixture checks its directory exists. Directory metadata confirms it predates this run (birth 2026-08-09; mtime 2026-10-21). Its contents were not inspected during this investigation. There is no log evidence of key reads or host writes, but read-only exposure did occur; no reconstruction/restoration was attempted. Fixture configuration also mounted three named volumes, whose runtime creation timestamps below establish that those particular volume resources were created during this run rather than before it.

### Exact cleanup and provenance
Before every deletion batch, read-only machine metadata listed all three current containers, then individually inspected their mounts/image descriptors. All mount schemas were validated, and no container referenced any of the four target logical volume names or the exact derived image. No deletion was selected by generic prefix. Only these actions ran, each exiting zero:

| Resource | Creation timestamp (UTC) / attribution | Exact action |
|---|---|---|
| `opencode-config` | 12:43:23; exact mounts/ports fixture volume | `container volume delete opencode-config` |
| `opencode-data` | 12:43:23; exact mounts/ports fixture volume | `container volume delete opencode-data` |
| `opencode-state` | 12:43:24; exact mounts/ports fixture volume | `container volume delete opencode-state` |
| `sample-b-data` | 12:45:33; exact local sample-b Feature volume | `container volume delete sample-b-data` |
| `docker.io/library/adev-adev-int-42c91f27-67:68b70fff4478` | 12:45:29; UUID-derived workspace tag plus exact exported digest above | `container image delete docker.io/library/adev-adev-int-42c91f27-67:68b70fff4478` |

The four volume creation timestamps fall within the run window and match the exact successful fixture definitions. The generated image's tag embeds the logged random workspace identity and its current digest matches the build export. No resource was deleted merely because its name looked test-related. Image deletion reported **970.6 MB reclaimed**. No container stop/delete, host-directory deletion, generic image deletion, prune, authentication, key/credential query, or production-service mutation was performed during cleanup.

### Preserved resources and verification boundary
- **No pre-incident runtime baseline exists.** Full restoration to pre-incident state is not asserted. A cleanup-local metadata baseline was taken before any removal, and compared after removal.
- All three current containers have identical identity, state, start time, creation time, label hash, mount hash and image hash before/after cleanup. This includes the two preexisting user containers (one running, one stopped), identified in sanitized evidence by id-hash prefixes `7cfae66cefc10690` and `e372377996ec7b1a`. Neither was targeted by a mutating command.
- A shared runtime-managed `buildkit` container was created at 12:45:17 during the Features build and is currently stopped. It is preserved: it is a shared Apple builder, not a UUID-named fixture, and no prior builder/config baseline exists to distinguish a new service from replacement/reconfiguration. Its shared host build-export directory/cache was not modified by cleanup. No fixture container or test-runner workload remains active.
- Six other volumes and five shared images remain, with inventory identities unchanged except for the exact removals above. Shared base/dotnet/Debian images, builder/vminit images, registry download/content caches and shared builder caches were preserved because exclusive provenance/prior absence cannot be proved. Their remaining disk footprint is not attributed solely to this run. No image cache pruning was attempted.
- Original log and before/after/action evidence are retained under `<approved-temp>/opencode/`: `ssh-incident-before-cleanup-metadata.json`, `ssh-incident-inspect-before-cleanup.json`, `ssh-incident-cleanup-actions.json`, `ssh-incident-after-cleanup-metadata.json` (evidence JSON permissions `0600`). Only metadata, identity hashes and exact fixture attribution were recorded; no container environment, credentials or key contents were captured. This follow-up edits incident evidence only, not product/spec outcomes.

## Final verification and archive — 2026-10-22
- [x] Independent re-review APPROVE supplied by the coordinator from session `ses_e9c44f75dffeRSCSgsmlDPHHZ3`, after resolving the remote-helper blocker. Persisted S01–S09 remain mapped above to passing policy/command tests; final retained evidence shows 10 focused groups and 1213 synthetic tests passing, with debug/release-product builds passing. This archive step reads that evidence and does not rerun tests or access the runtime. Socket metadata proves neither agent liveness nor SSH authentication.
- [x] Merge exactly the two ADDED requirements into [realized core](../../../core.md), verified byte-for-byte against the prior source plus the persisted delta's normative block. No requirements are modified or removed. [Clone](../../../clone.md) and [runArgs](../../../runargs-host.md) source files remain unchanged.
- [x] Archive exactly `proposal.md`, `spec.md`, and `tasks.md` at `specs/changes/archive/20261022-automatic-ssh-forwarding-up/`; no design artifact existed. Remove the now-empty active directory, validate relative links, and verify hashes of all 326 files outside the allowed source/bundle paths against the archive-step baseline. No older archive, code, tests, README or wiki changes belong to this step.
- [x] Preserve the full incident inventory, read-only preexisting `~/.kube` exposure, restricted cleanup evidence, retained shared caches/builder and lack of a pre-incident runtime baseline. Approval of the forwarding implementation does not erase the incident or assert complete restoration. Archive authorization was explicitly supplied in the user's approved request and the coordinator's archive dispatch.
