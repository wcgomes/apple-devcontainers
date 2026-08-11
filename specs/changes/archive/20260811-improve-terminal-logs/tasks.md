# Tasks: improve-terminal-logs

Spec ref: `specs/changes/improve-terminal-logs/`  
Design ref: `specs/changes/improve-terminal-logs/design.md`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. Default unit suite MUST NOT require a real TTY, network, or Apple `container` runtime — inject TerminalStyle/isatty/env and mock ProcessRunning / AppleContainerRuntime as today. Prefer monochrome (`NO_COLOR` set or style stub) unless a task explicitly tests color.

## 1. TerminalStyle + StatusPrinter

- [x] 1.1 Write failing tests: color policy — enabled when stderr TTY and `NO_COLOR` unset; disabled when `NO_COLOR` set (any value); `FORCE_COLOR=1` may enable without TTY; `NO_COLOR` wins over `FORCE_COLOR` (path: `Tests/adevcontainerTests/Support/TerminalStyleTests.swift`)
- [x] 1.2 Write failing tests: StatusPrinter phase lines use monochrome prefix `==> `; QUIET/`enabled` silences phase and info only (path: `Tests/adevcontainerTests/Support/StatusPrinterTests.swift`)
- [x] 1.3 Write failing tests: warning always emits under QUIET; prefix `warning: `; test suppressWarningStderr seam preserved (path: `Tests/adevcontainerTests/Support/StatusPrinterTests.swift`)
- [x] 1.4 Write failing tests: section spacing — blank line before second and later top-level phase lines, not before first; no blank placeholders when QUIET suppresses phases (path: `Tests/adevcontainerTests/Support/StatusPrinterTests.swift`)
- [x] 1.5 Write failing tests: `connectionHint` uses info weight (not `==> ` phase prefix); silenced under QUIET (path: `Tests/adevcontainerTests/Support/StatusPrinterTests.swift`)
- [x] 1.6 Write failing tests: when color enabled, phase/warning/error styling wraps but strip-ANSI still contains stable prefixes (path: `Tests/adevcontainerTests/Support/TerminalStyleTests.swift`)
- [x] 1.7 Implement `TerminalStyle` (policy, ANSI helpers, prefix/indent constants, test seams for isatty/env) (path: `Sources/ADevContainerLib/Support/TerminalStyle.swift`)
- [x] 1.8 Expand `StatusPrinter` (info, section spacing, style integration, connectionHint → info) (path: `Sources/ADevContainerLib/Support/StatusPrinter.swift`)

## Checkpoint — facade
- [x] verify **Phase lines use ==> prefix**
- [x] verify **Warning always emits under QUIET**
- [x] verify **Quiet silences progress and info not errors** (phase/info portion)
- [x] verify **Connection hints are quieter than phases**
- [x] verify **Blank line before non-first phase**
- [x] verify **Color when stderr TTY and NO_COLOR unset** / **NO_COLOR forces monochrome** / **FORCE_COLOR may enable without TTY**

---

## 2. ProcessRunner tee framing

- [x] 2.1 Write failing tests: with stream tee enabled, multi-chunk input reassembles lines and each displayed line is framed with indent + `| `; capture buffer remains raw unprefixed (path: `Tests/adevcontainerTests/Support/ProcessRunnerFramingTests.swift`)
- [x] 2.2 Write failing tests: partial line at EOF is flushed to display without losing capture fidelity (path: `Tests/adevcontainerTests/Support/ProcessRunnerFramingTests.swift`)
- [x] 2.3 Write failing tests: non-stream run does not frame and does not write tool body to host stderr (path: `Tests/adevcontainerTests/Support/ProcessRunnerFramingTests.swift`)
- [x] 2.4 Write failing tests: framing does not apply on interactive/TTY inherit path (behavior unchanged) (path: `Tests/adevcontainerTests/Support/ProcessRunnerFramingTests.swift`)
- [x] 2.5 Implement line-buffer framer in `FoundationProcessRunner` stream path; keep `StreamTeeingProcessRunning` API coherent (path: `Sources/ADevContainerLib/Runtime/ProcessRunner.swift`)
- [x] 2.6 Wire `AppleContainerRuntime` streamOutput/streamStderr paths so internal tees use framing; user/interactive paths do not (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)

## Checkpoint — tee
- [x] verify **Phase vs tool distinction on stderr** (framer unit level)
- [x] verify **Captured diagnostics remain unprefixed** (capture buffer)
- [x] verify **Interactive exec TTY inherit unchanged** (no frame on interactive path)

---

## 3. CLIError presentation

