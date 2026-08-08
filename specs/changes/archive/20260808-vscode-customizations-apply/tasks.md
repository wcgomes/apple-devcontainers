# Tasks: vscode-customizations-apply

Spec ref: `specs/changes/vscode-customizations-apply/`  
Design ref: `specs/changes/vscode-customizations-apply/design.md`  
Base contract: `specs/adevcontainer/spec.md`  
Prior archive: `specs/changes/archive/20260808-vscode-open-flag/`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root  

Assume Swift 6.x / SPM already available. Do **not** install VS Code or hit the real marketplace as task steps. Test-first: write failing tests before implementation in each section. Mock container exec, filesystem, and download so the default suite needs no real guest or network.

---

## 1. Parse model and identity exclusion (test-first)

- [ ] 1.1 Write failing tests: well-formed `customizations.vscode.extensions` (string IDs) and `settings` (object) are retained on resolve (path: `Tests/adevcontainerTests/VSCodeCustomizationsParseTests.swift`)
- [ ] 1.2 Write failing tests: malformed nested `extensions` (non-array) and `settings` (non-object) do not fail resolve; apply payloads empty/soft-skip (path: `Tests/adevcontainerTests/VSCodeCustomizationsParseTests.swift`)
- [ ] 1.3 Write failing tests: empty/absent customizations → no apply payload; non-object top-level `customizations` still fails resolve as today (path: `Tests/adevcontainerTests/VSCodeCustomizationsParseTests.swift`)
- [ ] 1.4 Write failing tests: `hashMaterial()` / config identity unchanged when only vscode customizations differ (path: `Tests/adevcontainerTests/VSCodeCustomizationsParseTests.swift`)
- [ ] 1.5 Extend resolved model fields for extensions + settings; keep or derive `hasVscodeCustomizations` (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [ ] 1.6 Parse/normalize in resolver (trim IDs; skip non-string entries with warn seam); resilient nested types (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [ ] 1.7 [P] Align admissions comments/policy with admit-object + no nested hard-fail (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [ ] 1.8 [P] Add fixtures for well-formed / bad nested / empty vscode customizations (path: `Tests/Fixtures/vscode-customizations-wellformed.json`)

## Checkpoint — parse
- [ ] verify **well-formed extensions and settings are retained**
- [ ] verify **malformed nested extensions does not fail resolve**
- [ ] verify **malformed nested settings does not fail resolve**
- [ ] verify **customizations stay outside create identity hash**
- [ ] verify **empty or absent vscode customizations**
- [ ] verify **customizations.vscode does not fail** (regression)
- [ ] verify **property surface admits vscode extensions and settings**

---

## 2. Apply helper: hash, marker, settings merge, extensions install (test-first)

- [ ] 2.1 Write failing tests: stable normalization + content hash for sorted extension IDs + canonical settings JSON (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`)
- [ ] 2.2 Write failing tests: marker match skips apply; marker missing/drift runs apply; marker written only on full-payload success rules from design (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`)
- [ ] 2.3 Write failing tests: settings merge creates Machine settings path, overlays keys, preserves unrelated keys; invalid existing JSON soft-fails without lifecycle throw (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`)
- [ ] 2.4 Write failing tests: extensions install skips already-present IDs; downloads/unpacks missing into extensions dir via mocks; one-ID failure warns and does not finalize marker (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`)
- [ ] 2.5 Write failing tests: all apply failures return soft-fail outcome (no throw that fails lifecycle); never requests container delete (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`)
- [ ] 2.6 Implement normalize/hash + marker read/write helpers (path: `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift`)
- [ ] 2.7 Implement settings merge via mockable guest exec/file API (path: `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift`)
- [ ] 2.8 Implement VSIX download+unpack (or equivalent) install via mockable seams (path: `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift`)
- [ ] 2.9 [P] Shared soft-fail warning helpers consistent with StatusPrinter norms (path: `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift`)

## Checkpoint — apply helper
- [ ] verify **matching marker skips re-apply** (unit)
- [ ] verify **hash drift re-applies** (unit)
- [ ] verify **not every open blindly reinstalls** (unit skip path)
- [ ] verify **settings soft-fail keeps lifecycle success** (helper outcome)
- [ ] verify **extensions soft-fail keeps lifecycle success** (helper outcome)
- [ ] verify settings path/merge semantics match design (`Machine/settings.json`)
- [ ] verify extensions dir layout match design (`~/.vscode-server/extensions`)

---

## 3. Wire settings on Up/Clone create-path and start/reuse repair (test-first)

- [ ] 3.1 Write failing tests: fresh `UpCommand` create-path with settings calls settings apply **after** create-path hooks and **without** requiring `--vscode` (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 3.2 Write failing tests: fresh `CloneCommand` create-path applies settings after hooks; soft-fail preserves clone success / no delete (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 3.3 Write failing tests: settings apply soft-fail does not fail `up`/`clone` and does not delete container (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 3.4 Write failing tests: `StartCommand` / up reuse with loadable config and marker drift attempts settings repair without `--vscode` (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 3.5 Ensure `PostAttachConfigLoader` (or successor) returns retained extensions/settings on bind and volume load paths (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`)
- [ ] 3.6 Wire settings apply after create-path hooks in UpCommand (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [ ] 3.7 Wire settings apply after create-path hooks in CloneCommand (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [ ] 3.8 Wire settings repair on StartCommand when config loaded and marker drift (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [ ] 3.9 Ensure settings apply is not invoked from Features/Dockerfile build paths (path: `Sources/ADevContainerLib/Features/`)

## Checkpoint — settings wiring
- [ ] verify **settings merge on fresh up create without --vscode**
- [ ] verify **settings merge on fresh clone create**
- [ ] verify **settings not gated on open success**
- [ ] verify **settings soft-fail keeps lifecycle success** (command level)
- [ ] verify **reuse/start repairs settings on marker drift**
- [ ] verify **features build path unchanged by customizations apply**

---

## 4. Wire extensions after open on finish/start (test-first)

- [ ] 4.1 Write failing tests: `UpCommand` with `--vscode` + open success + pending extensions calls extensions apply **after open** and **before** postAttach (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.2 Write failing tests: without `--vscode`, extensions not installed; with open soft-fail, extensions not installed (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.3 Write failing tests: extensions soft-fail preserves lifecycle success when postAttach absent/exits 0; container kept (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.4 Write failing tests: postAttach non-zero still fail-keep after extensions apply attempt (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.5 Write failing tests: matching marker skips extensions on subsequent `--vscode` open (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.6 Write failing tests: `StartCommand` and `CloneCommand` same open-gated extensions matrix (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [ ] 4.7 Wire UpCommand: after open success → extensions apply → postAttach (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [ ] 4.8 Wire CloneCommand: same post-open extensions then postAttach (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [ ] 4.9 Wire StartCommand: same post-open extensions then postAttach (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [ ] 4.10 Ensure extensions apply is never folded into `postAttachCommand` execution or create-path delete-on-fail (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)

## Checkpoint — extensions wiring
- [ ] verify **extensions install after successful --vscode open on up**
- [ ] verify **extensions skipped without --vscode**
- [ ] verify **extensions skipped when open soft-fails**
- [ ] verify **extensions soft-fail keeps lifecycle success** (command level)
- [ ] verify **start with --vscode applies pending extensions**
- [ ] verify **postAttach still fail-keep after extensions apply**
- [ ] verify **manual attach without flag does not apply extensions** (no CLI path without flag)
- [ ] verify **matching marker skips re-apply** / **not every open blindly reinstalls** (command level)
- [ ] verify **hash drift re-applies** (command level)
- [ ] verify **parseable vscode customizations are applied per policy**

---

## 5. Docs and final gate

- [x] 5.1 [P] README: document config-file `customizations.vscode` apply — settings on create-path (not gated on `--vscode`); extensions after successful `--vscode` open; registry upsert; extensionDependencies BFS; soft-fail; marker config-only; Reload Window; not image build; no full Dev Containers parity; manual attach without flag does not install extensions (path: `README.md`)
- [ ] 5.2 [P] Help text one-liner/cross-note consistent with README (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [ ] 5.3 Run full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)
- [ ] 5.4 Grep/regression: apply failures never map to lifecycle non-zero by themselves; postAttach fail-keep unchanged; customizations absent from identity hash; no postAttachCommand-as-apply vehicle
- [x] 5.5 [P] Spec/design delta: registry visibility MUST; transitive extensionDependencies MUST; tar-pipe + cache invalidate HOW; config-only marker hash (paths: `specs/changes/vscode-customizations-apply/{spec,design,proposal}.md`)
- [x] 5.6 [P] Wiki sync: architecture / gaps / cli-runtime-boundary / workspace fixture settings + lldb-dap via deps; index keywords (paths: `wiki/`)

## Checkpoint — docs / suite
- [x] verify **customizations apply does not claim IDE parity**
- [x] verify README/help describe settings vs extensions gates and soft-fail (README done; help text still 5.2)
- [ ] verify `swift run adevcontainerTests` green for default (mocked) suite
- [ ] verify scenarios from change `spec.md` ADDED/MODIFIED requirements covered by tests

(End of file)
