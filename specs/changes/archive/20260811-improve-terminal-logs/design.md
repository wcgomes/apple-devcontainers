# Design: improve-terminal-logs

Lean HOW for terminal progress and log presentation. Outcome contract lives in `spec.md`; this file encodes facade boundaries, tee framing, color policy, and call-site migration so implementers do not invent a second quiet/json/tool-prefix policy.

## Approach

Expand the existing stderr StatusPrinter into a small presentation stack and apply it everywhere product-owned lines and internal tool tees hit the host terminal:

1. **`TerminalStyle`** — single policy object for color enablement (stderr TTY, `NO_COLOR`, `FORCE_COLOR=1`), monochrome vs ANSI wrappers, and shared indent/prefix constants (`==> `, `warning: `, `error: `, tool `| `).
2. **`StatusPrinter` facade** — phase (`status`), quieter `info`, `warning`, human error helpers, `connectionHint` at info weight, and **section spacing** (blank line before top-level phase except the first). All product progress/warn/info call-sites migrate here (or thin wrappers).
3. **Line-buffered tee in `FoundationProcessRunner`** — when streaming internal tool output to host stderr, split on newlines (carry partial line), write each completed display line as indent + `| ` + content; accumulate **raw** bytes unchanged into capture buffers for diagnostics.
4. **`AppleContainerRuntime` inherits** — `streamOutput` / `streamStderr` paths used by lifecycle hooks, Features build, and clone populate pass through the framing tee; interactive runner and user `exec` do not enable tool framing.
5. **CLIError human presentation** — keep `formatted()` shape (`error: …`, indented property/hint); apply color via TerminalStyle when enabled; JSON path stays structured monochrome bytes.
6. **Clone populate** — `runtime.exec(..., streamOutput: true)` (or equivalent) on in-container git clone populate so tool output live-streams like hooks/build.
7. **Full call-site migration** — replace direct `FileHandle.standardError` / ad hoc `print` product progress writers in up/clone/rebuild/features/lifecycle/vscode/mount/recovery/prompts/prune with StatusPrinter/TerminalStyle; leave true user-facing stdout success digests and user exec passthrough alone.

**Alternatives rejected:** emoji/icon severity markers (locked non-goal); spinners/progress bars (noise, hard to test); verbose flag / log levels (scope creep); writing tool body unframed (fails scanability); framing user `exec` (breaks mental model of “my command”); prefixing captured diagnostic strings on CLIError (breaks raw fidelity and secret-redaction simplicity); quiet silencing warnings/tool body (breaks operator trust); color without NO_COLOR respect; blank lines on stdout JSON.

## Significant decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Product phase prefix | Keep `==> ` | Stable for tests/specs; greppable |
| Tool frame | `\| ` + consistent indent under phase | Distinct from product; minimal; no icons |
| Warning / error prefixes | Keep `warning: ` and `error: ` | Stable automation/tests |
| Connection hints | Info weight (not `status`/`==>`) | Reduce false “phase” noise after Ready |
| QUIET | Progress + info only | Warnings/errors/tool/prompts always visible |
| Streams | stderr = progress/warn/tool/human error; stdout = JSON/digests | Existing JSON purity contract |
| Color default | On when stderr isatty and `NO_COLOR` unset | Common CLI convention |
| FORCE_COLOR | `FORCE_COLOR=1` may force on | CI/script opt-in; `NO_COLOR` wins |
| Tee unit | Line-buffered frame | Avoid splitting ANSI/mid-line; readable sections |
| Capture buffers | Raw, unframed | CLIError diagnostics + redaction stay simple |
| User exec | No tool framing; interactive TTY inherit unchanged | User owns that stream |
| Clone populate | `streamOutput: true` + frame | Parity with hooks/build visibility |
| Section spacing | Blank line before non-first top-level phase | Scan long up/clone/rebuild logs |
| Facade | StatusPrinter + TerminalStyle, not a new logging framework | Small surface; matches existing call sites |
| Migration | Full product writers | Avoid half-styled CLI |
| Non-goals | No verbose, log files, spinners, emojis | Locked product decisions |

## Presentation rules (concrete)

### Prefixes and indent

```text
==> Resolving configuration
==> Running postCreateCommand (feature 1)    # item may be white
    | npm install
    | added 12 packages
warning: skipped docker-outside-of-docker … # label yellow; body dim
error: postCreateCommand exited 1           # label red; body dim
  property: postCreateCommand                 # dim
  hint: …                                     # cyan

==> Ready
    outcome: success                          # stdout; success green
    containerId: …
    …

    Connect with: adevcontainer exec …        # label dim; command bold white
```

