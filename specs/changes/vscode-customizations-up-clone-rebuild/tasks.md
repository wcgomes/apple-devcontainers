# Tasks: vscode-customizations-up-clone-rebuild

Spec ref: `specs/changes/vscode-customizations-up-clone-rebuild/`  
Base contract: union of `specs/<domain>.md` plus this change’s `spec.md`  
Tests: `Tests/adevcontainerTests/` (MiniTest; `swift run adevcontainerTests`)  
Package root: repository root

Test-first: write or flip the test, confirm it fails, then implement. Mock guest/download/open so the default suite needs no real container, marketplace, or VS Code. Change apply **wrappers** on `up` / `clone` / `rebuild` / `start` only — do not change Features/Dockerfile/image-build paths or the VSIX/registry/marker mechanism.

## 1. Failing tests — command gates

- [x] 1.1 Flip `upExtensionsSkippedWithoutVSCode` to expect guest extensions install (registry/unpack) on fresh `up` **without** `--vscode`; keep `upCreatePathAppliesSettingsWithoutVSCode`, `upExtensionsBeforeOpenBeforePostAttach`, and open/postAttach-only flag behavior (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 1.2 Add clone-without-`--vscode` extensions apply (and keep `cloneWithVSCodeAppliesExtensions` / `cloneCreatePathAppliesSettings`); add `up` reuse + `up` start-stopped expecting pending settings **and** extensions without `--vscode` (extend `upReuseRepairsSettingsOnMarkerDrift`); confirm matching-marker skip still holds (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 1.3 Flip `startWithVSCodeAppliesPendingExtensions` so `start --vscode` opens/postAttaches but applies **neither** settings nor extensions; extend `startWithoutVSCodeDoesNotInstallExtensions` so `start` without the flag also applies neither (no settings repair, marker unchanged) (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 1.4 Assert `CommandSurface.usage` and `commandHelpText` for `up` / `clone` / `start` / `rebuild` no longer say extensions are `--vscode`-gated; start help MUST say start does not apply settings or extensions (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 1.5 [P] Add rebuild-without-`--vscode` extensions apply (settings already covered by `rebuildSettingsApplyNotGatedOnOpen`); keep `rebuildVscodeExtensionsThenOpenThenPostAttach` order (apply → open → postAttach) (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)

## Checkpoint
- [x] verify **extensions install on fresh up without --vscode** fails on current flag gate
- [x] verify **extensions install on fresh clone without --vscode** encoded as a failing test
- [x] verify **extensions install on rebuild without --vscode** encoded as a failing test
- [x] verify **up reuse applies pending extensions without --vscode** and **up start-stopped applies pending extensions without --vscode** encoded as failing tests
- [x] verify **start never applies extensions**, **start with --vscode still does not apply extensions**, **start never applies settings**, and **start with --vscode still does not apply settings** encoded as failing tests
- [x] verify **--vscode still only gates open and postAttach on up** remains encoded (`upExtensionsBeforeOpenBeforePostAttach` / postAttach skip without flag)

## 2. Implement apply wrappers (not Features/build)

- [x] 2.1 Ungate `applyExtensionsIfNeeded` in `UpCommand.finish` (always when payload pending; not `if options.openVSCode`); reuse and start-stopped already call `finish` after settings — they MUST pick up extensions without a Features/build change (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 2.2 [P] Ungate `applyExtensionsIfNeeded` after create-path hooks in CloneCommand (same order: settings, extensions, optional open, postAttach) (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 2.3 [P] Ungate `applyExtensionsIfNeeded` in `RebuildCommand.finish` (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 2.4 [P] Remove `applySettingsIfNeeded` and `applyExtensionsIfNeeded` from `StartCommand.openAndPostAttach`; keep inspect/config load for open + postAttach only; do **not** add `postStartCommand` (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)

## Checkpoint
- [x] verify **extensions install on fresh up without --vscode**
- [x] verify **extensions install on fresh clone without --vscode**
- [x] verify **extensions install on rebuild without --vscode**
- [x] verify **extensions still apply on up when --vscode is set**
- [x] verify **up reuse applies pending extensions without --vscode**
- [x] verify **up start-stopped applies pending extensions without --vscode**
- [x] verify **up reuse still applies customizations** and **up start-stopped still applies customizations**
- [x] verify **settings merge on fresh up create without --vscode** (regression)
- [x] verify **start never applies extensions**
- [x] verify **start with --vscode still does not apply extensions**
- [x] verify **start never applies settings**
- [x] verify **start with --vscode still does not apply settings**
- [x] verify **--vscode on start still opens without applying customizations**
- [x] verify **--vscode still only gates open and postAttach on up**
- [x] verify **matching marker skips re-apply** and **hash drift re-applies on up without --vscode**
- [x] verify **start does not finalize or consume apply via marker**
- [x] verify **extensions apply is not image build** (no Features/Dockerfile edits)

## 3. Help and README

- [x] 3.1 Rewrite usage + per-command `--vscode` help: apply is default on `up` / `clone` / `rebuild` (including `up` reuse / start-stopped); `--vscode` is open + postAttach only; `start` never applies settings or extensions (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)
- [x] 3.2 [P] Update the Visual Studio Code integration section so `--vscode` is open-only and apply-on-`up`/`clone`/`rebuild` is stated; do not claim flag-gated extensions (path: `README.md`)

## Checkpoint
- [x] verify **customizations apply does not claim IDE parity**
- [x] verify help/usage no longer describe a `--vscode` gate for extensions
- [x] verify **without --vscode behavior unchanged for open**
