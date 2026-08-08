# Design: vscode-open-flag

Lean HOW for the verified host open recipe. Outcome contract lives in `spec.md`; this file encodes the URI/CLI technique so implementers do not invent a second path.

## Approach

After a successful `up` / `start` / `clone` when `--vscode` is set:

1. Collect **container id** (create `--name` / managed id), **image ref** (create result or `runtime.inspect`), and **folder** (`remoteWorkspaceFolder` from result or `devcontainer.workspace_folder` label via inspect).
2. Build the Remote - Containers folder URI (below).
3. Resolve a host `code` executable.
4. Invoke best-effort: `code --new-window --folder-uri "<uri>"`.
5. On any discovery/launch failure: stderr warn; return lifecycle success unchanged.

Optional: write nameConfig JSON before open when cheap; ignore write failures (soft).

**Alternatives rejected:** `open vscode://…` as primary (window reuse / weaker folder binding); extension UI attach-only authority (empty no-folder window); hard-fail on missing VS Code; re-reading raw `devcontainer.json` for folder.

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
| JSON stdout | Unchanged | Open is side effect; warn/progress on stderr |

## Flow

```text
lifecycle success (up | start | clone)
        │
        ▼
   --vscode? ──no──► done (no open)
        │ yes
        ▼
 resolve id + image + folder
   (result and/or inspect/labels;
    folder already product-resolved)
        │
        ▼
 build HEX = hex(utf8(compact JSON {"id","image"}))
 URI  = vscode-remote://apple-container+${HEX}${FOLDER}
        │
        ▼
 discover code (PATH → app bundle → optional insiders)
        │
   missing? ──► stderr warn ──► lifecycle success
        │ found
        ▼
 exec: code --new-window --folder-uri URI
        │
   fail? ──► stderr warn ──► lifecycle success
        │ ok
        ▼
 optional nameConfig write (MAY; soft-fail)
        │
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

### nameConfig (optional)

Path pattern:

`~/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/<containerName>.json`

Payload shape: `workspaceFolder` + `remoteUser` from labels/results. Write failures are warnings only.

### Prereqs (document only)

- VS Code + `ms-vscode-remote.remote-containers`
- `dev.containers.experimentalAppleContainerSupport: true`
- Host `code` on PATH or standard app location

## Artifact changes

| Area | Nature |
|------|--------|
| `Sources/adevcontainer/AdevcontainerMain.swift` | Parse `--vscode`; pass into up/start/clone; help text |
| `Sources/ADevContainerLib/Commands/UpCommand.swift` | After success, optional open hook |
| `Sources/ADevContainerLib/Commands/StartCommand.swift` | After start/no-op running, optional open via inspect |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | After success, optional open hook |
| `Sources/ADevContainerLib/Support/` (new small module e.g. `VSCodeOpen.swift`) | URI builder, `code` discovery, mockable process launch, optional nameConfig |
| `Sources/ADevContainerLib/Commands/InspectCommand.swift` / runtime inspect | Reuse for start path id/image/folder |
| `Tests/adevcontainerTests/` | URI unit tests; soft-fail; flag wiring with mocks |
| `README.md` / usage help | Flag, prereqs, soft-fail, no full-parity claim |
