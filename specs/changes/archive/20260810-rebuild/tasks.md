# Tasks: rebuild

**Status note:** Implementation, recovery (mode-split bind + volume), docs, domain contract fold, and archive are **done**. Live non-TTY recovery E2E passed when gated (`ADEVCONTAINER_RECOVERY_E2E=1`); live TTY operator-validated 2026-08-10 (no automated TTY E2E). Landed contract: `specs/managed-lifecycle.md`, `specs/core.md`, `specs/clone.md`, `specs/vscode.md`, `specs/features.md`, light touch `specs/lifecycle-hooks.md`. User-facing: `README.md`, `CommandSurface` usage + `printCommandHelp("rebuild")`. Archive: `specs/changes/archive/20260810-rebuild/`.

Spec ref: `specs/changes/rebuild/`  
Design ref: `specs/changes/rebuild/design.md`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. Mock `AppleContainerRuntime`, the Features fetch/build boundary, and the VS Code launcher so the default suite needs no real `container` runtime, no network, and no VS Code install. Reuse existing fixtures (`Tests/Fixtures/smoke.json`, `lifecycle-hooks.json`, `features-node.json`, `features-local.json`) for rebuild tests; add no new fixtures unless a task says so.

## 1. ConfigReader extraction and strict semantics

- [x] 1.1 Write failing tests: strict bind-mode read resolves from labels `devcontainer.local_folder` + `devcontainer.config_file` via `ConfigResolver.resolve`; missing/empty label inputs or missing host file → `config_not_found`; parse/admission failure → `config_parse` (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [x] 1.2 Write failing tests: strict volume-mode read — exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename` from stamped `devcontainer.workspace_folder` (fallback `/workspaces`); `cat` failure or empty text → `config_not_found`; unparseable in-volume config → `config_parse` (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [x] 1.3 Write failing tests: best-effort mode returns nil (not throws) for the same missing-input cases, preserving today's `PostAttachConfigLoader` skip semantics (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [x] 1.4 Implement `ConfigReader` with strict/best-effort modes (path: `Sources/ADevContainerLib/Commands/ConfigReader.swift`)
- [x] 1.5 Verify `CLIErrorCode.configNotFound` (`config_not_found`) and `CLIErrorCode.configParse` (`config_parse`) already exist and are reused by the strict reader — no new CLIErrorCode cases are added (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [x] 1.6 Refactor `PostAttachConfigLoader.load`/`loadBindMode`/`loadVolumeMode` onto `ConfigReader` best-effort; keep public behavior identical (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`)
- [x] 1.7 Run the existing suite; confirm zero regressions from the refactor (path: `Tests/adevcontainerTests/`)

## Checkpoint — reader
- [x] verify **bind rebuild missing config file fails config_not_found before delete**
- [x] verify **volume rebuild unreadable config fails before delete**
- [x] verify **volume rebuild parse failure is config_parse**
- [x] verify postAttach-loader skip semantics unchanged (best-effort nil regression)

---

## 2. CLI surface

