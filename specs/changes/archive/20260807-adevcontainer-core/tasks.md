# Tasks: adevcontainer-core

Spec ref: `specs/changes/archive/20260807-adevcontainer-core/` (archived; realized source: `specs/adevcontainer/spec.md`)  
Binary: `adevcontainer`  
Package root: `/Users/wyller/Repos/dev-containerization/`  
Assume Swift 6.x / SPM and Apple `container` already on the host. Do **not** install toolchains or run network package installs beyond SPM resolution of declared dependencies if any (prefer stdlib-only).

---

## 1. Scaffold SPM package

- [x] 1.1 Create Swift package manifest with executable product `adevcontainer` (path: `Package.swift`)
- [x] 1.2 Add CLI entrypoint stub that prints usage / dispatches subcommands (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 1.3 Add empty test target wiring (path: `Tests/adevcontainerTests/SmokeTests.swift`)
- [x] 1.4 Verify `swift build` and `swift test` succeed on host (path: `Package.swift`)

## Checkpoint — scaffold
- [x] `swift build` produces `.build/` executable product `adevcontainer`
- [x] `swift test` runs (may be empty/smoke only)

---

## 2. Shared types, errors, and process runner

- [x] 2.1 Define structured error model (code, property/flag, message, actionable hint) (path: `Sources/adevcontainer/Errors/CLIError.swift`)
- [x] 2.2 Define machine-readable `UpResult` (`outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder`) (path: `Sources/adevcontainer/Model/UpResult.swift`)
- [x] 2.3 Define `ProcessRunning` protocol + real `FoundationProcessRunner` (path: `Sources/adevcontainer/Runtime/ProcessRunner.swift`)
- [x] 2.4 [P] Add mock process runner for tests (path: `Tests/adevcontainerTests/Support/MockProcessRunner.swift`)

## Checkpoint — shared foundation
- [x] Unit test: structured error encodes property name for unsupported-property cases (path: `Tests/adevcontainerTests/CLIErrorTests.swift`)
- [x] Unit test: `UpResult` JSON encodes required fields (path: `Tests/adevcontainerTests/UpResultTests.swift`)

---

## 3. Config discovery, JSONC parse, substitution (test-first)

- [x] 3.1 Write failing tests for discovery order and missing config (path: `Tests/adevcontainerTests/ConfigDiscoveryTests.swift`)
- [x] 3.2 Implement config path discovery (`.devcontainer/devcontainer.json` then `.devcontainer.json`) (path: `Sources/adevcontainer/Config/ConfigDiscovery.swift`)
- [x] 3.3 Write failing tests for JSONC comments and trailing-comment configs using fixtures (path: `Tests/adevcontainerTests/ConfigParserTests.swift`)
- [x] 3.4 Implement JSONC loader/parser into raw DOM or Codable pipeline (path: `Sources/adevcontainer/Config/JSONCParser.swift`)
- [x] 3.5 Write failing tests for substitution subset and unknown-token errors (path: `Tests/adevcontainerTests/SubstitutionTests.swift`)
- [x] 3.6 Implement variable substitution (`localWorkspaceFolder`, `localWorkspaceFolderBasename`, `localEnv:*`, `containerWorkspaceFolder`) (path: `Sources/adevcontainer/Config/VariableSubstitutor.swift`)
- [x] 3.7 Define resolved config model for Phases 0–3 fields (path: `Sources/adevcontainer/Config/DevContainerConfig.swift`)

## Checkpoint — parse & substitute
- [x] verify **Config discovery** scenarios (prefer nested, fallback root, missing)
- [x] verify **JSONC configuration parsing** scenario (comments)
- [x] verify **Variable substitution subset** scenarios
- [x] Fixtures under `Tests/Fixtures/` load without parse errors

---

## 4. Admission / unsupported-property policy (test-first)

- [x] 4.1 Write failing tests for forever-reject: docker-ood feature, privileged, device, Compose keys, unknown runArgs (path: `Tests/adevcontainerTests/ConfigAdmissionTests.swift`)
- [x] 4.2 Write failing tests: `customizations.vscode` does not fail; Phase fixtures admit (path: `Tests/adevcontainerTests/ConfigAdmissionTests.swift`)
- [x] 4.3 Implement admission: supported surface, metadata ignore list, runArgs allowlist (default empty), structured errors (path: `Sources/adevcontainer/Config/ConfigAdmissions.swift`)
- [x] 4.4 Wire parse → substitute → admit pipeline facade (path: `Sources/adevcontainer/Config/ConfigResolver.swift`)

## Checkpoint — admission
- [x] verify all **Unsupported property policy** scenarios
- [x] verify **Phase fixtures** admitted for their phase
- [x] verify `customizations.vscode` does not fail parse

---

## 5. AppleContainerRuntime adapter (test-first)

- [x] 5.1 Write failing tests for runtime argv mapping and JSON parse success/failure using MockProcessRunner (path: `Tests/adevcontainerTests/AppleContainerRuntimeTests.swift`)
- [x] 5.2 Implement `AppleContainerRuntime` (create/start/stop/delete/exec/inspect/list-or-resolve by name) — sole module that invokes `container` (path: `Sources/adevcontainer/Runtime/AppleContainerRuntime.swift`)
- [x] 5.3 Implement deterministic container name + labels builder (`devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.config_hash`) (path: `Sources/adevcontainer/Runtime/ContainerIdentity.swift`)
- [x] 5.4 Map resolved config → create request DTO (image, binds, env, user, publish, mounts) (path: `Sources/adevcontainer/Runtime/CreateRequest.swift`)

## Checkpoint — runtime boundary
- [x] verify **AppleContainerRuntime boundary** mockable scenario
- [x] verify **Deterministic identity and labels** unit expectations (stable name + label keys)
- [x] No other Source file shells out to `container` (grep/convention check)

---

## 6. Phase 0 commands: doctor, up (image+bind), exec, stop, delete, inspect

- [x] 6.1 Write failing tests for `doctor` pass/fail (path: `Tests/adevcontainerTests/DoctorCommandTests.swift`)
- [x] 6.2 Implement `doctor` command (path: `Sources/adevcontainer/Commands/DoctorCommand.swift`)
- [x] 6.3 Write failing tests for `up` create/reuse/start + UpResult JSON (path: `Tests/adevcontainerTests/UpCommandTests.swift`)
- [x] 6.4 Implement `up` for Phase 0 (image, workspace bind, identity, JSON result) (path: `Sources/adevcontainer/Commands/UpCommand.swift`)
- [x] 6.5 Write failing tests for `exec` running vs not-running (path: `Tests/adevcontainerTests/ExecCommandTests.swift`)
- [x] 6.6 Implement `exec` (path: `Sources/adevcontainer/Commands/ExecCommand.swift`)
- [x] 6.7 [P] Write failing tests for `stop` / `delete` / `inspect` (path: `Tests/adevcontainerTests/LifecycleCommandTests.swift`)
- [x] 6.8 Implement `stop` (path: `Sources/adevcontainer/Commands/StopCommand.swift`)
- [x] 6.9 Implement `delete` (path: `Sources/adevcontainer/Commands/DeleteCommand.swift`)
- [x] 6.10 Implement `inspect` (path: `Sources/adevcontainer/Commands/InspectCommand.swift`)
- [x] 6.11 Wire subcommand routing in main (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 6.12 Add integration test: Phase 0 against real Apple `container` if available, else skip (path: `Tests/adevcontainerTests/Integration/Phase0IntegrationTests.swift`)

## Checkpoint — Phase 0
- [x] verify **Doctor preflight** scenarios
- [x] verify **Up lifecycle** create/reuse/start + **Up JSON shape**
- [x] verify **Exec** scenarios
- [x] verify **Stop and delete** scenarios
- [x] verify **Inspect after up**
- [x] verify **Phase 0 minimal config** (fixture `Tests/Fixtures/smoke.json`)
- [x] verify **VS Code attach acceptance** (container running and inspectable)
- [x] Integration: real container path runs or skips cleanly

---

## 7. Phase 1: env, user, workspaceFolder

- [x] 7.1 Write failing tests for `containerEnv`, `remoteUser`/`containerUser`, `workspaceFolder` on create/exec cwd (path: `Tests/adevcontainerTests/Phase1ConfigTests.swift`)
- [x] 7.2 Extend CreateRequest + UpCommand/ExecCommand for env, user, workspace folder (path: `Sources/adevcontainer/Runtime/CreateRequest.swift`)
- [x] 7.3 Ensure `UpResult.remoteUser` and `remoteWorkspaceFolder` reflect Phase 1 resolution (path: `Sources/adevcontainer/Commands/UpCommand.swift`)
- [x] 7.4 Wire fixture-based unit/integration coverage (path: `Tests/adevcontainerTests/Integration/Phase1IntegrationTests.swift`)

## Checkpoint — Phase 1
- [x] verify **Phase 1 env user folder** scenario (`Tests/Fixtures/env-user.json`)
- [x] verify substitution still applied to env values
- [x] Integration skip-if-unavailable pattern retained

---

## 8. Phase 2: mounts, forwardPorts, portsAttributes

- [x] 8.1 Write failing tests for bind + volume mounts and port publish mapping (path: `Tests/adevcontainerTests/Phase2MountsPortsTests.swift`)
- [x] 8.2 Implement mount parsing (string + object forms) post-substitution (path: `Sources/adevcontainer/Config/MountParser.swift`)
- [x] 8.3 Map `forwardPorts` → Apple container publish flags; store `portsAttributes` as metadata (path: `Sources/adevcontainer/Runtime/CreateRequest.swift`)
- [x] 8.4 Surface `portsAttributes` on `inspect` (path: `Sources/adevcontainer/Commands/InspectCommand.swift`)
- [x] 8.5 Integration tests with fixture (path: `Tests/adevcontainerTests/Integration/Phase2IntegrationTests.swift`)

## Checkpoint — Phase 2
- [x] verify **Phase 2 mounts and ports** scenario (`Tests/Fixtures/mounts-ports.json`)
- [x] verify portsAttributes metadata-only (inspect shows labels; no auto-forward claims)
- [x] reject path still hard-errors privileged/device if introduced in mounts/runArgs tests

---

## 9. Phase 3: postCreateCommand lifecycle

- [x] 9.1 Write failing tests: postCreate exit 0 succeeds up; non-zero fails up (path: `Tests/adevcontainerTests/Phase3LifecycleTests.swift`)
- [x] 9.2 Implement postCreate execution via runtime exec after create/start; fail `up` on non-zero (path: `Sources/adevcontainer/Commands/UpCommand.swift`)
- [x] 9.3 Support string and argv-array `postCreateCommand` forms (path: `Sources/adevcontainer/Config/DevContainerConfig.swift`)
- [x] 9.4 Integration test with fixture (path: `Tests/adevcontainerTests/Integration/Phase3IntegrationTests.swift`)

## Checkpoint — Phase 3 / MVP
- [x] verify **Phase 3 postCreate success** and **postCreate failure** scenarios
- [x] verify fixture `Tests/Fixtures/lifecycle.json`
- [x] Full suite green via `swift run adevcontainerTests` (CLT entrypoint; not only `swift test`); integration tests skip or pass on host with Apple `container`
- [x] Manual smoke optional: `doctor` → `up` → `exec` → `inspect` → `stop` → `delete` using Phase 3 fixture workspace

---

## 10. Docs touchpoints (no product scope creep)

- [x] 10.1 Minimal root README: what/why, prerequisites (macOS 26+ arm64, Apple container, Swift), build, command list, phase fixtures pointer, VS Code attach note (path: `README.md`)

## Checkpoint — docs
- [x] README passes 5-second test: what, why, how to build/run `doctor`
- [x] Explicit non-goals: no Compose, no docker-ood, no privileged/device, attach is manual

---

## 11. Post-MVP polish (landed)

- [x] 11.1 `prune` command: container + config named volumes + config image; not binds; not global prune
- [x] 11.2 Named volume reuse on `up`: list-first ensure; existing → reuse status, no fail solely because volume exists
- [x] 11.3 Docs/spec delta: README, wiki architecture + cli-runtime-boundary, proposal/spec requirements for prune + volume reuse

## Checkpoint — polish
- [x] `prune` and volume-reuse behavior match spec requirements
- [x] Command lists include `prune`; delete vs prune documented

---

## Implementation notes (locked — no further product decisions)

| Topic | Decision |
|-------|----------|
| Binary name | `adevcontainer` |
| Config search order | `.devcontainer/devcontainer.json` → `.devcontainer.json` |
| JSONC | Required |
| Substitution | `${localWorkspaceFolder}`, `${localWorkspaceFolderBasename}`, `${localEnv:VAR}`, `${containerWorkspaceFolder}` |
| runArgs allowlist | Empty at MVP; all entries error |
| features | Any features block → error; docker-ood called out in message |
| Compose keys | `dockerComposeFile`, `service`, and compose-driver equivalents → error |
| customizations.vscode | Ignore or metadata; never fail |
| postCreate | Via `container exec`; non-zero fails `up` |
| Up JSON | `outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder` |
| Identity | Deterministic name + labels; no label-filter list primary |
| Integration tests | Skip when `container` missing/unhealthy |
| Phases 4–6 | Out of scope |
