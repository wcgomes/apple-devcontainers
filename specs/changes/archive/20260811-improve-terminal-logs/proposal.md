# Proposal: Improve terminal log UX (product vs tool framing)

## Intent

Long-running `adevcontainer` flows (`up`, `clone`, `rebuild`, Features build, lifecycle hooks) mix product phase lines with raw subprocess output on stderr. Today that stream is hard to scan: hook and `container` tool body lines look like product status, clone populate does not live-stream like hooks/build, connection hints carry full phase weight, and colors are absent. This change establishes a single **terminal progress and log presentation** contract: product phases stay `==> …`, internal tool body lines are framed with a stable `| ` prefix (and indent), colors apply only when policy allows, `ADEVCONTAINER_QUIET` remains progress/info-only, stdout stays pure for JSON/digests, and user-facing `exec` output remains unframed passthrough.

## Scope

- Change id: **`improve-terminal-logs`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/AdevcontainerMain.swift`; tests under `Tests/adevcontainerTests/`
- Realized base contract: union of `specs/<domain>.md`. This delta **adds** a cohesive terminal log presentation requirement set (channel roles, severity presentation, internal tool framing, color/monochrome, phase section spacing, clone populate live stream). On archive, prefer a new domain file `specs/terminal-output.md` (or fold into `core.md` if the team chooses one domain home).
- **MODIFIES** presentation of:
  - [lifecycle-hooks.md](../../lifecycle-hooks.md) **Lifecycle hook progress and live stream** — hook body lines on host stderr MUST be framed as internal tool output (`| `); status lines remain `==> Running …`; QUIET still status-only; JSON purity unchanged
  - [features.md](../../features.md) **Features progress status lines** — text family of status lines preserved; presentation MAY use colors and phase spacing; tool body from Features build/fetch tees MUST use internal tool framing
- Does **not** change hook order, Features install semantics, clone identity/auth, recovery eligibility, or command surfaces beyond log presentation
- Full migration of product log call-sites onto `StatusPrinter` / `TerminalStyle` (or equivalent facade): StatusPrinter, ProcessRunner tee, CLIError human colors, prompts, prune, mount warnings, recovery, connection hints, direct `FileHandle.standardError` / `print` product progress writers where they emit progress/warn/info
- Clone populate in-container git clone MUST live-stream tool output on host stderr (same streaming class as hooks/build), framed as internal tool lines
- Docs: brief README/help note on QUIET, NO_COLOR/FORCE_COLOR, and that tool lines are prefixed — no verbose flag, log files, or spinner UX

## Non-goals

- Verbose flag, log-level ladder, or log files
- Spinners, progress bars, or emoji/icon decoration
- Changing stable textual prefixes used by tests and specs: `==> `, `warning: `, `error: ` (colors may wrap; monochrome text remains greppable)
- Framing user `adevcontainer exec` (interactive or non-interactive) output as internal tool lines — passthrough remains
- Changing InteractiveProcessRunner / interactive exec TTY inherit behavior
- Prefixed capture for CLIError diagnostics — captured tool text stored on errors MUST remain unprefixed raw bytes/text
- Silencing tool body, warnings, errors, or interactive prompts under `ADEVCONTAINER_QUIET=1`
- Writing progress/warn/tool body to stdout (stdout remains pure for JSON and digest-style machine output)
- Reworking command semantics, Features recipe, clone auth matrix, or recovery policies beyond stream presentation
- Third-party pretty log frameworks or external log shippers

## Approach

Full SDD: this proposal + outcome delta `spec.md` + `design.md` (Full mode) + dependency-ordered test-first `tasks.md`.

1. Introduce `TerminalStyle` (color/monochrome policy, TTY detection, NO_COLOR/FORCE_COLOR) and expand `StatusPrinter` into the product log facade (phase, info, warning, error presentation, section spacing, connection-hint weight).
2. Line-buffer the `FoundationProcessRunner` stream tee so internal tool stdout/stderr teed to host stderr are framed per line with `| ` (+ indent); keep capture buffers raw/unprefixed for diagnostics.
3. Thread framing through `AppleContainerRuntime` stream paths used by lifecycle hooks, Features build, and other internal tees; leave interactive/user-exec paths unframed.
4. Enable live stream (`streamOutput: true` or equivalent) for clone populate exec; frame as internal tool.
5. Colorize human CLIError presentation and StatusPrinter severities when color policy allows; keep JSON error path monochrome/structured.
6. Migrate remaining product writers (prune, prompts, mount warnings, recovery, connection hints, stray stderr writes) onto the facade.
7. Update unit/regression tests that assert stderr shapes; preserve greppable prefixes in monochrome.

## Clarifications

- **Q:** How do tool lines differ from product lines visually?
  **A:** Product phases keep `==> ` (and warnings `warning: `, errors `error: `). Internal tool body lines on host stderr MUST be prefixed with `| ` and indented under the current phase. No emojis or icons.

- **Q:** Partial vs full call-site migration?
  **A:** Full migration of product log call-sites onto the StatusPrinter/TerminalStyle facade (or ProcessRunner framing for teed tool output). Includes StatusPrinter, ProcessRunner tee, CLIError human colors, prompts, prune, mount warnings, recovery, connection hints, and other product progress/warn/info writers.

- **Q:** Does clone populate stream live like hooks/build?
  **A:** Yes. In-container workspace populate (`git clone` and related populate exec) MUST live-stream tool output to host stderr, framed as internal tool lines, while still capturing raw output for failure diagnostics.

- **Q:** When are colors used?
  **A:** Colors when host stderr is a TTY and `NO_COLOR` is unset. `FORCE_COLOR=1` MAY force color even when stderr is not a TTY. Otherwise monochrome. JSON/machine paths stay uncolored structured output.

- **Q:** What does `ADEVCONTAINER_QUIET=1` silence?
  **A:** Product progress/step/info only (including `==> ` phase lines and quieter info lines such as connection hints). It MUST NOT silence tool body lines, warnings, errors, or interactive prompts.

- **Q:** stdout vs stderr?
  **A:** Progress, warnings, tool body tees, and human error presentation go to stderr. stdout stays pure for JSON and digest-style machine output.

- **Q:** Is user `adevcontainer exec` framed?
  **A:** No. User exec output is passthrough (not internal tool framing). InteractiveProcessRunner / interactive exec TTY inherit is unchanged.

- **Q:** Connection hints weight?
  **A:** Connection hints SHOULD be quieter info lines, not full `==> ` phase weight.

- **Q:** Section separation?
  **A:** Emit a blank line before each top-level phase line except the first, for visual section separation.

- **Q:** Stable prefixes for tests?
  **A:** Keep textual prefixes `==> `, `warning: `, and `error: ` stable so existing tests/specs remain greppable in monochrome (ANSI may wrap when color is on).

- **Q:** Captured diagnostics on CLIError?
  **A:** MUST remain unprefixed raw tool text (framing is host-display only at tee time).

- **Q:** Verbose, log files, spinners, emojis?
  **A:** Out of scope for this change.