- [x] 2.1 Write failing tests: `rebuild` dispatch accepts `--name`, `--skip-pull`, `--vscode`, `--json`, and combination; omitted flags default off (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 2.2 Write failing tests: `-w <path>` on rebuild is a usage error (`-w is only valid for up`) via the existing global gate; unknown flag fails closed (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 2.3 Write failing tests: `printCommandHelp("rebuild")` prints rebuild help; main usage lists `rebuild` with flags (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 2.4 Implement dispatch `case "rebuild"` threading `--name`/`--skip-pull`/`--vscode`/`--json` into `RebuildOptions` (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 2.5 [P] Add usage row and `printCommandHelp("rebuild")` case (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 2.6 Wire a stub `RebuildCommand.run` returning success JSON (up-shape) so dispatch tests compile and fail only on asserted behavior (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint — CLI
- [x] verify **-w on rebuild is usage error**
- [x] verify **rebuild unknown flag fails closed**
- [x] verify `printCommandHelp("rebuild")` present and usage row lists rebuild

---

## 3. Phase A — selection, stamps, strict read, pre-delete gate

- [x] 3.1 Write failing tests: selection parity — `--name` by id or name; auto-select single managed container; picker when multiple + TTY; `selection_required` when multiple + non-interactive; `container_not_found` when name matches nothing (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 3.2 Write failing tests: volume-mode stopped container is auto-started with a **bare** runtime start (no lifecycle hooks invoked) before config read; runtime start failure → structured error and no delete call (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 3.3 Write failing tests: strict read errors (`config_not_found`, `config_parse`) fail rebuild and the mock runtime records **no** delete/create/volume calls (old container untouched) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 3.4 Write failing tests: `hostRequirements` shortfall fails rebuild before delete (no delete call); unparseable/unknown keys same gate (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 3.5 Write failing tests: Features path — rosetta consent gate invoked when features non-empty; fetch/build failure fails before delete; derived tag `adev-{base}:{hash12}` reused (no `container build`) when material unchanged; `--skip-pull` suppresses pull (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 3.6 Implement Phase A in `RebuildCommand` (selection → stamps → volume auto-start → `ConfigReader` strict → resolve → hostRequirements preflight → FeatureGitEnsure.ensurePresent for volume mode → rosetta gate + Features fetch/build/reuse) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint — Phase A
- [x] verify **rebuild auto-selects the single managed container**
- [x] verify **rebuild interactive picker when multiple**
- [x] verify **rebuild non-interactive multiple requires --name**
- [x] verify **volume rebuild auto-starts stopped container bare before reading**
- [x] verify **hostRequirements shortfall fails before delete**
- [x] verify **features build failure fails before delete**
- [x] verify **--skip-pull honored on rebuild**

---

## 4. Phase B — delete old, preserve volumes, create path

- [x] 4.1 Write failing tests: identity preservation — delete is called exactly once for the OLD container name; new create uses the SAME name; labels come from the OLD container's label dict + updates ONLY for drift-eligible keys (never recomputed via `volumeModeLabels` from a fresh identity with the new config name), so bind labels `managed`/`workspace_mode`/`local_folder`/`config_file` and volume labels `git_url`/`workspace_volume` stay byte-identical while `config_hash` + derived labels (`workspace_folder`/`remote_user`/`config_volumes`) update; equal hash still recreates (no skip) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.2 Write failing tests: volume preservation — `*-ws` volume and config named volumes are NEVER deleted or recreated on rebuild (assert no `volume delete`/`volume create` on existing names; `ensureVolume` reuse status); same `*-ws` mounted on new container; no git clone / `git pull` invoked; newly declared config volume created (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.3 Write failing tests: create request parity — bind uses `CreateRequest.from` with preserved host workspace path; volume uses `CreateRequest.fromVolumeMode` with `enableSSHForward: true` only when `SSH_AUTH_SOCK` non-empty, `false` (and no failure) when absent (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.4 Write failing tests: volume-mode post-create — `FeatureGitEnsure.ensurePresent` injects `git:1` when config lacks git/common-utils (status line when injecting; no double-add); `ensureWorkspaceWritableByRemoteUser` runs only when effective `remoteUser` differs from stamped `devcontainer.remote_user` (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.5 Write failing tests: create-path hooks run in fresh-create order on the NEW container (onCreate → updateContent → postCreate → postStart); non-zero create-path hook → delete-on-fail of the NEW container + stderr warning that the old container was already removed; workspace/config volumes survive (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.6 Write failing tests: settings apply runs after create-path hooks and is NOT gated on `--vscode`; `--vscode` open success → extensions apply → postAttach gate (config then feature; non-zero postAttach fails command but KEEPS new container); open soft-fail → postAttach skipped, rebuild still succeeds (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 4.7 Implement Phase B in `RebuildCommand` (container-only delete old → `ensureVolume` list-then-reuse → create bind/volume → start → volume writable-if-changed → `LifecycleRunner.runCreatePath` → settings apply → `VSCodeOpen` + extensions + `applyPostAttachGate`) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 4.8 Extract/share `ensureWorkspaceWritableByRemoteUser` so `CloneCommand` and `RebuildCommand` use one implementation (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)

## Checkpoint — Phase B
- [x] verify **bind rebuild keeps name and updates hash labels**
- [x] verify **volume rebuild keeps name and workspace volume**
- [x] verify **equal config hash still rebuilds**
- [x] verify **rebuild preserves workspace volume data**
- [x] verify **rebuild preserves config named volumes**
- [x] verify **rebuild deletes only the old container**
- [x] verify **rebuild does not re-clone or pull in the volume**
- [x] verify **volume rebuild writable step runs only when remoteUser changed**
- [x] verify **volume rebuild ssh forward only with agent**
- [x] verify **create-path hook failure deletes the new container**
- [x] verify **failure after delete deletes the new container and warns**

---

## 5. Output and exit parity

- [x] 5.1 Write failing tests: success `--json` shape (bind) includes `outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder`; volume mode MAY include `gitUrl`/`workspaceVolume`; stdout pure (no progress lines) (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 5.2 Write failing tests: human success lines match `up` style; failure exits non-zero with structured error on stderr and NO success JSON on stdout for `--json` invocations; `ADEVCONTAINER_QUIET=1` silences status (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 5.3 Implement result type, `--json` emission, and error-path mapping in `RebuildCommand` + dispatch (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 5.4 Run the full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)

## Checkpoint — output
- [x] verify **rebuild --json success shape for bind**
- [x] verify **rebuild --json success shape for volume mode**
- [x] verify **rebuild failure exits non-zero with structured error**

---

## 6. Docs and final gate

- [x] 6.1 [P] README: command table row for `rebuild`, quick-start note, forced-recreate + volume-preservation wording, `--vscode` gate parity, `--json` note; hash-mismatch → `rebuild` (not `--recreate`) (path: `README.md`)
- [x] 6.2 [P] Help text: usage row + `printCommandHelp("rebuild")` consistent with README (selection, forced recreate, volume preservation, `--vscode`); no `--recreate` in usage/`up` help (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)
- [x] 6.3 Run the full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 6.4 Grep/regression: no path in rebuild code that deletes `*-ws` or config named volumes; no silent-nil config read left in rebuild flow; postAttach/extensions gating identical to up/clone call sites (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 6.5 Remove obsolete `up --recreate`: delete flag from parser/`UpOptions`/`UpCommand`/help/usage; hash-mismatch fails with `config_hash_mismatch` hinting `adevcontainer rebuild` (managed selection); `--recreate` fails closed as unknown flag; tests cover mismatch hint + unknown flag (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`, `Sources/ADevContainerLib/Support/CommandSurface.swift`, `Sources/adevcontainer/AdevcontainerMain.swift`, `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint — docs / suite
- [x] verify README/help describe rebuild without parity overclaim
- [x] verify `swift run adevcontainerTests` green for default (mocked) suite
- [x] verify scenarios from change `spec.md` ADDED requirements covered by tests

---

## 7. Contract landing

- [x] 7.1 Fold the MODIFIED deltas into `specs/managed-lifecycle.md` (selection table row + `-w` gate + forced-recreate note) (path: `specs/managed-lifecycle.md`)
- [x] 7.2 Fold the MODIFIED deltas into `specs/core.md` (recreate/drift policy sentence + create-path matrix row) (path: `specs/core.md`)
- [x] 7.3 Fold the MODIFIED deltas into `specs/clone.md` (freshness carve-out scoped to `clone`; rebuild reuse clause) (path: `specs/clone.md`)
- [x] 7.4 Fold the MODIFIED deltas into `specs/vscode.md` (command list, postAttach policy consistency, rebuild scenarios) (path: `specs/vscode.md`)
- [x] 7.5 Fold the MODIFIED deltas into `specs/features.md` (derived-tag reuse clause for rebuild) (path: `specs/features.md`)
- [x] 7.6 Archive the change: move `specs/changes/rebuild/` to `specs/changes/archive/20260810-rebuild/`, marking tasks complete and referencing the landed contract locations (path: `specs/changes/archive/20260810-rebuild/`)

## Checkpoint — contract
- [x] verify grep: `rebuild` appears in the selection table, create-path matrix, clone freshness carve-out, vscode command lists, and features reuse clause of the live specs
- [x] verify archive directory `20260810-rebuild` exists with all four artifacts and completion status
- [x] verify final `swift run adevcontainerTests` still green

---

## 8. Recovery runtime and helper primitive

The recovery phases below are appended to preserve the existing checklist. They depend on the completed rebuild implementation phases above and MUST be completed before the existing section 7 contract-landing/archive tasks are executed; section 7 remains unchanged and unmarked.

- [x] 8.1 Write failing tests for clone-origin recovery eligibility: require managed `workspace_mode=volume` plus non-empty `git_url`, `workspace_volume`, and stamped `config_file`; bind and non-clone targets must be ineligible (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 8.2 Write failing tests for helper-image preflight: use one immutable Alpine arm64 reference with explicit `linux/arm64`; image unavailable must fail before old-container deletion and must not mutate volumes (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 8.3 Write failing tests for helper create/start: original container name and identity labels are retained, `devcontainer.recovery=adevcontainer` plus an opaque session marker are present, and exactly the existing `*-ws` volume is mounted read-write without config-volume or workspace-volume delete/create/populate calls (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 8.4 Write failing tests for failed-new-container detachment: a still-attached failed container blocks helper mount, while successful stop/delete plus runtime mount verification permits it (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 8.5 Implement the runtime helper API for image preflight, helper create/start, stdin exec, mount inspection, and detached-volume verification (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)
- [x] 8.6 Implement the recovery-helper primitive and immutable image/platform policy (path: `Sources/ADevContainerLib/Commands/RecoveryHelper.swift`)
- [x] 8.7 Add structured recovery error cases for unavailable, conflict, cancellation, and final verification failure without changing existing config error mappings (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)

## Checkpoint — helper primitive
- [x] verify **helper image is preflighted before deletion**
- [x] verify helper creation/start failure and attached-new-container failure return recovery-unavailable without deleting any volume
- [x] verify helper mounts the exact existing `*-ws` volume read-write and retains identity/name labels plus visible recovery marker

---

## 9. Secure config session and editor process

- [x] 9.1 Write failing tests for raw in-volume capture: exact bytes are retained before delete in a `0700` session directory with a `0600` file; raw content, temp path, and secrets are absent from labels/status payloads except the operator-facing command field (path: `Tests/adevcontainerTests/RecoveryConfigSessionTests.swift`)
- [x] 9.2 Write failing tests for hash/conflict handling: original/baseline/last-applied SHA-256 values are tracked, a changed volume hash produces a conflict file and no overwrite, and missing/symlinked/mode-insecure metadata fails closed (path: `Tests/adevcontainerTests/RecoveryConfigSessionTests.swift`)
- [x] 9.3 Write failing tests that edited bytes use the same strict volume-mode resolution rules and stamped workspace-folder basename as rebuild, not the private temp directory basename (path: `Tests/adevcontainerTests/RecoveryConfigSessionTests.swift`)
- [x] 9.4 Expose raw-byte capture from the shared strict volume reader without changing best-effort `PostAttachConfigLoader` behavior (path: `Sources/ADevContainerLib/Commands/ConfigReader.swift`)
- [x] 9.5 Implement secure recovery session metadata, SHA-256 baselines, conflict preservation, and secure cleanup (path: `Sources/ADevContainerLib/Commands/RecoveryConfigSession.swift`)
- [x] 9.6 Write failing tests for editor selection: first usable `$VISUAL`, then `$EDITOR`, `/usr/bin/nano`, `/usr/bin/vi`; unusable environment entries fall through; temp path is passed as a separate argument (path: `Tests/adevcontainerTests/RecoveryEditorTests.swift`)
- [x] 9.7 Write failing tests for editor outcomes: invalid resolution reopens without volume write, interrupt/EOF returns cancellation while retaining helper/session, and launch failure returns recovery-unavailable (path: `Tests/adevcontainerTests/RecoveryEditorTests.swift`)
- [x] 9.8 Implement ordered editor resolution and awaited TTY process handling (path: `Sources/ADevContainerLib/Commands/RecoveryEditor.swift`)
- [x] 9.9 Write failing tests for atomic write/readback: helper exec streams exact bytes to a same-directory temporary file, atomically renames, returns matching hash, never calls `container cp`, and cleans helper temp files on failure (path: `Tests/adevcontainerTests/RecoveryConfigSessionTests.swift`)
- [x] 9.10 Implement atomic in-helper write and readback through the runtime stdin/exec boundary (path: `Sources/ADevContainerLib/Commands/RecoveryConfigSession.swift`)
- [x] 9.11 Write failing tests for the shared TTY open-editor prompt (bind + volume): after structured failure on stderr, prompt `Open the recovery editor now? [Y/n]`; empty/Enter and y/Y/yes-class are affirmative; n/N/no-class, other non-yes, and EOF decline; editor MUST NOT launch before the prompt is answered; invalid-config reopen MUST NOT re-ask the open-editor prompt (path: `Tests/adevcontainerTests/RecoveryEditorTests.swift`)
- [x] 9.12 Write failing tests for TTY prompt defer: decline/EOF retains recovery state (volume: helper+temp; bind: host path + resume stamps), prints non-TTY-equivalent structured recovery details + exact `rebuild --name` retry, exits non-zero, and never launches an editor (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 9.13 Implement shared prompt line-read + classification (default Y) used by bind and volume TTY recovery entry; wire print-failure-then-prompt before any `RecoveryEditor` launch (path: `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift`)

## Checkpoint — session/editor
- [x] verify **editor selection follows the fixed precedence**
- [x] verify **safe atomic copy and readback protects the in-volume config**
- [x] verify **invalid config retries without writing an invalid file**
- [x] verify cancellation leaves a usable marked helper and secure temp session
- [x] verify **volume TTY recovery prints failure then prompts before editor**
- [x] verify **volume TTY decline or EOF defers with retained helper and retry instructions**
- [x] verify TTY open-editor prompt is shared for bind and volume and never runs under `--json` or non-TTY

---

## 10. Recovery orchestration and retry lifecycle

- [x] 10.1 Write failing tests for the eligible hard-failure matrix: new create failure, new start failure, and each of `onCreate`/`updateContent`/`postCreate`/`postStart` clean/verify the failed new container before helper creation and offer recovery only for clone-origin volume targets (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 10.2 Write failing tests for unchanged exclusions on the **volume** path and soft-fail matrix: non-clone volume hard failures keep old-removed warning/delete-new with no helper; settings/extension soft-fail, VS Code open soft-fail, and postAttach failure do not create a helper or editor session. Bind hard post-delete recovery is covered in §15 (not asserted absent here) (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 10.3 Write failing tests for TTY retry ordering: after affirmative open-editor prompt, valid edited bytes are validated, atomically written/read back through the helper, and only then does the recovery-aware rebuild read config; repeated hard failures replace the helper without deleting volumes and re-enter print-failure-then-prompt (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 10.4 Write failing tests for non-TTY and `--json`: no open-editor prompt and no editor process, helper/temp retained, structured failure includes identity/hash/session details and exact edit/retry/cleanup commands, and cleanup commands are container-only plus secure temp removal (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 10.5 Write failing tests for final verification: successful retry reads the edited hash/content through the final container before success; same-volume equivalence forbids a redundant post-success copy; final verification or helper/session cleanup failure returns structured recovery failure without volume deletion (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 10.6 Implement `RecoveryOrchestrator` eligibility, failed-container cleanup/verification, helper lifecycle, shared TTY open-editor prompt (print failure → `[Y/n]` → affirmative/defer), TTY/non-TTY branching, and retry state machine (path: `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift`)
- [x] 10.7 Integrate recovery preparation into Phase A and recovery-aware post-delete failure handling/retry selection into `RebuildCommand` without changing pre-delete ordering or image rollback semantics (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 10.8 Add final-container config readback and same-volume cleanup ordering after lifecycle success (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 10.9 Write failing tests that volume TTY affirmative path still completes one-flow write/retry after the prompt, and that volume TTY decline retains helper+session with non-TTY-equivalent instructions (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)

## Checkpoint — orchestration
- [x] verify **volume-only recovery session is offered for a hard create failure**
- [x] verify **volume TTY recovery prints failure then prompts before editor**
- [x] verify **volume TTY affirmative prompt opens editor then existing edit loop**
- [x] verify **volume TTY decline or EOF defers with retained helper and retry instructions**
- [x] verify **TTY recovery writes before retry and can complete in one flow**
- [x] verify **non-TTY and JSON recovery never prompt or edit**
- [x] verify **successful retry verifies final-container visibility before cleanup**
- [x] verify **soft failures and non-clone volume failures do not offer recovery**
- [x] verify **recovery preserves volumes and does not roll back workspace data**
- [x] verify bind hard post-delete recovery is deferred to §15 (not asserted absent in volume orchestration)

---

## 11. Recovery identity, selection, list, and prune behavior

- [x] 11.1 Write failing tests that a marked helper remains in managed discovery, is visibly marked in human/JSON `list`, is addressable by `exec --name`, and can be selected by `rebuild --name` with the original name (path: `Tests/adevcontainerTests/RecoverySelectionTests.swift`)
- [x] 11.2 Write failing tests that the original failure path does not delete the helper before a later named retry, while same-flow TTY retry may remove it only after temp write/readback and pre-delete checks (path: `Tests/adevcontainerTests/RecoverySelectionTests.swift`)
- [x] 11.3 Write failing tests that ordinary `prune` skips marked helpers and all referenced workspace/config volumes, while explicit container-only `delete --name` remains the reported cleanup path (path: `Tests/adevcontainerTests/RecoverySelectionTests.swift`)
- [x] 11.4 Implement recovery-aware rendering/filtering in managed selection/list and prune protection; preserve existing selection behavior for non-recovery containers (path: `Sources/ADevContainerLib/Support/ManagedContainers.swift`)
- [x] 11.5 Implement recovery marker display and prune skip behavior without changing ordinary delete volume semantics (path: `Sources/ADevContainerLib/Commands/ListCommand.swift`)
- [x] 11.6 Implement marked-helper/resource filtering in prune (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)

## Checkpoint — selection and safety
- [x] verify **recovery helper preserves identity and safe selection**
- [x] verify a later `rebuild --name` writes through the still-running helper before selecting replacement
- [x] verify ordinary prune cannot delete a recovery helper or any workspace/config named volume it references

---

## 12. Recovery errors and output/JSON contract

- [x] 12.1 Write failing tests for structured recovery-unavailable/conflict/cancelled/final-verification errors, including old-container-removed status and no success object on failure (path: `Tests/adevcontainerTests/RecoveryOutputTests.swift`)
- [x] 12.2 Write failing tests for human and JSON recovery details: helper id/name, recovery marker/session id, workspace volume, stamped config path, secure temp path, expected hash, failure kind, and shell-quoted edit/retry/cleanup commands; raw config and secrets never appear (path: `Tests/adevcontainerTests/RecoveryOutputTests.swift`)
- [x] 12.3 Implement recovery error payloads, command generation, stderr/human rendering, and JSON result integration while preserving pure stdout success JSON (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 12.4 Implement recovery result models and redacted command/detail serialization (path: `Sources/ADevContainerLib/Model/RebuildResult.swift`)

## Checkpoint — output
- [x] verify **non-TTY and JSON recovery never prompt or edit**
- [x] verify exact edit/retry/cleanup commands are executable and contain no volume delete or image rollback
- [x] verify recovery failures exit non-zero and never emit success JSON

---

## 13. Real Apple-container recovery E2E

- [x] 13.1 Write a real-runtime E2E test gated by explicit recovery E2E prerequisites that creates a clone-origin volume workspace, preserves a sentinel file/config named volume, and records the exact workspace/config labels (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 13.2 Write a real-runtime E2E test that makes a post-delete create-path hook fail after the old container is removed, asserts the failed container is cleaned, and verifies the helper image/platform, helper identity, exact `*-ws` read-write mount, and no workspace/config volume delete/recreate (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 13.3 Write a real-runtime non-TTY/JSON E2E test that edits the reported secure temp file, invokes the exact named retry, verifies the edited config is written before rebuild reads it, and confirms the final container sees the same bytes/hash (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 13.4 Write a real-runtime E2E test for helper visibility/prune protection and post-success helper/temp cleanup, including cleanup assertions when the test aborts (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 13.5 Register recovery E2E cases with the existing integration harness and skip only when explicit runtime, image, and host prerequisites are absent; never silently skip a requested recovery E2E run (path: `Tests/adevcontainerTests/main.swift`)
- [x] 13.6 Run mocked unit tests first, then the gated real Apple-container recovery E2E suite and verify no test leaves containers or volumes behind (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)

## Checkpoint — real recovery E2E
- [x] verify **helper image preflight, exact volume mount, safe write/readback, and final-container verification** against a real Apple container (gated non-TTY live E2E passed)
- [x] verify sentinel workspace/config-volume data survives every recovery retry and no image rollback is claimed
- [x] verify helper/temp cleanup succeeds after final verification and ordinary prune remains safe
- [x] note: automated live TTY E2E absent; TTY operator-validated 2026-08-10

---

## 14. Recovery contract review

- [x] 14.1 Cross-check every recovery scenario in `spec.md` against a unit or E2E test and its implementing task (path: `specs/changes/rebuild/spec.md`)
- [x] 14.2 Cross-check proposal, spec, design, and tasks for mode-split eligibility (volume helper vs bind host-editor), one shared hard-failure matrix, volume-only helper identity/list/prune rules, mode-appropriate retry ordering and cleanup policy; remove any stale “bind has no recovery” or “interactive editing is a non-goal” wording (path: `specs/changes/rebuild/design.md`)
- [x] 14.3 Run the full default suite and the explicitly enabled recovery E2E suite; report any unavailable Apple-container/image prerequisite as a concern rather than marking the contract complete (path: `Tests/adevcontainerTests/`)

## Checkpoint — recovery contract
- [x] verify no unresolved clarification markers remain in the four change artifacts
- [x] verify no recovery path deletes/recreates/repopulates workspace or config named volumes
- [x] verify archive/contract-landing authorized and completed (20260810)

---

## 15. Bind-mode recovery UX

Appended after volume recovery phases. Depends on shared editor/orchestrator plumbing from §§8–12 where present; MUST NOT invent a recovery helper for bind. Section 7 contract-landing/archive remains unmarked until separately authorized. Volume helper tasks (§§8–14) stay as-is except the §10.2 exclusion wording that defers bind hard failures here.

- [x] 15.1 Write failing tests for bind recovery eligibility: managed bind-mode stamps (`local_folder` + `config_file`, not `workspace_mode=volume`) are eligible for host-editor recovery after the shared hard-failure set; non-clone volume remains ineligible; pre-delete `config_not_found` / `config_parse` on bind never enters recovery and leaves the old container untouched (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 15.2 Write failing tests for the bind hard-failure matrix: new create, new start, and each of `onCreate`/`updateContent`/`postCreate`/`postStart` after old-container deletion clean the failed new container, emit old-removed warning, offer bind recovery, and never create a helper, never preflight Alpine for bind, never attach `devcontainer.recovery` labels, and never call volume mount/atomic helper write (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 15.3 Write failing tests for bind soft-fail exclusions: settings/extension soft-fail, VS Code open soft-fail, and postAttach fail-keep do not start bind recovery (parity with volume exclusions) (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 15.4 Write failing tests for bind TTY recovery: shared open-editor prompt runs after structured failure (default Y); on affirmative, shared editor precedence opens the **host stamped path** (`local_folder` + `config_file`) directly (not a private temp copy); invalid bind-mode strict validation reopens the editor without starting rebuild and without re-asking the open-editor prompt; valid edit retries `rebuild` reading that host path; editor cancel returns structured `recovery_cancelled` (or equivalent) with host path + `rebuild --name` retry and no helper cleanup (path: `Tests/adevcontainerTests/RecoveryEditorTests.swift`)
- [x] 15.5 Write failing tests for bind non-TTY and `--json`: no editor and no open-editor prompt; structured recovery details include host config path, failure kind, shell-quoted edit hint for the host path, and `adevcontainer rebuild --name <name>` retry; payload MUST NOT require helper identity, workspace volume, secure temp, or helper-delete cleanup commands (path: `Tests/adevcontainerTests/RecoveryOutputTests.swift`)
- [x] 15.6 Write failing tests that volume recovery path is unchanged when bind recovery exists: clone-origin volume hard failure still uses helper image preflight, secure temp, atomic write-back, list/prune helper protection, helper-delete cleanup, and the same print-failure-then-prompt TTY gate (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)
- [x] 15.7 Extend `RecoveryOrchestrator` mode classification and post-delete branch for bind host-editor recovery; share TTY open-editor prompt, TTY/non-TTY detection, and `RecoveryEditor` selection with volume; bind branch skips helper create/start/image preflight/session temp write-back (path: `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift`)
- [x] 15.8 Wire bind recovery into `RebuildCommand` post-delete failure handling without requiring Phase A helper preflight for bind targets (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 15.9 Extend recovery result/error models and human/JSON rendering for bind details (host path, no helper cleanup) while reusing existing recovery codes where applicable (`recovery_cancelled`, `recovery_unavailable`) (path: `Sources/ADevContainerLib/Model/RebuildResult.swift`)
- [x] 15.10 [P] Optional gated real-runtime coverage: bind postCreate hard failure non-TTY recovery details + named retry after host edit; TTY covered by manual/env gate guidance if automated TTY is unavailable (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 15.11 Cross-check §15 scenarios in `spec.md` (bind TTY print-then-prompt, bind affirmative host path, bind decline/EOF defer, bind non-TTY/JSON, bind pre-delete parse no recovery, volume path unchanged, no helper for bind) against tests and tasks (path: `specs/changes/rebuild/spec.md`)
- [x] 15.12 Write failing tests for bind TTY decline/EOF: after structured failure and open-editor prompt, n/N/no-class or EOF never launches an editor, retains host path/resume stamps, prints non-TTY-equivalent recovery details + `rebuild --name` retry, and exits non-zero (path: `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift`)

## Checkpoint — bind recovery UX
- [x] verify **bind TTY recovery after postCreate failure prints failure then prompts before editor**
- [x] verify **bind TTY affirmative prompt opens host stamped path**
- [x] verify **bind TTY decline or EOF defers with retained host path and retry instructions**
- [x] verify **bind non-TTY and JSON recovery never prompt or edit**
- [x] verify **bind pre-delete parse still no recovery**
- [x] verify **bind recovery does not create helper or recovery labels**
- [x] verify **volume recovery path unchanged when bind recovery exists**
- [x] verify bind cleanup/retry commands never mention helper delete
- [x] verify section 7 archive tasks completed
