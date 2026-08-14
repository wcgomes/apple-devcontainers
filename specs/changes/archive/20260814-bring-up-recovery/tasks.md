# Tasks: bring-up-recovery

Test-first: write failing tests before implementation. Mock `AppleContainerRuntime` so the default suite needs no real `container` runtime. Reuse `RecoveryOpenEditorPrompt`, `RecoveryEditor`, and `CLIErrorCode` recovery codes from `RecoveryOrchestrator`. Do not archive or fold domain specs in this task set.

## 1. Shared bring-up recovery primitive

- [x] 1.1 Add `BringUpRecovery` with a TTY prompt → editor → retry loop (reuse `RecoveryOpenEditorPrompt`/`RecoveryEditor`); decline/EOF throws original error; non-TTY returns an edit/retry hint struct without prompting (path: `Sources/ADevContainerLib/Commands/BringUpRecovery.swift`)
- [x] 1.2 Unit-test the loop: affirmative retry, decline, EOF, non-TTY no-prompt, invalid-config reopen (path: `Tests/adevcontainerTests/BringUpRecoveryTests.swift`)

## Checkpoint

- [x] verify **Bring-up recovery offer on up and clone** (prompt/decline/EOF/non-TTY shapes)

## 2. `up` wiring

- [x] 2.1 Test-first: `up` create/start/ownership/create-path-hook failure offers bind host-editor recovery and retries (mock runtime + editor) (path: `Tests/adevcontainerTests/UpCommandRecoveryTests.swift`)
- [x] 2.2 Wrap `UpCommand` create/start/ownership/`runCreatePath` failures with `BringUpRecovery` bind flow (re-resolve from host + re-run create path) (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)

## Checkpoint

- [x] verify **Bind up recovery (host config editor)** scenario

## 3. `clone` wiring

- [x] 3.1 Test-first: `clone` failure retains the config-only checkout in a stable non-temp path and (TTY) edits+retries without re-fetch; non-TTY retains + prints exact retry (path: `Tests/adevcontainerTests/CloneRecoveryTests.swift`)
- [x] 3.2 Extract the post-fetch `clone` pipeline into a re-entrant function keyed on a retained config dir (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 3.3 Add `--resume <config-dir>` to `CloneOptions` + argument parser + help text (paths: `Sources/ADevContainerLib/Commands/CloneCommand.swift`, `Sources/adevcontainer/AdevcontainerMain.swift`, `Sources/ADevContainerLib/Support/CommandSurface.swift`)

## Checkpoint

- [x] verify **Clone volume recovery (retained checkout)** scenario (TTY and non-TTY `--resume`)

## 4. `start` wiring

- [x] 4.1 Test-first: `start` failure prompts (TTY) and delegates to `RebuildCommand`; decline/non-TTY fails with `rebuild --name` hint (path: `Tests/adevcontainerTests/StartCommandRecoveryTests.swift`)
- [x] 4.2 Wrap `StartCommand` `runtime.start` failure with the rebuild-delegation prompt (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)

## Checkpoint

- [x] verify **Start failure delegates to rebuild** scenario

## 5. E2E gates + docs

- [x] 5.1 Add E2E coverage under `ADEVCONTAINER_RECOVERY_E2E` / `ADEVCONTAINER_RECOVERY_E2E_TTY` for up/clone/start recovery paths (gated command-specific harness; skips without macOS Apple-container runtime/TTY)
- [x] 5.2 Update README and `printCommandHelp` for `up`/`clone`/`start` recovery UX and `clone --resume` (paths: `README.md`, `Sources/ADevContainerLib/Support/CommandSurface.swift`)

## Checkpoint

- [ ] verify all spec scenarios map to a passing test; run `swift run adevcontainerTests` and repo lint/typecheck (recovery-focused tests pass; four pre-existing host/PTY/security-environment failures remain, and live Apple E2E is skipped without its gate/runtime)

## 6. Persist edited clone config into workspace

Do not change rebuild volume helper write-back. Do not add an Alpine helper for bring-up. Overlay this persist after populate on a successful `clone` recovery retry only.

- [x] 6.1 Test-first: successful TTY clone recovery retry and `clone --resume` leave the in-container workspace `devcontainer.json` as the edited bytes after populate; no overlay when there is no editable config (path: `Tests/adevcontainerTests/CloneRecoveryTests.swift`)
- [x] 6.2 Persist the edited `devcontainer.json` into the in-container workspace after populate on a successful `clone` recovery retry or `--resume` (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 6.3 [P] Confirm bind `up` recovery remains host-edit only with no extra workspace copy (path: `Tests/adevcontainerTests/UpCommandRecoveryTests.swift`)
- [x] 6.4 [P] Confirm `start` still delegates to rebuild and adds no write path (path: `Tests/adevcontainerTests/StartCommandRecoveryTests.swift`)

## Checkpoint

- [x] verify **Clone recovery persists edited config into workspace** (TTY retry, `--resume`, later in-container open, bind `up` host-edit only, `start` no write path, no overlay without editable config)
