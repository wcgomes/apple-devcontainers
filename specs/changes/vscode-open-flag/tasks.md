# Tasks: vscode-open-flag

Spec ref: `specs/changes/vscode-open-flag/`  
Design ref: `specs/changes/vscode-open-flag/design.md`  
Base contract: `specs/adevcontainer/spec.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root  

Assume Swift 6.x / SPM already available. Do **not** install VS Code or extensions as task steps. Test-first: write failing tests before implementation in each section. Mock the host `code` launcher so the default suite needs no real VS Code.

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

## 5. Docs and final gate

- [x] 5.1 [P] README: document `--vscode` on up/start/clone, host prereqs (VS Code + remote-containers + experimental Apple support), soft-fail, manual attach still valid, no full Dev Containers parity claim (path: `README.md`)
- [x] 5.2 [P] Confirm help text matches README prereq tone (path: `Sources/adevcontainer/AdevcontainerMain.swift`)
- [x] 5.3 Run full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)

## Checkpoint — docs / suite
- [x] verify README/help mention soft-fail and prereqs without parity overclaim
- [x] verify `swift run adevcontainerTests` green for default (mocked) suite
- [x] Grep: no hard-fail path that maps open failure to non-zero lifecycle exit solely due to `--vscode`

(End of file - total 88 lines)
