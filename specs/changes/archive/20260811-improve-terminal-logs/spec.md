# Change Spec: improve-terminal-logs

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply.

On archive, these ADDED requirements SHOULD land as a cohesive domain set — prefer new `specs/terminal-output.md`, or fold into `specs/core.md` if a single domain home is chosen. MODIFIED requirements update presentation only; they MUST NOT weaken QUIET, JSON purity, hook order, or Features install semantics.

## ADDED Requirements

### Requirement: Terminal log channel roles

The CLI MUST separate host terminal streams by role:

1. **Product progress / step / info** — phase and quieter informational lines written by the product (StatusPrinter family or equivalent facade).
2. **Product warnings** — policy and soft-fail warnings (`warning: …`).
3. **Product errors** — structured human error presentation (`error: …`) and JSON error objects when machine mode applies (`code` field remains machine-only).
4. **Internal tool body** — live-teed stdout/stderr from internal subprocesses the product runs on the user's behalf (lifecycle hooks, Features `container build`, clone populate git clone, other internal `container`/tool tees).
5. **User command passthrough** — output of user-initiated `adevcontainer exec` (interactive or non-interactive) and other true user I/O.

**Channel rules**

- Progress, warnings, internal tool body tees, and human error text MUST write to **host stderr**.
- **Host stdout** MUST remain pure for machine JSON and digest-style success output when `--json` (or equivalent) is used: no progress lines, no tool body, no warnings on stdout.
- Interactive prompts that read stdin MUST remain usable under QUIET and MUST NOT be classified as silenced progress.
- This requirement MUST NOT introduce a verbose flag, log files, spinners, or emoji/icon decoration.

#### Scenario: JSON purity with progress and tool body
- Given a command invoked with `--json` that emits product phases and internal tool body lines during work
- When the command succeeds
- Then host stdout contains only machine JSON (no `==> ` lines, no `| ` tool lines, no `warning: ` lines) and progress/tool/warn appear on host stderr

#### Scenario: Human mode uses stderr for progress and tool
- Given quiet mode unset and a non-JSON create-path command that runs a live-streamed internal tool
- When the command runs
- Then product phase lines and framed tool body lines appear on host stderr

#### Scenario: No verbose flag or log files required
- Given the product after this change
- When the user runs ordinary commands without extra flags
- Then improved presentation applies by default and the CLI does not require a verbose flag or write a product log file for this behavior

---

### Requirement: Product log severity presentation

Product log lines MUST use stable textual prefixes (monochrome greppable form):

| Severity | Prefix / shape | QUIET |
|----------|----------------|-------|
| Phase / step | `==> <message>` | Silenced when `ADEVCONTAINER_QUIET=1` |
| Info (quieter) | Product info line **without** full `==> ` phase weight (implementation MAY use a distinct quieter form such as indented or unprefixed info via the facade) | Silenced when `ADEVCONTAINER_QUIET=1` |
| Warning | `warning: <message>` | **Not** silenced by QUIET |
| Error (human) | `error: <message>` with optional indented `property:` / `hint:` detail lines | **Not** silenced by QUIET |

**Connection hints**

- Connection hints (e.g. how to `exec` or open with `--vscode`) SHOULD emit as **info** (quieter than a top-level phase), not as full `==> ` phase lines.
- Connection hints MUST honor QUIET (silenced with other progress/info).
- On successful human `up`/`rebuild` without originating `--vscode`, hints MUST appear **after** the human outcome digest on stdout, separated by a blank line on stderr. Human outcome fields MUST be indented under `==> Ready`. On successful `clone`, hints MUST appear after success JSON on stdout (same blank separator). Originating `--vscode` MUST suppress these hints.

**Human error shape**

- Human mode MUST use the prefix `error: ` only (MUST NOT embed the machine error code in the head label). Machine JSON MUST still expose `code` when applicable.
- Optional indented `property:` and `hint:` detail lines remain allowed.

**Stability**

- The monochrome textual prefixes `==> `, `warning: `, and `error: ` MUST remain stable for tests and specs.
- When color is enabled, ANSI styling MAY wrap those prefixes/messages; stripping ANSI MUST still leave the stable prefixes intact.

**QUIET**

