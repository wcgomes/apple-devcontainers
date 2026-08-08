# Tasks: vscode-open-flag

Spec ref: `specs/changes/vscode-open-flag/`  
Design ref: `specs/changes/vscode-open-flag/design.md`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root  

Assume Swift 6.x / SPM already available. Do **not** install VS Code or extensions as task steps. Test-first: write failing tests before implementation in each section. Mock the host `code` launcher so the default suite needs no real VS Code.

**Status note:** All sections complete. Open flag, best-effort VS Code open, gated postAttach, docs, and suite verification are **done**. Change archived into the live contract (now feature-scoped under `specs/`; union of `specs/<domain>.md`, VS Code requirements in `specs/vscode.md`).

---

## 1. URI builder and open inputs

- [x] 1.1 Write failing tests: compact JSON `{"id","image"}` → UTF-8 → hex; folder appended; full `vscode-remote://apple-container+…` shape stable (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 1.2 Write failing tests: folder source uses provided resolved path only (including product default `/workspaces/<basename>`); empty/missing folder is rejected or warned per design without inventing from raw JSON (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 1.3 Implement URI builder pure helpers (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)

## Checkpoint — URI
- [x] verify unit coverage for authority hex + folder append (design URI contract)
- [x] verify **omitted workspaceFolder uses product default already resolved** (builder receives resolved default; no raw JSON re-parse)

---

## 2. Host `code` discovery and mockable launcher

- [x] 2.1 Define mockable launcher / process boundary for invoking `code` (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)
- [x] 2.2 Write failing tests: discovery order PATH then standard macOS app `code` path; optional insiders attempt (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 2.3 Write failing tests: missing `code` → soft-fail result (no throw that fails lifecycle); launch failure → soft-fail result (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 2.4 Write failing tests: successful open invokes `code --new-window --folder-uri <uri>` exactly once with expected argv shape (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 2.5 Implement discovery + best-effort launch + stderr warn helpers (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)
- [x] 2.6 [P] Optional: nameConfig write helper (soft-fail on error) (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)

## Checkpoint — launcher
- [x] verify **soft-fail when code CLI missing**
- [x] verify **soft-fail when launch fails**
- [x] verify successful path uses `--new-window --folder-uri` (design)

---

## 3. CLI flag surface

- [x] 3.1 Write failing tests: `--vscode` accepted on `up`, `start`, `clone` parse path; omitted → open not requested (path: `Tests/adevcontainerTests/`)
- [x] 3.2 Write failing tests: `--json` + `--vscode` still produce unchanged success JSON shape for up/clone (stdout); open side effect does not write to stdout (path: `Tests/adevcontainerTests/`)
- [x] 3.3 Parse `--vscode` into flags and thread into command options (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 3.4 [P] Update usage/help strings for `--vscode` on up/start/clone + prereq one-liner (path: `Sources/adevcontainer/AdevcontainerMain.swift`)

## Checkpoint — flags
- [x] verify **without --vscode behavior unchanged** (no launcher call)
- [x] verify **--json works with --vscode**

---

## 4. Wire open after up / clone / start

- [x] 4.1 Write failing tests: `UpCommand` with `--vscode` after success calls open with container id, image, `remoteWorkspaceFolder` from result; lifecycle success if open soft-fails (path: `Tests/adevcontainerTests/`)
- [x] 4.2 Write failing tests: `CloneCommand` with `--vscode` after success calls open with clone result fields; soft-fail preserves success JSON (path: `Tests/adevcontainerTests/`)
- [x] 4.3 Write failing tests: `StartCommand` with `--vscode` after start/already-running resolves id/image/folder via inspect/labels and calls open; soft-fail preserves start success (path: `Tests/adevcontainerTests/`)
- [x] 4.4 Write failing tests: explicit resolved `workspaceFolder` (e.g. `/custom/ws`) is passed through on up/clone open (path: `Tests/adevcontainerTests/`)
- [x] 4.5 Extend up options + invoke open after successful `UpResult` (image from create/inspect as needed) (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 4.6 Extend clone options + invoke open after successful `CloneResult` (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 4.7 Extend `StartOptions` + invoke open after start/no-op using inspect payload (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 4.8 Ensure image ref for URI comes from inspect/create result fields (reuse `InspectCommand` / runtime inspect; do not invent) (path: `Sources/ADevContainerLib/Commands/`)

## Checkpoint — command wiring
- [x] verify **up with --vscode opens editor on remote workspace folder**
- [x] verify **start with --vscode opens after managed start**
- [x] verify **clone with --vscode opens after volume-mode create**
- [x] verify **explicit workspaceFolder is honored for open**
- [x] verify **soft-fail when code CLI missing** (end-to-end command level)
- [x] verify **soft-fail when launch fails** (end-to-end command level)
- [x] verify **Running container is attachable target** (regression: list/inspect unchanged)
- [x] verify **Optional open does not replace manual attach**

---

## 5. Docs and final gate (open path)

- [x] 5.1 [P] README: document `--vscode` on up/start/clone, host prereqs (VS Code + remote-containers + experimental Apple support), soft-fail, manual attach still valid, no full Dev Containers parity claim (path: `README.md`)
- [x] 5.2 [P] Confirm help text matches README prereq tone (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 5.3 Run full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)

## Checkpoint — docs / suite (open)
- [x] verify README/help mention soft-fail and prereqs without parity overclaim
- [x] verify `swift run adevcontainerTests` green for default (mocked) suite
- [x] Grep: no hard-fail path that maps open failure to non-zero lifecycle exit solely due to `--vscode`

---

## 6. postAttach gate — LifecycleRunner and open result (test-first)

- [x] 6.1 Write failing tests: open result distinguishes **success** vs **soft-fail** (missing code, launch fail, missing id/image/folder) so callers can gate postAttach (path: `Tests/adevcontainerTests/`)
- [x] 6.2 Write failing tests: `LifecycleRunner` (or successor helper) runs config `postAttachCommand` then `featurePostAttachCommands` via exec with `failKeepContainer`; labels match other feature stages (path: `Tests/adevcontainerTests/`)
- [x] 6.3 Write failing tests: skip helpers — no attach hook status when `--vscode` absent and postAttach present; open-did-not-succeed skip when open soft-failed and postAttach present; **no** skip line when postAttach absent (path: `Tests/adevcontainerTests/`)
- [x] 6.4 Write failing tests: postAttach non-zero → structured error naming postAttach; container **not** deleted (path: `Tests/adevcontainerTests/`)
- [x] 6.5 Ensure open path returns a success/soft-fail outcome usable by commands (extend `VSCodeOpen` / launcher result if needed) (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)
- [x] 6.6 Implement `runPostAttach` (config then features, `failKeepContainer`) and replace always-skip-only `emitPostAttachSkipIfNeeded` with outcome-aware skip/run API (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)

## Checkpoint — postAttach runner
- [x] verify **Invalid postAttach form still fails resolve** (regression; unchanged)
- [x] verify unit-level run order config → feature postAttach
- [x] verify fail-keep-container on non-zero postAttach
- [x] verify **no skip line when postAttach absent**

---

## 7. Wire postAttach after successful open on up / start / clone

- [x] 7.1 Write failing tests: `UpCommand` with `--vscode` + open success + `postAttachCommand` exits 0 → postAttach exec after open; success JSON unchanged (path: `Tests/adevcontainerTests/`)
- [x] 7.2 Write failing tests: `UpCommand` without `--vscode` + postAttach present → skip status, no exec, success (path: `Tests/adevcontainerTests/`)
- [x] 7.3 Write failing tests: `UpCommand` with `--vscode` + open soft-fail + postAttach present → no postAttach exec; lifecycle success; skip status SHOULD explain open did not succeed (path: `Tests/adevcontainerTests/`)
- [x] 7.4 Write failing tests: `UpCommand` with `--vscode` + open success + postAttach non-zero → command fails naming postAttach; container kept; no success JSON (path: `Tests/adevcontainerTests/`)
- [x] 7.5 Write failing tests: feature-contributed postAttach runs after config on open success; feature non-zero fails keep-container (path: `Tests/adevcontainerTests/`)
- [x] 7.6 Write failing tests: same gate matrix for `StartCommand` and `CloneCommand` (run after open success; skip without flag; skip on open soft-fail; fail keep container) (path: `Tests/adevcontainerTests/`)
- [x] 7.7 Wire UpCommand: after open outcome, run or skip postAttach per design (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 7.8 Wire CloneCommand: same postAttach gate after open (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 7.9 Wire StartCommand: same postAttach gate after open (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 7.10 Ensure postAttach is **not** invoked from `runCreatePath` / `runRestartPostStart` and is never ordered before open when `--vscode` (path: `Sources/ADevContainerLib/Commands/`)

## Checkpoint — postAttach command wiring
- [x] verify **postAttach runs after successful --vscode open**
- [x] verify **postAttach skipped without --vscode**
- [x] verify **postAttach skipped when open soft-fails**
- [x] verify **postAttach failure fails command but keeps container**
- [x] verify **feature postAttach runs after successful open**
- [x] verify open soft-fail still never fails lifecycle **by itself**
- [x] verify start/clone parity with up for the gate

---

## 8. Docs and final gate (postAttach delta)

- [x] 8.1 [P] README: document that `postAttachCommand` runs only after successful `--vscode` open; skipped without flag or when open soft-fails; failure fails the command but keeps the container; CLI-initiated attach approximation (not IDE remote-ready) (path: `README.md`)
- [x] 8.2 [P] Help text: one-liner or cross-note consistent with README postAttach gate (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 8.3 Run full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 8.4 Grep/regression: always-skip-only postAttach path removed for `--vscode` success; open soft-fail still non-fatal by itself; postAttach fail does not delete container

## Checkpoint — docs / suite (postAttach)
- [x] verify README/help describe gated postAttach + approximation caveat without parity overclaim
- [x] verify `swift run adevcontainerTests` green for default (mocked) suite
- [x] verify scenarios from change `spec.md` MODIFIED postAttach policy covered by tests

(End of file)