Phase targets: prefer `StatusPrinter.status("Running", item: property)`. Connection hints via `SuccessPresentation` after outcome/JSON (not inside command finish before digest).

### Color map (when enabled)

| Kind | Typical styling |
|------|-----------------|
| Phase head | Bold steel blue (256 `75`) |
| Phase item / copy-paste commands | Bold default (white on dark) |
| Info | Dim |
| Warning label only | Bold yellow (256 `226`); body dim |
| Error label only | Bold red (256 `196`); body dim |
| Error `hint:` | Cyan (256 `87`) |
| Outcome `success` | Bold green (256 `46`) |
| Tool `| ` lines | Dim |

Strip-ANSI of any colored line MUST preserve the monochrome prefix + message text.

### Color policy algorithm

```text
func colorEnabled(stderrIsTTY, env):
  if env[NO_COLOR] is set (key present): return false
  if env[FORCE_COLOR] == "1": return true
  return stderrIsTTY
```

Tests inject style/policy seams (isatty stub, env) so default unit suite does not require a real TTY.

### Section spacing

StatusPrinter tracks `hasEmittedPhase` per process (static/facade state, resettable in tests). On `status`/`phase`:

- If `hasEmittedPhase` and not QUIET: write `\n` then the phase line.
- Else: write the phase line only.
- Set `hasEmittedPhase = true` when a phase line is actually emitted (not when QUIET suppresses).

### QUIET matrix

| Output | QUIET=1 |
|--------|---------|
| `==> ` phase | Silent |
| Info / connection hints | Silent |
| `warning: ` | Emit |
| `error: ` human | Emit |
| Framed tool body | Emit |
| Interactive prompts | Emit / still read stdin |
| JSON stdout | Unchanged (still pure) |

## Process tee framing

### StreamTeeingProcessRunning

Extend the streaming run path used today (`streamStderr`, `teeStdoutToStderr`) so host display goes through a **line framer**:

```text
onByteChunk(stream):
  captureBuffer.append(raw chunk)          # never framed
  displayBuffer.append(chunk)
  while let line = displayBuffer.popLine(): # split on \n; keep remainder
    hostStderr.write(frame(line) + "\n")
onEOF:
  if displayBuffer has partial line without trailing \n:
    hostStderr.write(frame(partial) + "\n")  # or write partial without forced newline if raw had none — prefer complete line + newline for terminal readability
```

`frame(line)` = `toolIndent + "| " + line` (if line already has trailing `\r`, normalize conservatively; do not double-prefix).

**Do not frame** when:

- Interactive runner / TTY inherit path
- User `ExecCommand` non-internal passthrough (no streamOutput framing flag)
- Capture-only runs (`streamStderr: false`, `teeStdoutToStderr: false`)

### AppleContainerRuntime

- Lifecycle hooks: already `streamOutput: true` → framing on.
- Features build invoke: existing `streamStderr: true` (and stdout tee if any) → framing on.
- Clone populate exec: set `streamOutput: true` → framing on.
- User `exec` command path: leave streaming/passthrough without tool frame flag.
- Interactive exec: unchanged InteractiveProcessRunner.

### CLIError diagnostics

When attaching subprocess stdout/stderr snippets to messages or recovery text, use **capture buffers** (raw). Never re-read framed host display. Human `formatted()` may color the `error:` line; property/hint stay indented ASCII.

## Call-site migration map

| Area | Today | Target |
|------|-------|--------|
| `StatusPrinter` | `==> ` / `warning: ` / detail / connectionHint as status | + TerminalStyle colors; info; section spacing; connectionHint → info |
| `FoundationProcessRunner` | Raw tee chunks to stderr | Line-buffer + tool frame on stream paths |
| `AppleContainerRuntime` | streamOutput / streamStderr | Pass framing; populate + hooks + build |
| `LifecycleRunner` | streamOutput true | Unchanged flag; framing inherited |
| `CloneCommand.populateInContainer` | exec capture default | streamOutput true |
| `CLIError` / `CLIErrorOutput` | monochrome formatted | Color when policy allows; JSON unchanged |
| `UpCommand` / `RebuildCommand` / `StartCommand` | connectionHint via status | info weight |
| `PruneCommand` and similar | mix of StatusPrinter + print | Product progress → StatusPrinter; user-facing result digests may stay stdout print where they are success summaries (not progress) — do not move JSON/digest stdout to stderr |
| Mount / ownership warnings | StatusPrinter.warning or raw | StatusPrinter.warning |
| Recovery prompts / structured failure print | writeError closures | Ensure failure text uses CLIError formatting; prompts stay visible under QUIET |
| `AppleContainerConfig` consent messages | raw stderr | StatusPrinter phase/info as appropriate |
| `ManagedContainers` picker prompts | writeError | Remain prompts (not QUIET-silenced progress) |
| Features warn-skip | StatusPrinter.warning | Unchanged semantics; color optional |
| VS Code soft-fail warnings | StatusPrinter.warning | Unchanged semantics |