- `ADEVCONTAINER_QUIET=1` MUST silence product **progress, step, and info** only.
- QUIET MUST NOT silence warnings, errors, internal tool body lines, or interactive prompts.

#### Scenario: Phase lines use ==> prefix
- Given quiet mode unset
- When the product emits a top-level phase such as resolving configuration or creating a container
- Then host stderr includes a line whose monochrome text starts with `==> `

#### Scenario: Warning always emits under QUIET
- Given `ADEVCONTAINER_QUIET=1` and a policy warn-skip or soft-fail path that must warn
- When the path runs
- Then host stderr includes a `warning: ` line and no requirement forces that warning to be suppressed

#### Scenario: Quiet silences progress and info not errors
- Given `ADEVCONTAINER_QUIET=1`
- When a command emits phases/info and then fails with a structured CLIError in human mode
- Then `==> ` phase lines and quieter info/connection-hint lines are not printed, and the human `error: ` presentation still appears on stderr

#### Scenario: Connection hints are quieter than phases
- Given quiet mode unset and a successful start/up/clone/rebuild path that prints connection hints
- When hints are emitted
- Then they are not presented as full-weight `==> ` phase lines (info weight) and under `ADEVCONTAINER_QUIET=1` they are silenced

#### Scenario: Human up success order Ready then outcome then hints
- Given quiet mode unset, human (non-JSON) `up` success without `--vscode`
- When the command finishes
- Then stderr includes `==> Ready`, stdout includes indented `outcome:` / identity fields, and connection hints appear on stderr after a blank line following that digest (not before the outcome fields)

#### Scenario: Error formatting remains structured
- Given a failing command in human (non-JSON) mode
- When the CLI prints the error
- Then stderr includes `error: <message>` without an `error[<code>]:` head label, and when present indented property/hint detail; machine JSON still exposes `code` when applicable

---

### Requirement: Internal tool output framing

When the product live-tees an **internal** tool's stdout and/or stderr to host stderr, each teed **line** MUST be framed as internal tool output:

1. Prefix each displayed line with `| ` (pipe + space).
2. Apply indent so tool lines read as nested under the active product phase (concrete indent width is an implementation choice; MUST be consistent).
3. MUST NOT use emojis or icons in the frame.
4. Framing applies to **host display at tee time only**.

**Capture vs display**

- Bytes/text **captured** for failure diagnostics and CLIError detail MUST remain **unprefixed raw** tool text (no `| ` frame stored on the error).
- Tests that assert diagnostic capture MUST expect raw content, not framed display lines.

**Scope of framing**

- MUST frame: lifecycle hook command body, Features build/fetch tool body when live-teed, clone populate in-container git clone body, and other internal non-interactive tees of product-invoked tools.
- MUST NOT frame: user `adevcontainer exec` output (passthrough); interactive exec / InteractiveProcessRunner TTY inherit sessions; product-owned StatusPrinter lines (those use product severity presentation, not tool framing).

**QUIET**

- Internal tool body lines MUST still emit on host stderr under `ADEVCONTAINER_QUIET=1` (only the product status/info lines for that step may be silenced).

#### Scenario: Phase vs tool distinction on stderr
- Given quiet mode unset and a create-path hook that prints a recognizable line to its stdout
- When the CLI executes that hook
- Then host stderr includes a product status line `==> Running <property>` (or labeled form) and the hook body line appears as a framed internal tool line starting with `| ` (after indent), not as a second `==> ` phase line

#### Scenario: Quiet keeps tool body
- Given `ADEVCONTAINER_QUIET=1` and an internal live-streamed tool that prints a recognizable line
- When the tool runs
- Then product `==> ` status for that step is not printed and the framed tool body line still appears on host stderr

#### Scenario: Captured diagnostics remain unprefixed
- Given an internal tool that fails after printing `TOOL_FAIL_MARK` on stderr
- When the CLI builds a structured error that includes captured diagnostics
- Then the captured diagnostic text contains `TOOL_FAIL_MARK` without a leading `| ` frame prefix

#### Scenario: User exec output is not framed
- Given a running managed container
- When the user runs `adevcontainer exec` (non-interactive) with a command that prints `USER_EXEC_MARK`
- Then host output shows `USER_EXEC_MARK` without internal-tool `| ` framing

