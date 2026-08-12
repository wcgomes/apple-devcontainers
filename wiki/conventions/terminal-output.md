# Convention: Terminal output presentation

Product host-terminal presentation: **StatusPrinter** + **TerminalStyle** + **SuccessPresentation**. Prefer StatusPrinter for product progress/warn/info; CLIError.formatted for human errors; SuccessPresentation for post-success digest/hints. Do not write product lines via raw `FileHandle.standardError` (**exception:** interactive prompts / **InteractivePicker** UI stay raw stderr — not QUIET-gated). Prescriptive contract: [specs/terminal-output.md](../../specs/terminal-output.md). Change archive: `specs/changes/archive/20260811-improve-terminal-logs/`.

## Channels (stderr vs stdout)

| Channel | Stream | Notes |
|---------|--------|--------|
| Phase / info / warn / human error | **stderr** | StatusPrinter / CLIError |
| Internal tool body (live tee) | **stderr** | Framed display; raw capture |
| User `exec` / interactive TTY | passthrough | **Not** tool-framed |
| Human success digest (`outcome: …`) | **stdout** | After `==> Ready`; indented (`up`/`clone`/`rebuild`) |
| `--json` success JSON | **stdout** | Pure machine payload (`up`/`clone`/`rebuild`/…) |

No verbose flag, product log files, spinners, or emoji/icon severity markers.

## StatusPrinter severities

| Kind | Monochrome shape | QUIET |
|------|------------------|-------|
| Phase | `==> <message>` optional white **item** via `status(_:item:)` | Silenced |
| Info | Indented; not `==> ` | Silenced |
| Warning | `warning: <message>` | **Emits** |
| Error (human) | `error: <message>` + optional `property:` / `hint:` | **Emits** |

- **Phase items:** prefer `StatusPrinter.status("Deleting container", item: id)` → blue head + bold white target. Fallback auto-split: trailing `(…)` or resource-like last token.
- **connectionHint** = info weight (not phase). Emitted by **SuccessPresentation** after success digest/JSON (not inside Up/Clone/Rebuild finish). Suppressed when originating command has `--vscode`.
- **Section spacing:** blank stderr line before each top-level phase except the first; no blank placeholders under QUIET; never blank-pad stdout JSON.
- Stable greppable prefixes (ANSI stripped): `==> `, `warning: `, `error: `.

## Post-success layout (human up/clone/rebuild)

```text
==> Ready
    outcome: success          # success value green when color on
    containerId: …
    …
    gitUrl: …                 # clone only
    workspaceVolume: …        # clone only

    Connect with: <cmd>       # label dim; command bold white
    Open in VS Code with: …
```

Order: Ready (stderr) → outcome digest (stdout, nestIndent) → blank + connection hints (stderr). With `--json`: Ready → pure JSON stdout → blank + hints. Start: ack print → blank + hints.

## Internal tool framing

Live-tee internal tools (hooks, Features build, clone populate `streamOutput: true`, other product non-interactive tees):

- Display: `    | ` + content
- Capture buffers **raw** (no `| ` on CLIError diagnostics)
- Line-buffered in ProcessRunner stream paths

**Do not frame:** user `adevcontainer exec`; InteractiveProcessRunner TTY inherit; StatusPrinter lines.

## QUIET matrix (`ADEVCONTAINER_QUIET=1`)

| Output | QUIET |
|--------|-------|
| Phase, info, connection hints | Silent |
| `warning: `, human `error: ` | Emit |
| Framed tool body | Emit |
| Interactive prompts / picker UI | Still usable (raw stderr) |
| JSON / human digest stdout | Unchanged |

## Managed container table (list + InteractivePicker)

**`ManagedContainerTable`** shared human layout for `list` (stdout) and **InteractivePicker** (stderr). Code: `ManagedContainerTable.swift`.

Columns (header dim `styleInfo`): **NAME STATE MODE GIT_URL**. Pad plain cells, then style (ANSI must not skew columns). Cell styles (color on): name `stylePhaseHead`; state `styleSuccess` when running else **`styleMuted`** (bold + 256 fg `245` — not weight-normal; distinct from header `styleInfo` dim); mode `styleCommand`; git plain default foreground (not dim, not bold). Recovery helpers append ` [RECOVERY]` on the name. Monochrome when color off; `list --json` monochrome.

| Surface | Stream | Lead column |
|---------|--------|-------------|
| Human `list` | stdout | none (`lead=0`) |
| Navigable picker | stderr | `" > "` when selected (`>` = `styleCommand`) / `"   "` else |
| Numbered picker | stderr | right-padded `"  N) "` |

Picker chrome (raw stderr, not StatusPrinter / not QUIET-gated): prompt `Select a container:`; navigable hint dim `styleInfo` (`↑/↓ move · Enter select · Esc cancel`). Keys/raw-mode: [cli-runtime-boundary — InteractivePicker](cli-runtime-boundary.md#interactivepicker-multi-container).

## Color (TerminalStyle)

Enable when stderr is a TTY and `NO_COLOR` unset. `FORCE_COLOR=1` may force; **`NO_COLOR` wins**. JSON monochrome.

| Kind | Typical (256-color) |
|------|---------------------|
| Phase head | Bold steel blue `75` |
| Phase item / commands | Bold default (white on dark) |
| Warning label only | Bold yellow `226`; body dim |
| Error label only | Bold red `196`; body dim |
| Error `hint:` line | Cyan `87` |
| Outcome `success` | Bold green `46` |
| Info / tool lines / table header | Dim (`styleInfo`) |
| Muted (non-running STATE) | Bold + 256 fg `245` (`styleMuted`; not weight-normal; not header dim) |

## Nomenclature (user-facing)

- Say **dev container** for the managed product container (not “workspace container”).
- Keep **workspace folder**, **workspace volume** (`*-ws`), `-w/--workspace` (host path on `up`) as technical terms.
- Example status: `==> Ensuring git feature for volume-mode dev container`, `==> Pruning dev container resources`.

## Agent / implementer rules

- Product lines → StatusPrinter (`item:` when there is a target).
- Post-success digest/hints → SuccessPresentation (entry point / StartCommand).
- Internal tees → framing on; user exec / interactive → off.
- Tests: monochrome by default (`colorOverride = false`); assert stable prefixes after strip-ANSI.
