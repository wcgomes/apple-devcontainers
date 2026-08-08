# Design: vscode-open-flag

Lean HOW for the verified host open recipe and postAttach gate. Outcome contract lives in `spec.md`; this file encodes the URI/CLI technique and attach-hook ordering so implementers do not invent a second path.

## Approach

After a successful `up` / `start` / `clone`:

1. If `--vscode` is set: collect **container id**, **image ref**, and **folder** → build folder URI → resolve host `code` → invoke best-effort open.
2. **Open success** → then run postAttach (config + feature-contributed) via existing LifecycleRunner-style container exec (`failKeepContainer` policy).
3. **Open soft-fail / missing inputs** → warn on stderr; **skip** postAttach (status when any postAttach present); lifecycle success unchanged by open alone.
4. If `--vscode` is **absent**: no open; if any postAttach present → one skip status (`postAttach skipped (no attach hook)` or clearer); never execute postAttach.

Optional: write nameConfig JSON before open when cheap; ignore write failures (soft). nameConfig is not the attach gate.

**Alternatives rejected:** `open vscode://…` as primary (window reuse / weaker folder binding); extension UI attach-only authority (empty no-folder window); hard-fail on missing VS Code; re-reading raw `devcontainer.json` for folder; always-skip postAttach forever; running postAttach before open; waiting for VS Code Server ready / IDE-confirmed attach; delete-on-fail for postAttach.

## Significant decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Open binary | `code` CLI | Verified recipe; supports `--new-window --folder-uri` |
| Window | Always `--new-window` | Avoid reuse without folder context |
| Authority scheme | `apple-container` | Matches experimental Remote - Containers Apple support |
| Authority payload | Compact JSON `{"id","image"}` → UTF-8 → hex, no spaces | Verified extension contract |
| Folder in URI | Path appended after hex blob | Puts workspace in the window (avoids UI no-folder gap) |
| Image source | Inspect/create image field | Required by authority JSON; start has no UpResult |
| `code` lookup | `PATH` then `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`; MAY try Insiders | macOS product host |
| nameConfig | Optional write under Code globalStorage | Improves defaults; not required if folder is in URI |
| Process boundary | Mockable launcher protocol | Unit tests without real VS Code |
| JSON stdout | Unchanged on success | Open is side effect; warn/progress on stderr. postAttach fail → error path, no success JSON |
| CLI attach hook | Successful host `code` launch under `--vscode` | Practical gate without IDE IPC |
| postAttach order | After open success only | Spec: do not run postAttach before open when `--vscode` |
| postAttach exec | LifecycleRunner conventions | Config then `featurePostAttachCommands`; shell-vs-argv; `remoteUser` / workdir |
| postAttach failure | `failKeepContainer` | Container already up; VS Code may already be opening; contrast create-path delete-on-fail |
| Open soft-fail | Never fails lifecycle by itself; skips postAttach | Preserve soft open; do not run attach hooks without attach hook |
| Approximation | No wait for remote-ready | Non-goal; document in help/README |

## Flow

```text
lifecycle success (up | start | clone)
        │
        ▼
   --vscode? ──no──► postAttach present? ──yes──► status: skip (no attach hook)
        │                         │ no
        │                         ▼
        │                        done
        │ yes
        ▼
  resolve id + image + folder
    (result and/or inspect/labels;
     folder already product-resolved)
        │
   missing? ──► stderr warn (open soft-fail)
        │              │
        │              ▼
        │         postAttach present? ──yes──► status: skip (attach open did not succeed)
        │              │ no / after status
        │              ▼
        │         lifecycle success
        ▼
  build HEX = hex(utf8(compact JSON {"id","image"}))
  URI  = vscode-remote://apple-container+${HEX}${FOLDER}
        │
        ▼
  discover code (PATH → app bundle → optional insiders)
        │
    missing? ──► stderr warn ──► skip postAttach (as above) ──► lifecycle success
        │ found
        ▼
  exec: code --new-window --folder-uri URI
        │
    fail? ──► stderr warn ──► skip postAttach (as above) ──► lifecycle success
        │ ok  (open SUCCESS = CLI attach hook)
        ▼
  optional nameConfig write (MAY; soft-fail)
        │
        ▼
  postAttach present (config and/or features)?
        │ no ──► lifecycle success (unchanged JSON)
        │ yes
        ▼
  run postAttach via container exec
    (config postAttachCommand, then feature postAttach;
     shell-vs-argv; remoteUser; workdir)
        │
    non-zero? ──► structured error naming postAttach
        │              MUST NOT delete/stop container
        │              no success JSON / existing error path
        │              lifecycle FAIL
        │ ok
        ▼
  lifecycle success (unchanged JSON)
```

