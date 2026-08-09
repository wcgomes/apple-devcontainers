# Tasks: rebuild

Spec ref: `specs/changes/rebuild/`  
Design ref: `specs/changes/rebuild/design.md`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. Mock `AppleContainerRuntime`, the Features fetch/build boundary, and the VS Code launcher so the default suite needs no real `container` runtime, no network, and no VS Code install. Reuse existing fixtures (`Tests/Fixtures/smoke.json`, `lifecycle-hooks.json`, `features-node.json`, `features-local.json`) for rebuild tests; add no new fixtures unless a task says so.

## 1. ConfigReader extraction and strict semantics

- [ ] 1.1 Write failing tests: strict bind-mode read resolves from labels `devcontainer.local_folder` + `devcontainer.config_file` via `ConfigResolver.resolve`; missing/empty label inputs or missing host file → `config_not_found`; parse/admission failure → `config_parse` (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [ ] 1.2 Write failing tests: strict volume-mode read — exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename` from stamped `devcontainer.workspace_folder` (fallback `/workspaces`); `cat` failure or empty text → `config_not_found`; unparseable in-volume config → `config_parse` (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [ ] 1.3 Write failing tests: best-effort mode returns nil (not throws) for the same missing-input cases, preserving today's `PostAttachConfigLoader` skip semantics (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [ ] 1.4 Implement `ConfigReader` with strict/best-effort modes (path: `Sources/ADevContainerLib/Commands/ConfigReader.swift`)
- [ ] 1.5 Verify `CLIErrorCode.configNotFound` (`config_not_found`) and `CLIErrorCode.configParse` (`config_parse`) already exist and are reused by the strict reader — no new CLIErrorCode cases are added (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [ ] 1.6 Refactor `PostAttachConfigLoader.load`/`loadBindMode`/`loadVolumeMode` onto `ConfigReader` best-effort; keep public behavior identical (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`)
- [ ] 1.7 Run the existing suite; confirm zero regressions from the refactor (path: `Tests/adevcontainerTests/`)

## Checkpoint — reader
- [ ] verify **bind rebuild missing config file fails config_not_found before delete**
- [ ] verify **volume rebuild unreadable config fails before delete**
- [ ] verify **volume rebuild parse failure is config_parse**
- [ ] verify postAttach-loader skip semantics unchanged (best-effort nil regression)

---

## 2. CLI surface

