# Tasks: lifecycle-runargs-host

Spec ref: `specs/changes/archive/20260807-lifecycle-runargs-host/` (archived; live contract: union of `specs/<domain>.md`)  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: `/Users/wyller/Repos/dev-containerization/`  

Assume Swift 6.x / SPM and Apple `container` already on the host. Do **not** install toolchains or run network package installs. Test-first: write failing tests before implementation in each section.

---

## 1. Lifecycle / runArgs / hostRequirements fixtures

- [x] 1.1 Add lifecycle hooks fixture with `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, and optional `postAttachCommand` (path: `Tests/Fixtures/lifecycle-hooks.json`)
- [x] 1.2 Add runArgs + hostRequirements fixture with allowlisted flags and parseable `memory`/`cpus` (path: `Tests/Fixtures/runargs-host.json`)
- [x] 1.3 [P] Confirm core fixtures still present and unchanged in intent (path: `Tests/Fixtures/`)

## Checkpoint — fixtures
- [x] Fixtures are pure JSON, no forever-rejected props
- [x] Paths match change spec table

---

## 2. runArgs allowlist admission (test-first)

- [x] 2.1 Write failing tests: allow `--init`, `--cap-add=NAME`, two-token `--cap-add`/`NAME`, `--cap-drop` forms; empty array OK (path: `Tests/adevcontainerTests/AllUnitTests.swift` or dedicated `RunArgsAdmissionTests` section)
- [x] 2.2 Write failing tests: reject `--privileged`, `--device…`, unknown flags, dangling `--cap-add` without name (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 2.3 Implement allowlist parser/admission; return structured allowlisted runArgs for the resolved model (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [x] 2.4 Extend resolved config to carry admitted runArgs (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 2.5 Wire resolver to populate runArgs after admit (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [x] 2.6 Update forever-reject / unsupported messages so allowlisted entries are not described as “MVP allowlist is empty” (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)

## Checkpoint — runArgs admission
- [x] verify **runArgs allowlist** scenarios (allow, empty, privileged, device, unknown, dangling)
- [x] verify **Allowlisted cap-add no longer errors** modified scenario
- [x] `Tests/Fixtures/runargs-host.json` admits

---

## 3. runArgs → create argv mapping (test-first)

- [x] 3.1 Write failing tests: CreateRequest/create argv includes `--init` and cap-add/cap-drop forms from resolved runArgs (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.2 Map allowlisted runArgs onto `container create` argv in CreateRequest (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift`)
- [x] 3.3 Include runArgs in config hash material when present so drift detection catches changes (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 3.4 [P] Runtime tests still sole shell-out boundary (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)

## Checkpoint — create mapping
- [x] verify **Allowlisted runArgs admit and map** scenario
- [x] No blind passthrough of non-allowlisted tokens
- [x] Grep: no `container` subprocess outside AppleContainerRuntime

---

## 4. hostRequirements preflight (test-first)

- [x] 4.1 Write failing tests: parse `memory` (`8gb`, `8192mb`), `cpus` number/string; unknown key fails; bad memory string fails (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 4.2 Write failing tests: below-threshold memory/cpus → hard failure; gpu → warn unsupported; absent → no-op; create limits when set (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 4.3 Implement hostRequirements parse + evaluation types (hardFailures vs warnings) (path: `Sources/ADevContainerLib/Config/HostRequirements.swift`)
- [x] 4.4 Injectable host resource provider (memory bytes, CPU count) for tests + real macOS implementation (path: `Sources/ADevContainerLib/Config/HostResourceInfo.swift`)
- [x] 4.5 Remove pure-ignore of `hostRequirements`; admit as evaluated property; fail on unparseable/unknown keys (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [x] 4.6 Run preflight on every `up` before path selection; **fail** on capacity shortfall; map requested memory/cpus to create `-m`/`-c` when present (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`, `CreateRequest.swift`)
- [x] 4.7 Structured CLIError codes/messages for parse failures and shortfall (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [x] 4.8 Include hostRequirements memory/cpus in config hash material (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)

## Checkpoint — hostRequirements
- [x] verify all **hostRequirements preflight** scenarios (fail-on-shortfall + create limits)
- [x] verify **hostRequirements no longer silently ignored** modified scenario
- [x] Default policy is **fail** on capacity shortfall; apply limits on create when host OK

---

## 5. Lifecycle model: onCreate, updateContent, postStart, postAttach (test-first)

- [x] 5.1 Write failing tests: parse/admit all four new lifecycle properties; invalid form errors; postAttach admits (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 5.2 Extend `ResolvedDevContainerConfig` with `onCreateCommand`, `updateContentCommand`, `postStartCommand`, `postAttachCommand` (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 5.3 Parse lifecycle fields in resolver (reuse `LifecycleCommand.parse`) (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [x] 5.4 Add keys to supported admission set (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [x] 5.5 Include create-path lifecycle commands (and postStart) in hash material as appropriate for drift (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 5.6 Add CLIError codes for lifecycle failures beyond postCreate (or generalize lifecycle failed + property name) (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)

## Checkpoint — lifecycle model
- [x] verify **Lifecycle command forms** scenario
- [x] verify **Invalid postAttach form still fails resolve**
- [x] `Tests/Fixtures/lifecycle-hooks.json` admits

---

## 6. UpCommand hook matrix (test-first)

- [x] 6.1 Write failing tests with mock runtime: fresh create order onCreate → updateContent → postCreate → postStart (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 6.2 Write failing tests: reuse running → zero lifecycle execs (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 6.3 Write failing tests: start stopped → postStart only (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 6.4 Write failing tests: create-path failure (each hook) → `up` fails + delete invoked; restart postStart failure → fail without delete (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 6.5 Write failing tests: postAttach present → not executed; one skip status on stderr (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 6.6 Implement shared lifecycle runner helper (exec, status line, fail mapping) (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)
- [x] 6.7 Wire UpCommand path matrix and delete-on-fail for full create-path including first-create postStart (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 6.8 Emit postAttach skip status via StatusPrinter when property set (path: `Sources/ADevContainerLib/Support/StatusPrinter.swift` and/or `UpCommand.swift`)

## Checkpoint — up matrix
- [x] verify **Fresh create runs full hook order**
- [x] verify **Reuse running skips lifecycle**
- [x] verify **Start stopped runs postStart only**
- [x] verify **Create-path hook failure deletes container**
- [x] verify **Restart postStart failure does not delete container**
- [x] verify **postAttach admitted but not run on up**
- [x] verify **Create then reuse still stable with hooks**

---

## 7. Integration and suite wiring

- [x] 7.1 Register new unit/command tests in suite entrypoints (path: `Tests/adevcontainerTests/main.swift`, `AllUnitTests.swift`, `AllCommandTests.swift`)
- [x] 7.2 Optional integration: lifecycle-hooks and/or runargs-host against real Apple `container` if available, else skip (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 7.3 Run full suite: `swift run adevcontainerTests` (path: package root)

## Checkpoint — suite
- [x] Full MiniTest suite green
- [x] Integration skips cleanly without Apple `container`
- [x] Core scenarios remain green (no regression)

---

## 8. Realized contract + docs touchpoints (no scope creep)

- [x] 8.1 Merge lifecycle / runArgs / hostRequirements delta into realized contract after implementation lands (paths: `specs/lifecycle-hooks.md`, `specs/runargs-host.md`)
- [x] 8.2 README: mention lifecycle / runArgs allowlist / hostRequirements enforce+apply if command surface docs list capabilities (path: `README.md`)
- [x] 8.3 Do **not** implement features, Compose, privileged, device, or postAttach execution in this change

## Checkpoint — closeout
- [x] Realized spec matches shipped behavior
- [x] Non-goals respected (features/Compose/privileged/device/blind runArgs/full postAttach)

---

## Implementation notes (locked — no further product decisions)

| Topic | Decision |
|-------|----------|
| Create-path order | onCreate → updateContent → postCreate → postStart |
| Reuse running | No lifecycle re-run |
| Start stopped | postStart only |
| Create-path failure | Delete container before failing `up` (all hooks through first-create postStart) |
| Restart postStart failure | Fail `up`; do **not** delete container |
| postAttachCommand | Admit; do not run on `up`; one status: postAttach skipped (no attach hook) |
| runArgs allow | `--init`, caps, shm-size, dns*, no-dns, ulimit, tmpfs (path-before-colon), cpus/memory (merge), named `--network`, rosetta, ssh, read-only; empty OK |
| runArgs reject | privileged, device, security-opt, gpus, ipc, pid, userns, cgroupns, hostname, add-host, sysctl, group-add, runtime, network=host/bridge/none/container:*, first-class flags, unknown, incomplete two-token forms |
| runArgs memory/cpus | hostRequirements wins per dimension; else apply runArgs to `-m`/`-c`; no duplicate tokens |
| hostRequirements | Evaluate; **fail** on memory/cpus shortfall or unreadable host; map requested memory/cpus to create `-m`/`-c`; fail on unparseable/unknown keys; gpu → warn unsupported (no fail alone) |
| Fail up on low host resources | **Yes** (enforce); apply create limits when host has capacity |
| Features / Compose | Still reject |
| Test runner | `swift run adevcontainerTests` |
| Paths | Library under `Sources/ADevContainerLib/`; do not put logic only in thin `Sources/adevcontainer/` entry |