### URI contract (verified)

```text
vscode-remote://apple-container+<hex(utf8 compact JSON)><remoteWorkspaceFolder>
```

Compact JSON keys (stable order recommended for tests): `id`, `image`. Example open:

```bash
code --new-window --folder-uri "vscode-remote://apple-container+${HEX}${FOLDER}"
```

Where `FOLDER` is an absolute container path (e.g. `/workspaces/my-repo`). Do not URL-encode the entire URI ad hoc in ways that break the extension parser; follow the verified host recipe (folder path appended after the hex authority segment).

### postAttach execution (HOW)

- Reuse `LifecycleRunner.runIfPresent` (or equivalent) with **`failurePolicy: .failKeepContainer`**.
- Order: `config.postAttachCommand` then each of `config.featurePostAttachCommands` (labels like `postAttachCommand (feature)` / `postAttachCommand (feature N)` matching other stages).
- Replace always-skip `emitPostAttachSkipIfNeeded` with outcome-aware helpers:
  - skip no-hook when `--vscode` absent and any postAttach present;
  - skip open-did-not-succeed when `--vscode` and open soft-failed and any postAttach present;
  - run path only after open success.
- Wire after open in `UpCommand` / `StartCommand` / `CloneCommand` (same place open is invoked today). Commands that already shipped open without postAttach need this second step.
- Do **not** fold postAttach into `runCreatePath` / `runRestartPostStart` (wrong timing and wrong delete policy).

### nameConfig (optional)

Path pattern:

`~/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/<containerName>.json`

Payload shape: `workspaceFolder` + `remoteUser` from labels/results. Write failures are warnings only.

### Prereqs (document only)

- VS Code + `ms-vscode-remote.remote-containers`
- `dev.containers.experimentalAppleContainerSupport: true`
- Host `code` on PATH or standard app location
- postAttach after `--vscode` is CLI-initiated attach approximation — not IDE remote-ready confirmation

## Artifact changes

| Area | Nature |
|------|--------|
| `Sources/adevcontainer/AdevcontainerMain.swift` | Parse `--vscode`; pass into up/start/clone; help text (open + postAttach gate) |
| `Sources/ADevContainerLib/Commands/UpCommand.swift` | After success: optional open; on open success run postAttach; on open fail/skip status paths |
| `Sources/ADevContainerLib/Commands/StartCommand.swift` | Same gate after start/no-op running via inspect |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | Same gate after clone success |
| `Sources/ADevContainerLib/Commands/LifecycleRunner.swift` | postAttach run + outcome-aware skip (replace always-skip-only); `failKeepContainer` |
| `Sources/ADevContainerLib/Support/` (e.g. `VSCodeOpen.swift`) | URI builder, `code` discovery, mockable process launch, optional nameConfig; open result enum success/soft-fail for gate |
| `Sources/ADevContainerLib/Commands/InspectCommand.swift` / runtime inspect | Reuse for start path id/image/folder |
| `Tests/adevcontainerTests/` | URI unit tests; soft-fail open; postAttach run/skip/fail-keep-container; flag wiring with mocks |
| `README.md` / usage help | Flag, prereqs, soft-fail open, postAttach gating, approximation caveat, no full-parity claim |