- [ ] 2.1 Write failing tests: `rebuild` dispatch accepts `--name`, `--skip-pull`, `--vscode`, `--json`, and combination; omitted flags default off (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 2.2 Write failing tests: `-w <path>` on rebuild is a usage error (`-w is only valid for up`) via the existing global gate; unknown flag fails closed (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 2.3 Write failing tests: `printCommandHelp("rebuild")` prints rebuild help; main usage lists `rebuild` with flags (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 2.4 Implement dispatch `case "rebuild"` threading `--name`/`--skip-pull`/`--vscode`/`--json` into `RebuildOptions` (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [ ] 2.5 [P] Add usage row and `printCommandHelp("rebuild")` case (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [ ] 2.6 Wire a stub `RebuildCommand.run` returning success JSON (up-shape) so dispatch tests compile and fail only on asserted behavior (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint — CLI
- [ ] verify **-w on rebuild is usage error**
- [ ] verify **rebuild unknown flag fails closed**
- [ ] verify `printCommandHelp("rebuild")` present and usage row lists rebuild

---

## 3. Phase A — selection, stamps, strict read, pre-delete gate

- [ ] 3.1 Write failing tests: selection parity — `--name` by id or name; auto-select single managed container; picker when multiple + TTY; `selection_required` when multiple + non-interactive; `container_not_found` when name matches nothing (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 3.2 Write failing tests: volume-mode stopped container is auto-started with a **bare** runtime start (no lifecycle hooks invoked) before config read; runtime start failure → structured error and no delete call (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 3.3 Write failing tests: strict read errors (`config_not_found`, `config_parse`) fail rebuild and the mock runtime records **no** delete/create/volume calls (old container untouched) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 3.4 Write failing tests: `hostRequirements` shortfall fails rebuild before delete (no delete call); unparseable/unknown keys same gate (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 3.5 Write failing tests: Features path — rosetta consent gate invoked when features non-empty; fetch/build failure fails before delete; derived tag `adev-{base}:{hash12}` reused (no `container build`) when material unchanged; `--skip-pull` suppresses pull (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 3.6 Implement Phase A in `RebuildCommand` (selection → stamps → volume auto-start → `ConfigReader` strict → resolve → hostRequirements preflight → FeatureGitEnsure.ensurePresent for volume mode → rosetta gate + Features fetch/build/reuse) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint — Phase A
- [ ] verify **rebuild auto-selects the single managed container**
- [ ] verify **rebuild interactive picker when multiple**
- [ ] verify **rebuild non-interactive multiple requires --name**
- [ ] verify **volume rebuild auto-starts stopped container bare before reading**
- [ ] verify **hostRequirements shortfall fails before delete**
- [ ] verify **features build failure fails before delete**
- [ ] verify **--skip-pull honored on rebuild**

---

## 4. Phase B — delete old, preserve volumes, create path

- [ ] 4.1 Write failing tests: identity preservation — delete is called exactly once for the OLD container name; new create uses the SAME name; labels come from the OLD container's label dict + updates ONLY for drift-eligible keys (never recomputed via `volumeModeLabels` from a fresh identity with the new config name), so bind labels `managed`/`workspace_mode`/`local_folder`/`config_file` and volume labels `git_url`/`workspace_volume` stay byte-identical while `config_hash` + derived labels (`workspace_folder`/`remote_user`/`config_volumes`) update; equal hash still recreates (no skip) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.2 Write failing tests: volume preservation — `*-ws` volume and config named volumes are NEVER deleted or recreated on rebuild (assert no `volume delete`/`volume create` on existing names; `ensureVolume` reuse status); same `*-ws` mounted on new container; no git clone / `git pull` invoked; newly declared config volume created (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.3 Write failing tests: create request parity — bind uses `CreateRequest.from` with preserved host workspace path; volume uses `CreateRequest.fromVolumeMode` with `enableSSHForward: true` only when `SSH_AUTH_SOCK` non-empty, `false` (and no failure) when absent (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.4 Write failing tests: volume-mode post-create — `FeatureGitEnsure.ensurePresent` injects `git:1` when config lacks git/common-utils (status line when injecting; no double-add); `ensureWorkspaceWritableByRemoteUser` runs only when effective `remoteUser` differs from stamped `devcontainer.remote_user` (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.5 Write failing tests: create-path hooks run in fresh-create order on the NEW container (onCreate → updateContent → postCreate → postStart); non-zero create-path hook → delete-on-fail of the NEW container + stderr warning that the old container was already removed; workspace/config volumes survive (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.6 Write failing tests: settings apply runs after create-path hooks and is NOT gated on `--vscode`; `--vscode` open success → extensions apply → postAttach gate (config then feature; non-zero postAttach fails command but KEEPS new container); open soft-fail → postAttach skipped, rebuild still succeeds (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 4.7 Implement Phase B in `RebuildCommand` (container-only delete old → `ensureVolume` list-then-reuse → create bind/volume → start → volume writable-if-changed → `LifecycleRunner.runCreatePath` → settings apply → `VSCodeOpen` + extensions + `applyPostAttachGate`) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [ ] 4.8 Extract/share `ensureWorkspaceWritableByRemoteUser` so `CloneCommand` and `RebuildCommand` use one implementation (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)

## Checkpoint — Phase B
- [ ] verify **bind rebuild keeps name and updates hash labels**
- [ ] verify **volume rebuild keeps name and workspace volume**
- [ ] verify **equal config hash still rebuilds**
- [ ] verify **rebuild preserves workspace volume data**
- [ ] verify **rebuild preserves config named volumes**
- [ ] verify **rebuild deletes only the old container**
- [ ] verify **rebuild does not re-clone or pull in the volume**
- [ ] verify **volume rebuild writable step runs only when remoteUser changed**
- [ ] verify **volume rebuild ssh forward only with agent**
- [ ] verify **create-path hook failure deletes the new container**
- [ ] verify **failure after delete deletes the new container and warns**

---

## 5. Output and exit parity

- [ ] 5.1 Write failing tests: success `--json` shape (bind) includes `outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder`; volume mode MAY include `gitUrl`/`workspaceVolume`; stdout pure (no progress lines) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 5.2 Write failing tests: human success lines match `up` style; failure exits non-zero with structured error on stderr and NO success JSON on stdout for `--json` invocations; `ADEVCONTAINER_QUIET=1` silences status (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 5.3 Implement result type, `--json` emission, and error-path mapping in `RebuildCommand` + dispatch (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [ ] 5.4 Run the full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)

## Checkpoint — output
- [ ] verify **rebuild --json success shape for bind**
- [ ] verify **rebuild --json success shape for volume mode**
- [ ] verify **rebuild failure exits non-zero with structured error**

---

## 6. Docs and final gate

- [ ] 6.1 [P] README: command table row for `rebuild`, quick-start note, forced-recreate + volume-preservation wording, `--vscode` gate parity, `--json` note (path: `README.md`)
- [ ] 6.2 [P] Help text: usage row + `printCommandHelp("rebuild")` consistent with README (selection, forced recreate, volume preservation, `--vscode`) (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [ ] 6.3 Run the full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)
- [ ] 6.4 Grep/regression: no path in rebuild code that deletes `*-ws` or config named volumes; no silent-nil config read left in rebuild flow; postAttach/extensions gating identical to up/clone call sites (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint — docs / suite
- [ ] verify README/help describe rebuild without parity overclaim
- [ ] verify `swift run adevcontainerTests` green for default (mocked) suite
- [ ] verify scenarios from change `spec.md` ADDED requirements covered by tests

---

## 7. Contract landing

- [ ] 7.1 Fold the MODIFIED deltas into `specs/managed-lifecycle.md` (selection table row + `-w` gate + forced-recreate note) (path: `specs/managed-lifecycle.md`)
- [ ] 7.2 Fold the MODIFIED deltas into `specs/core.md` (recreate/drift policy sentence + create-path matrix row) (path: `specs/core.md`)
- [ ] 7.3 Fold the MODIFIED deltas into `specs/clone.md` (freshness carve-out scoped to `clone`; rebuild reuse clause) (path: `specs/clone.md`)
- [ ] 7.4 Fold the MODIFIED deltas into `specs/vscode.md` (command list, postAttach policy consistency, rebuild scenarios) (path: `specs/vscode.md`)
- [ ] 7.5 Fold the MODIFIED deltas into `specs/features.md` (derived-tag reuse clause for rebuild) (path: `specs/features.md`)
- [ ] 7.6 Archive the change: move `specs/changes/rebuild/` to `specs/changes/archive/20260809-rebuild/`, marking tasks complete and referencing the landed contract locations (path: `specs/changes/archive/20260809-rebuild/`)

## Checkpoint — contract
- [ ] verify grep: `rebuild` appears in the selection table, create-path matrix, clone freshness carve-out, vscode command lists, and features reuse clause of the live specs
- [ ] verify archive directory `20260809-rebuild` exists with all four artifacts and completion status
- [ ] verify final `swift run adevcontainerTests` still green