**Stdout `print` success digests** (`Deleted …`, `Started …`, human key/value up results without `--json`) are not progress tees; leave on stdout unless an existing spec already required stderr. Do not reclassify them as tool lines.

## Artifact changes (key Swift files)

| Path | Change |
|------|--------|
| `Sources/ADevContainerLib/Support/TerminalStyle.swift` | **New** — color policy, ANSI helpers, prefix/indent constants, test seams |
| `Sources/ADevContainerLib/Support/StatusPrinter.swift` | Expand facade: info, spacing, style integration, connectionHint weight |
| `Sources/ADevContainerLib/Runtime/ProcessRunner.swift` | Line-buffer framer on stream tee; raw capture preserved |
| `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift` | Ensure stream paths use framer; no frame on interactive/user exec |
| `Sources/ADevContainerLib/Errors/CLIError.swift` | Optional color in `formatted()` / output helper |
| `Sources/ADevContainerLib/Commands/LifecycleRunner.swift` | Rely on framed streamOutput (verify only) |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | populate `streamOutput: true`; StatusPrinter-only progress |
| `Sources/ADevContainerLib/Commands/UpCommand.swift` | Migrate stray stderr; connectionHint info |
| `Sources/ADevContainerLib/Commands/RebuildCommand.swift` | Same presentation parity |
| `Sources/ADevContainerLib/Commands/StartCommand.swift` | connectionHint info |
| `Sources/ADevContainerLib/Commands/PruneCommand.swift` | Progress via StatusPrinter |
| `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift` | Consistent error/warn/info; prompts not QUIET-silenced |
| `Sources/ADevContainerLib/Features/FeaturesRunner.swift` (and build invoke) | Status lines + framed build tee |
| `Sources/ADevContainerLib/Support/ManagedContainers.swift` | Prompts remain visible |
| `Sources/ADevContainerLib/Runtime/AppleContainerConfig.swift` | Consent/progress via facade |
| `Sources/adevcontainer/AdevcontainerMain.swift` | Human error write uses styled CLIError output |
| `Tests/adevcontainerTests/…` | New TerminalStyle/StatusPrinter/ProcessRunner framing tests; update stderr assertions for `| ` where streams are expected; keep monochrome prefix greps |

## Test strategy

- Unit-test TerminalStyle matrix: TTY/NO_COLOR/FORCE_COLOR combinations with injected isatty/env.
- Unit-test StatusPrinter: QUIET matrix, section blank lines, connectionHint not `==> `, warning under QUIET.
- Unit-test ProcessRunner framer: multi-chunk lines, partial line at EOF, raw capture unframed, no double prefix.
- Command/lifecycle tests: hook body framed; QUIET keeps body; JSON stdout pure.
- Clone tests: populate path requests streamOutput; framed body; failure diagnostics raw.
- Exec tests: user exec not framed.
- Regression: existing greps for `==> `, `warning: `, `error:` still pass on monochrome (FORCE_COLOR off / NO_COLOR set in tests by default unless testing color).

## Flow (create-path stderr sketch)

```text
==> Resolving configuration
==> Resolving features
==> Fetching feature ghcr.io/…/node:1
==> Building features image adev-…:abc
    | [build output line]
    | [build output line]
==> Creating container …
==> Starting container
==> Populating workspace   # clone only
    | Cloning into …
    | …
==> Running onCreateCommand
    | hook body
==> Running postCreateCommand
    | …
==> Ready
    Connect with: …          # info, not ==>
warning: …                   # if any; not QUIET-silenced
```

Under `ADEVCONTAINER_QUIET=1`, only the `| ` tool lines, warnings, errors, and prompts remain.