- [x] 3.1 Write failing tests: human `formatted()` still starts with `error: ` and indented property/hint lines; under color-enabled style, strip-ANSI preserves structure (path: `Tests/adevcontainerTests/Support/CLIErrorPresentationTests.swift`)
- [x] 3.2 Write failing tests: JSON `CLIErrorOutput.data(for:json: true)` remains pure parseable JSON without requiring ANSI stripping (path: `Tests/adevcontainerTests/Support/CLIErrorPresentationTests.swift`)
- [x] 3.3 Write failing tests: diagnostic snippets attached from tool capture stay unprefixed raw text (path: `Tests/adevcontainerTests/Support/CLIErrorPresentationTests.swift`)
- [x] 3.4 Implement styled human formatting via TerminalStyle; leave JSON path structured monochrome (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [x] 3.5 Ensure entry-point human error write uses styled output (path: `Sources/adevcontainer/AdevcontainerMain.swift`)

## Checkpoint — errors
- [x] verify **Error formatting remains structured**
- [x] verify **JSON error path uncolored structure**
- [x] verify **Quiet silences progress and info not errors** (error still emits)

---

## 4. Clone populate streaming

- [x] 4.1 Write failing tests: clone populate exec requests live stream (`streamOutput: true` or equivalent mock assertion) (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 4.2 Write failing tests: streamed populate body appears as framed tool lines on stderr; QUIET keeps body and silences populate status (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 4.3 Write failing tests: populate failure diagnostics include raw tool text without `| ` prefix (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 4.4 Implement populate `streamOutput: true` (or runtime equivalent) and StatusPrinter status for populate phase (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)

## Checkpoint — clone stream
- [x] verify **Clone populate streams live framed tool output**
- [x] verify **Clone populate streams under QUIET**
- [x] verify **Clone populate failure diagnostics raw**

---

## 5. Migrate product call-sites

Migrate progress/warn/info writers onto StatusPrinter/TerminalStyle. One primary path area per task. Keep stdout success digests/JSON on stdout.

- [x] 5.1 Write failing tests then migrate: lifecycle hook status + framed body end-to-end with QUIET/JSON purity (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`, tests under `Tests/adevcontainerTests/`)
- [x] 5.2 Write failing tests then migrate: Features progress lines + framed build tee when streamed (path: `Sources/ADevContainerLib/Features/FeaturesRunner.swift`, runtime build invoke)
- [x] 5.3 Migrate UpCommand stray stderr/progress; connectionHint info weight (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 5.4 Migrate RebuildCommand presentation parity with up (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 5.5 Migrate StartCommand connectionHint info weight (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 5.6 Migrate CloneCommand non-populate progress/warn paths (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 5.7 Migrate prune progress lines via StatusPrinter (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 5.8 Migrate mount/ownership and related warnings (path: `Sources/ADevContainerLib/Commands/WorkspaceOwnership.swift` and call sites)
- [x] 5.9 Migrate recovery orchestrator failure/warn/info printing; prompts remain visible under QUIET (path: `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift`)
- [x] 5.10 Migrate VS Code soft-fail / open progress warnings to facade norms (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`, `VSCodeCustomizationsApply.swift`)
- [x] 5.11 Migrate AppleContainerConfig consent/progress messages (path: `Sources/ADevContainerLib/Runtime/AppleContainerConfig.swift`)
- [x] 5.12 Migrate ManagedContainers picker/prompt writers as needed without QUIET-silencing prompts (path: `Sources/ADevContainerLib/Support/ManagedContainers.swift`)
- [x] 5.13 Verify user `ExecCommand` output remains unframed passthrough (tests + code path) (path: `Sources/ADevContainerLib/Commands/ExecCommand.swift`)

## Checkpoint — migration
- [x] verify **Hook run emits status and framed live-tees I/O**
- [x] verify **Quiet silences status not hook output**
- [x] verify **Progress lines during feature up** / **Quiet suppresses features progress**
- [x] verify **Features build tool body framed when streamed**
- [x] verify **User exec output is not framed**
- [x] verify **JSON purity with progress and tool body**

---

## 6. Integration / regression and docs

- [x] 6.1 Update existing tests that assert raw teed hook/build stderr to expect `| ` framing where applicable; keep monochrome prefix greps for `==> `, `warning: `, `error:` (path: `Tests/adevcontainerTests/`)
- [x] 6.2 Run full unit suite; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 6.3 [P] README brief note: QUIET silences progress/info only; tool lines prefixed; NO_COLOR / FORCE_COLOR; no verbose flag (path: `README.md`)
- [x] 6.4 Grep product Sources for ad hoc progress writers that bypass StatusPrinter on stderr create-paths; fix stragglers that are product progress/warn/info (path: `Sources/ADevContainerLib/`)
- [x] 6.5 Contract landing (when implementing archive): fold ADDED requirements into `specs/terminal-output.md` (preferred) or `specs/core.md`; apply MODIFIED deltas to `specs/lifecycle-hooks.md` and `specs/features.md`; archive this folder to `specs/changes/archive/YYYYMMDD-improve-terminal-logs/` (path: `specs/`)

## Checkpoint — suite / docs
- [x] verify scenarios from change `spec.md` ADDED + MODIFIED covered by tests
- [x] verify `swift run adevcontainerTests` green for default (mocked) suite
- [x] verify no `[NEEDS CLARIFICATION]` markers in change artifacts
- [x] verify stable prefixes still greppable under monochrome test defaults