#### Scenario: Interactive exec TTY inherit unchanged
- Given an interactive `adevcontainer exec -it` session
- When the session runs
- Then process TTY inherit behavior is unchanged by this presentation change (no forced line-buffer framing that breaks the interactive TTY)

---

### Requirement: Color and monochrome policy

Product presentation MAY apply ANSI colors to phase, info, warning, and human error lines when **color is enabled**.

**Color enabled** when all of the following hold, unless forced:

- Host **stderr** is a TTY; and
- Environment variable `NO_COLOR` is **unset** (any value of `NO_COLOR` means color disabled per common convention).

**Force**

- When `FORCE_COLOR=1`, the CLI MAY enable color even if stderr is not a TTY.
- When `NO_COLOR` is set, the CLI MUST NOT enable color (NO_COLOR wins over FORCE_COLOR).

**Monochrome**

- When color is not enabled, output MUST be monochrome with stable textual prefixes only.

**Machine output**

- JSON error and success payloads on the machine stream MUST NOT depend on ANSI codes for correctness; human-only coloring MUST NOT corrupt JSON.

#### Scenario: Color when stderr TTY and NO_COLOR unset
- Given stderr is a TTY, `NO_COLOR` unset, and `FORCE_COLOR` unset
- When the product emits a phase or warning line
- Then the implementation MAY include ANSI color sequences around the stable prefix/message

#### Scenario: NO_COLOR forces monochrome
- Given `NO_COLOR` is set in the environment (any value)
- When the product emits phase, warning, or human error lines
- Then those lines are monochrome (no color styling applied)

#### Scenario: FORCE_COLOR may enable without TTY
- Given stderr is not a TTY, `NO_COLOR` unset, and `FORCE_COLOR=1`
- When the product emits a phase line
- Then the implementation MAY apply color styling

#### Scenario: JSON error path uncolored structure
- Given `--json` and a failing command
- When the error is written for machine consumption
- Then the JSON object remains parseable structured fields without requiring ANSI stripping for correctness

---

### Requirement: Section spacing for phases

For top-level product **phase** lines (`==> …`):

- The CLI SHOULD emit a single blank line on host stderr before each top-level phase line **except the first** phase line of the process invocation, so phases read as separated sections.
- Blank-line separation MUST NOT insert blank lines into host stdout JSON.
- Blank-line separation MUST NOT apply inside framed tool body streams (tool lines stay contiguous aside from their own content).
- Under QUIET, suppressed phase lines produce no blank-line placeholders for those omitted phases.

#### Scenario: Blank line before non-first phase
- Given quiet mode unset and a command that emits at least two top-level `==> ` phase lines on stderr
- When the command runs
- Then the second (and later) phase lines are preceded by a blank line on stderr, and the first phase line is not required to have a leading blank line from this rule

#### Scenario: Spacing does not break JSON stdout
- Given `--json` and multiple phases on stderr
- When the command succeeds
- Then stdout JSON remains pure and contiguous as a JSON document

---

### Requirement: Clone populate live stream

On `clone`, after the container is created and started, the **in-container full git clone populate** (and any immediately associated populate exec the product uses for that populate step) MUST:

1. Live-tee the populate command's stdout and stderr to **host stderr** while the command runs (same live-stream class as lifecycle hooks and Features build tees).
2. Frame displayed tool lines as **internal tool output** per **Internal tool output framing**.
3. Still capture raw (unprefixed) output for failure diagnostics.
4. Keep host stdout pure under `--json`.
5. Under `ADEVCONTAINER_QUIET=1`, still emit framed tool body; only the product populate status/info lines are silenced.

This requirement extends presentation only; populate auth matrix, verify `.git`, and failure cleanup remain as in [clone.md](../../clone.md).

#### Scenario: Clone populate streams live framed tool output
- Given a clone path whose in-container git clone prints progress lines to stdout/stderr and quiet mode unset
- When populate runs
- Then those lines appear live on host stderr as framed internal tool lines (`| ` after indent) rather than only after the command completes

#### Scenario: Clone populate streams under QUIET
- Given `ADEVCONTAINER_QUIET=1` and populate tool output that prints a recognizable line
- When populate runs
- Then product populate status lines are silenced and the framed tool line still appears on host stderr

