# Tasks: clone-in-volume

Spec ref: `specs/changes/clone-in-volume/`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root  

> **Supersession note:** Early sections (§2–4) describe tar-pipe populate and `stop -w` selection. Those checkpoints were completed then **superseded** by §9 (in-container full clone + guest auth) and §10 (unified managed-only; `-w` only on `up`). Do not uncheck completed work. **Current live contract is the union of `specs/<domain>.md`** (clone requirements in `specs/clone.md`; this archive’s delta was realized at archive time into the former monolitih). Treat §2 full-clone staging, §3 tar-pipe populate, and §4 `stop -w` items as historical completed steps, not live product behavior.

Assume Swift 6.x / SPM, Apple `container`, and host `git` already available where E2E needs them. Do **not** install toolchains, GCM, or run network package installs as task steps. Test-first: write failing tests before implementation in each section. Mock git and AppleContainerRuntime boundaries so the default suite needs no network.

---

## 1. Identity and CreateRequest volume workspace

- [x] 1.1 Write failing tests: volume-mode `hash12` from normalized git URL + config relative path; stable across temp path changes (path: `Tests/adevcontainerTests/`)
- [x] 1.2 Write failing tests: human base from config `name` else repo basename; container name `adev-{base}-{hash12}`; volume name `adev-{base}-{hash12}-ws`; clip policy keeps hash + `-ws` (path: `Tests/adevcontainerTests/`)
- [x] 1.3 Write failing tests: URL normalization determinism (trailing `.git`, trailing slash, scheme userinfo strip) (path: `Tests/adevcontainerTests/`)
- [x] 1.4 Implement volume-mode identity helpers (normalize URL, base, names) (path: `Sources/ADevContainerLib/` identity module — extend existing name/hash types)
- [x] 1.5 Extend CreateRequest / mount model for workspace **named volume** mode (not host bind) (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift` or equivalent)
- [x] 1.6 Define label constants and apply on create: `devcontainer.managed`, `git_url`, `workspace_volume`, `workspace_mode=volume`, adapted `local_folder`, `config_file`, config hash, `config_volumes` (path: `Sources/ADevContainerLib/`)

## Checkpoint — identity / create request
- [x] verify **Volume name includes container identity**
- [x] verify **Same URL and config path stable identity**
- [x] verify **Human base from repo basename when name omitted**
- [x] verify **Bind and volume modes distinct hash inputs**

---

## 2. Host git client

- [x] 2.1 Define mockable `GitClient` / process boundary protocol (path: `Sources/ADevContainerLib/` — e.g. `Git/GitClient.swift`)
- [x] 2.2 Write failing tests: missing `git` on PATH → structured error (path: `Tests/adevcontainerTests/`)
- [x] 2.3 Write failing tests: sparse/shallow (or equivalent) config fetch invokes expected git argv shape; failure maps to structured error (path: `Tests/adevcontainerTests/`)
- [x] 2.4 Write failing tests: full clone to staging; does not require in-container credentials API (path: `Tests/adevcontainerTests/`) <!-- superseded by §9: no host fullClone on happy path -->
- [x] 2.5 Implement host git presence check + config-only fetch + full clone staging (path: `Sources/ADevContainerLib/Git/`) <!-- full-clone staging superseded by §9; config-only fetch remains -->
- [x] 2.6 Document in code: no GCM integration; host environment inherits credential.helper/SSH (path: same)

## Checkpoint — git client
- [x] verify **Missing host git fails structured**
- [x] verify unit tests mock git without network
- [x] Grep: no PAT flag surface; no GCM install/detect API

---

## 3. Clone command orchestration

- [x] 3.1 Write failing tests: missing config after fetch → structured fail, no container/volume/default image (path: `Tests/adevcontainerTests/`)
- [x] 3.2 Write failing tests: public happy path — resolve → ensure volume → create with volume mount + labels → start → tar-pipe populate + verify → hooks → success JSON with `gitUrl` + `workspaceVolume` (mocks) (path: `Tests/adevcontainerTests/`) <!-- populate path superseded by §9 in-container clone -->
- [x] 3.3 Write failing tests: temp cleanup on success and on failure; cleanup failure → stderr warn only (path: `Tests/adevcontainerTests/`)
- [x] 3.4 Write failing tests: create-path hook failure → delete container + workspace volume; populate failure → no success + cleanup (path: `Tests/adevcontainerTests/`)
- [x] 3.5 Write failing tests: `--branch` / unknown flags rejected (path: `Tests/adevcontainerTests/`)
- [x] 3.6 Implement config discovery on temp root (reuse Config discovery order); workspaceFolder default / `${localWorkspaceFolderBasename}` = git URL repo basename (path: `Sources/ADevContainerLib/Commands/` + Config)
- [x] 3.7 Implement tar-pipe copy-into-container workspace after start + post-copy verify (via AppleContainerRuntime) (path: `Sources/ADevContainerLib/Runtime/`, Commands) <!-- superseded by §9: happy path is in-container git clone; tar-pipe may remain unused utility -->
- [x] 3.8 Implement `CloneCommand` flow end-to-end with defer temp cleanup + StatusPrinter progress; existing name fail-closed; ws volume delete+recreate; failure cleanup deletes container + ws volume (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`) <!-- flow later extended by §8–10 -->
- [x] 3.9 Wire create-path LifecycleRunner matrix (same as up fresh create) (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`, CloneCommand)

## Checkpoint — clone
- [x] verify **Public happy path discovers nested config** (mocked)
- [x] verify **Missing config fails without default image**
- [x] verify **Clone create uses named volume not host bind**
- [x] verify **Managed and volume labels present**
- [x] verify **Populate uses host git then tar-pipe + verify** <!-- superseded by §9: in-container full clone + verify `.git` -->
- [x] verify **Temp dirs always cleaned up**
- [x] verify **Success JSON includes gitUrl and workspaceVolume**
- [x] verify **Branch flag rejected**
- [x] verify **Auth non-goal** (no PAT/GCM product API)

---

## 4. List, start, stop

- [x] 4.1 Write failing tests: `list` filters `devcontainer.managed=adevcontainer` client-side; table default; `--json` (path: `Tests/adevcontainerTests/`)
- [x] 4.2 Write failing tests: `start --name` starts stopped; already running no-op success; no re-clone (path: `Tests/adevcontainerTests/`)
- [x] 4.3 Write failing tests: `start` interactive picker when multiple + TTY; non-TTY multi → structured need `--name` (path: `Tests/adevcontainerTests/`)
- [x] 4.4 Write failing tests: volume-mode `start` runs **no** lifecycle hooks (path: `Tests/adevcontainerTests/`)
- [x] 4.5 Write failing tests: `stop -w` preserved; `stop --name` managed; interactive when no workspace (path: `Tests/adevcontainerTests/`) <!-- `-w` on stop superseded by §10 managed-only -->
- [x] 4.6 Implement managed-container discovery helper (list JSON → filter labels) (path: `Sources/ADevContainerLib/`)
- [x] 4.7 Implement TTY picker utility (shared start/stop) (path: `Sources/ADevContainerLib/Support/` or Commands)
- [x] 4.8 Implement `ListCommand` (path: `Sources/ADevContainerLib/Commands/ListCommand.swift`)
- [x] 4.9 Implement `StartCommand` (runtime start only for volume-mode) (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 4.10 Extend `StopCommand` selection (`-w` + `--name` + picker) (path: `Sources/ADevContainerLib/Commands/StopCommand.swift`) <!-- `-w` path removed in §10; managed `--name`/picker remains -->

## Checkpoint — list/start/stop
- [x] verify **List shows only managed containers**
- [x] verify **List JSON is machine-readable**
- [x] verify **Start stopped managed container**
- [x] verify **Start already running is no-op success**
- [x] verify **Start interactive picker when multiple**
- [x] verify **Volume-mode start runs no hooks**
- [x] verify **Stop with -w unchanged** <!-- superseded by §10: `-w` only valid for `up` -->
- [x] verify **Stop by name for managed container**
- [x] verify **up start-stopped postStart** still applies for bind `-w` (regression)

---

## 5. Prune (and delete unchanged)

- [x] 5.1 Write failing tests: prune volume-mode removes workspace `*-ws` volume in addition to container, config volumes, config image (path: `Tests/adevcontainerTests/`)
- [x] 5.2 Write failing tests: delete removes container only — workspace volume remains (path: `Tests/adevcontainerTests/`)
- [x] 5.3 Write failing tests: prune still skips binds and global prune (path: `Tests/adevcontainerTests/`)
- [x] 5.4 Extend PruneCommand resource set for `devcontainer.workspace_volume` / `*-ws` and `devcontainer.config_volumes` (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 5.5 Confirm DeleteCommand does not remove workspace volume (path: `Sources/ADevContainerLib/Commands/DeleteCommand.swift`)

## Checkpoint — prune/delete
- [x] verify **Prune removes volume-mode workspace volume**
- [x] verify **Delete does not remove workspace volume**
- [x] verify **Prune still skips binds and global prune**

---

## 6. Tests and fixtures

- [x] 6.1 Add minimal fixture config(s) for clone resolve unit tests (image-only smoke shape; no forever-reject) (path: `Tests/Fixtures/` as needed)
- [x] 6.2 [P] Unit coverage for normalization, names, labels, selection, prune set (path: `Tests/adevcontainerTests/`)
- [x] 6.3 [P] Command tests with mocked GitClient + AppleContainerRuntime / ProcessRunning (path: `Tests/adevcontainerTests/`)
- [x] 6.4 Optional E2E (documented env gate): public repo clone when `git` + Apple `container` available — not required for default CI (path: tests + README/comment only if needed)
- [x] 6.5 Regression: `up` still bind-mounts host workspace; Features/lifecycle/runArgs paths unchanged for `up` (path: `Tests/adevcontainerTests/`)

## Checkpoint — tests
- [x] `swift run adevcontainerTests` green for default (mocked) suite
- [x] verify **Up still bind-mounts host workspace**
- [x] No network required for default suite

---

## 7. CLI wiring

- [x] 7.1 Register subcommands: `clone`, `start`, `list`; extend `stop` flags (`--name`) (path: CLI entry / `Sources/` executable + command router)
- [x] 7.2 Help text: URL-only clone; auth via host git; start vs up hooks distinction (path: command help strings)
- [x] 7.3 Ensure all new `container` subprocesses stay behind AppleContainerRuntime; git stays on GitClient (path: review `Sources/ADevContainerLib/`)
- [x] 7.4 [P] Progress lines for clone stages (fetch config, resolve, create, populate, hooks) via StatusPrinter; quiet suppresses (path: CloneCommand / StatusPrinter)

## Checkpoint — CLI
- [x] `adevcontainer clone|start|list|stop --help` reflect v1 surface
- [x] Grep: no `container` shell-out outside AppleContainerRuntime
- [x] Grep: no GCM/PAT product flags

---

## Implementation order (summary)

| Phase | Focus | Parallelism |
|-------|--------|-------------|
| 1 | Identity + CreateRequest volume workspace | sequential foundation |
| 2 | Host git client | after 1 types exist; tests [P] with 1.x tests |
| 3 | Clone command | depends on 1–2 |
| 4 | List / start / stop | [P] with late 3 once labels exist |
| 5 | Prune (+ delete check) | after labels/volume name stable |
| 6 | Fixtures & full test pass | ongoing test-first; harden here |
| 7 | CLI wiring | after commands exist |

---

## Done when

- [x] All checklist items above complete
- [x] Spec scenarios covered by tests (mocked and/or E2E gate): clone public happy path, missing config fail, temp cleanup, volume name includes identity, start interactive/list, stop extend, prune removes ws volume, auth non-goals (no PAT/GCM)
- [x] No product questions left for a Swift engineer implementing from this folder alone
- [x] `up` bind-mode behavior preserved; volume-mode is opt-in via `clone`

---

## 8. Clone auto git Feature (follow-on)

- [x] 8.1 Unit: `FeatureGitEnsure.ensurePresent` — empty → inject git:1; existing git → no dup; common-utils → no inject
- [x] 8.2 CloneCommand: after resolve, before Features gate, ensure git feature; status line when injecting; empty list enters Features path
- [x] 8.3 Command tests with mocked FeaturesRunner path when config had no features
- [x] 8.4 Spec ADDED requirement + scenarios; README note; `up` unchanged

---

## 9. In-container full clone + guest auth (follow-on)

- [x] 9.1 Spec/proposal: replace host clone+tar-pipe populate with in-container full clone + auth matrix (SSH/HTTPS)
- [x] 9.2 `GitURLClassifier` + `HostGitCredential` (`git credential fill`, token/`gh` fallbacks)
- [x] 9.3 `CreateRequest.fromVolumeMode(enableSSHForward:)` injects `.ssh`
- [x] 9.4 `CloneCommand`: classify URL; SSH sock gate; in-container clone via runtime.exec; HTTPS one-shot + store; verify `.git`; no host fullClone on happy path
- [x] 9.5 Tests: mock credential fill; SSH runArgs; HTTPS no sock path; no host fullClone; populate failure cleanup
- [x] 9.6 README + CLI help: SSH vs HTTPS auth notes

---

## 10. Unified CLI identity (managed-only)

- [x] 10.1 `ContainerIdentity.bindModeLabels` + ConfigResolver stamps managed/bind/managed labels on `up` create
- [x] 10.2 `exec`/`stop`/`delete`/`prune`/`inspect` resolve via `ManagedContainers.resolveSelection` only (no ConfigResolver / `-w`)
- [x] 10.3 Main: `-w` only for `up`; usage error “-w is only valid for up” on other commands
- [x] 10.4 Tests + README + delta spec updated; `swift run adevcontainerTests` green

(End of file)
