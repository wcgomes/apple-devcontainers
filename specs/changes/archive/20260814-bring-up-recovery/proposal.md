# Proposal: Bring-up recovery mode (up/clone/start)

## Intent

Recovery mode exists only for `rebuild` after the old container was removed (hard post-delete). `up`, `clone`, and `start` fail fast with a structured error when the container cannot be brought up — e.g. a `forwardPorts` port already in use surfaces as `runtimeFailed` at create/start — leaving the user to free the port and manually re-run, with no guided path to adjust the resolved `devcontainer.json` and retry. This change offers a bounded recovery prompt on bring-up failures so the user can edit the config and retry, mirroring the existing rebuild recovery UX (prompt-then-editor, non-TTY retain) without deleting any state up front.

## Scope

- `up` (bind): prompt → host-config editor → retry loop (re-resolve from host + re-run create path). Host-edit only; no extra copy into the container.
- `clone` (volume): retain the config-only checkout, prompt → editor → retry loop from the retained checkout; non-TTY retains the checkout and prints an exact retry command. After a successful retry (TTY edit or `--resume`), the in-container workspace `devcontainer.json` is the edited bytes, not the original git-populated file.
- `start`: prompt → delegate to `rebuild --name` (reuses the existing full recovery). No new write path.
- Shared bring-up recovery primitive reusing `RecoveryOpenEditorPrompt`, `RecoveryEditor`, and `CLIErrorCode` recovery codes.

## Non-goals

- Changing `rebuild` recovery semantics, including volume helper write-back, `delete`/`prune` volume handling, or postAttach/settings/open soft-fail behavior.
- Inventing an Alpine helper for bring-up recovery.
- Rollback of a failed create path (data written by hooks is not rolled back).
- Recovery for failures where no editable `devcontainer.json` exists (config not found; clone git fetch failure before any config exists). No overlay in those cases either.
- A generic config-editing prompt outside bring-up failures.

## Approach

Reuse `RecoveryOpenEditorPrompt`, `RecoveryEditor`, and the recovery `CLIErrorCode`s from `RecoveryOrchestrator`. Add a shared bring-up recovery helper (TTY prompt → editor → retry loop) and per-command wiring. `clone` gains a `--resume <config-dir>` flag for non-TTY resume of a retained checkout. After a successful `clone` recovery retry, persist the edited `devcontainer.json` into the in-container workspace after populate so the git-cloned original does not remain the workspace file. Bind `up` stays host-edit only. Do not reuse or invent an Alpine helper for this persist.

## Clarifications

Mid-work refinement (same change id, not a new change): a successful `clone` recovery edit is not enough on its own. Populate git-clones the original URL into the volume and would restore the broken `devcontainer.json`. This change now also requires persisting the edited bytes into the in-container workspace after a successful TTY retry or `--resume`. Bind `up` remains host-edit only (the host file is already the workspace). `start` still delegates to `rebuild --name` and gains no write path.

- **Q:** Which failures offer recovery?
  **A:** Any bring-up failure with an editable `devcontainer.json` (see trigger set in spec). Failures with no editable config (config not found; clone git fetch failure before config exists) fail normally and MUST NOT overlay a config into the workspace.
- **Q:** How does `start` recovery behave?
  **A:** Delegate to `rebuild --name` — ports/labels are baked at create, so re-running `start` cannot re-apply an edited config. `start` MUST NOT add a write path for an edited config.
- **Q:** Does retry re-execute or resume?
  **A:** Re-execute from scratch (re-resolve from host for `up`, from the retained checkout for `clone`); no mid-pipeline resume.
- **Q:** After a successful `clone` recovery retry, which `devcontainer.json` is in the container workspace?
  **A:** The edited bytes. Clone populate git-clones the original URL, which would restore the broken config; after a successful TTY edit-and-retry or `clone --resume`, the workspace file MUST be the edited bytes, not the original git-populated file. Persistence happens after populate so a later in-container open does not require re-fixing.
- **Q:** Does bind `up` copy the edited config into the container?
  **A:** No. Bind `up` already edits the host workspace file; recovery remains host-edit only with no extra copy.
- **Q:** Does this change rebuild volume helper write-back?
  **A:** No. Rebuild volume helper write-back semantics stay as they are. Bring-up MUST NOT invent an Alpine helper.