#### Scenario: Clone populate failure diagnostics raw
- Given populate fails after the tool printed a recognizable diagnostic line
- When the structured `populate_failed` (or equivalent) error is formed
- Then captured diagnostic text keeps the raw tool line without `| ` framing

---

## MODIFIED Requirements

### Requirement: Lifecycle hook progress and live stream

**Modify** [lifecycle-hooks.md](../../lifecycle-hooks.md) **Lifecycle hook progress and live stream** as follows (presentation extension only):

When a create-path hook, restart `postStartCommand`, or running `postAttachCommand` executes, the CLI MUST:

1. Emit a stderr progress status line in the StatusPrinter family before the hook runs: `==> Running <property>` (string/argv form), or the labeled form `==> Running <property> (<name>)` for each object-map entry. Presentation MAY apply color and phase section spacing per ADDED requirements; the monochrome text family MUST remain greppable as `==> Running …`.
2. Live-tee the hook command's **stdout and stderr** to **host stderr** while the command runs, **framed as internal tool output** (each displayed line prefixed with `| ` and indented per **Internal tool output framing**), and still capture that output as **unprefixed raw** text for failure diagnostics (structured error text). Non-lifecycle `exec` MAY remain capture-then-print unless another requirement enables streaming.
3. Keep machine JSON on stdout pure when `--json` (or equivalent) is used — hook script stdout MUST NOT write to host stdout (tee to host stderr only).
4. Treat `ADEVCONTAINER_QUIET=1` as silencing **status lines only** (`==> Running …`); hook script output MUST still emit on host stderr under QUIET (framed as internal tool lines).

This modification MUST NOT change hook order, admitted forms, fail/delete-on-fail policy, or postAttach gating.

#### Scenario: Hook run emits status and framed live-tees I/O
- Given a create-path (or restart postStart / running postAttach) hook that prints to stdout and stderr and exits 0, and quiet mode unset
- When the CLI executes that hook
- Then stderr includes `==> Running <property>` (or labeled form), the hook's stdout and stderr appear live on host stderr as framed `| ` tool lines, captured diagnostics remain available as raw text on failure paths, and with `--json` host stdout remains pure machine JSON

#### Scenario: Quiet silences status not hook output
- Given `ADEVCONTAINER_QUIET=1` and a hook that prints a recognizable line to stdout
- When the CLI executes that hook
- Then `==> Running …` status lines are not printed and the hook's output still appears on host stderr as framed internal tool lines

---

### Requirement: Features progress status lines

**Modify** [features.md](../../features.md) **Features progress status lines** as follows (presentation note only):

During Features work on `up` (and other create paths that run Features), the CLI MUST emit stderr progress status lines in the progress family (`==> …` / StatusPrinter), including at least:

- Resolving features
- Fetching feature \<ref or id\> (per feature or equivalent clear wording)
- Building features image \<tag\> (or Reusing features image \<tag\> when the tag exists)
- Configuring native arm64 builds (build.rosetta=false) — **only** when actually changing config

Presentation MAY use colors and phase section spacing per ADDED requirements. The monochrome text family of these status lines MUST remain greppable (`==> …` with the same message intent).

When Features build (or other Features tool steps) live-tee subprocess output to host stderr, those body lines MUST use **internal tool output framing**; status lines remain product phase lines.

`ADEVCONTAINER_QUIET=1` MUST silence these status lines (progress only). Policy warn-skip warnings MUST still emit under QUIET. Machine JSON on stdout MUST remain pure when `--json` (or equivalent) is used. Tool body tees MUST still emit under QUIET.

#### Scenario: Progress lines during feature up
- Given a features config and quiet mode unset
- When `up` runs the Features path (mocked fetch/build OK)
- Then stderr includes resolving/fetching/building (or reusing) status lines in the `==> …` family

#### Scenario: Quiet suppresses features progress
- Given `ADEVCONTAINER_QUIET=1`
- When `up` runs the Features path
- Then Features progress status lines are not printed

#### Scenario: Features build tool body framed when streamed
- Given quiet mode unset and a Features build that live-tees builder output containing a recognizable line
- When the build runs
- Then the recognizable builder line appears on host stderr as a framed internal tool line (`| ` after indent), distinct from `==> ` status lines

---

## REMOVED Requirements

None.
