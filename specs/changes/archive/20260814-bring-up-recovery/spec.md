# Change Spec: bring-up-recovery

## ADDED Requirements

### Requirement: Bring-up recovery offer on up and clone

`up` and `clone` MUST offer an interactive recovery mode when bringing the container up fails and an editable `devcontainer.json` is available. The trigger set is: config parse/resolve failure on an existing config file, container create, container start, workspace-ownership, in-container workspace populate (`clone`), and create-path hooks (`onCreate`, `updateContent`, `postCreate`, `postStart`). Failures with no editable config — config not found, or `clone` git fetch failure before any config exists — MUST fail normally without a recovery prompt.

#### Scenario: create failure offers recovery in a TTY

- Given `up`/`clone` resolved a `devcontainer.json` and stdin is a TTY with `--json` absent
- When container create fails (e.g. a `forwardPorts` port already in use)
- Then the CLI prints the structured failure, prompts to enter recovery mode (default Y), and on affirmative opens the editor and retries; on decline/EOF it fails non-zero with the original error

#### Scenario: create failure without a TTY never prompts

- Given the same failure with a non-TTY stdin or `--json`
- Then the CLI never prompts or opens an editor and fails with the original error plus an edit/retry hint (up: host config path; clone: retained checkout + exact retry command)

#### Scenario: no editable config falls through

- Given `clone` fails during git fetch before a config exists, or `up` finds no `devcontainer.json`
- Then the CLI fails with the normal structured error and does not offer recovery

### Requirement: start failure delegates to rebuild

When `start` fails to start a selected managed container, the CLI MUST offer recovery mode by delegating to `rebuild` for that container rather than re-running `start` (the container's ports/labels are baked at create). In a TTY (without `--json`) it MUST prompt (default Y) and, on affirmative, run `RebuildCommand` for the same container. On decline/EOF, non-TTY, or `--json`, it MUST fail with the original error and a hint to run `adevcontainer rebuild --name <name>`; it MUST NOT open an editor or re-run `start`.

#### Scenario: start failure hands off to rebuild

- Given a selected managed container and `runtime.start` fails
- When stdin is a TTY and the user affirms the recovery prompt
- Then the CLI runs `rebuild` for that container (which provides its own recovery); otherwise it fails with a hint to run `adevcontainer rebuild --name <name>`

### Requirement: bind up recovery (host config editor)

For an eligible `up` failure in a TTY, recovery MUST print the structured failure, prompt whether to enter recovery (default Y), and on affirmative open the editor on the host `devcontainer.json` path and validate with bind-mode strict resolve rules. Invalid content MUST reopen the editor without retrying; a valid edit MUST retry by re-resolving from the host and re-running the create path. Decline/EOF MUST fail non-zero with the original error. Non-TTY/`--json` MUST never prompt or edit and MUST fail with the original error plus an edit/retry hint for the host config path. `up` recovery MUST NOT create a helper container or a retained checkout (the config already lives on the host).

#### Scenario: bind up recovery edits the host config and retries

- Given `up` failed at create/start/hooks and the config path is the host checkout
- When the user affirms the prompt and edits the config to a valid state
- Then the CLI re-resolves from the host config and re-runs the create path; on success it reports success and no helper/checkout is left behind

### Requirement: clone volume recovery (retained checkout)

On an eligible `clone` failure, `clone` MUST retain the config-only checkout in a stable non-temporary host location before it would otherwise be removed, so it can be edited and reused by a retry. In a TTY, recovery MUST prompt (default Y) and on affirmative open the editor on the retained config and retry by re-resolving from the retained checkout and re-running create → start → ownership → populate → hooks (no re-fetch of git). Non-TTY/`--json` MUST retain the checkout, print structured details plus an exact edit and retry command, and never prompt or edit. A later non-TTY resume MUST be possible via `clone --resume <config-dir>` reusing the retained checkout.

#### Scenario: clone recovery retains and reuses the checkout

- Given `clone` fetched a config-only checkout and then failed at create/start/populate/hooks
- When the failure is eligible
- Then the checkout is retained in a stable host location; in a TTY an affirmed prompt edits the retained config and retries without re-fetching git; in non-TTY the checkout is retained with an exact `clone --resume <config-dir>` retry command

### Requirement: Retry re-executes from scratch

After an edit, the retry MUST re-execute from the resolved config (re-resolve from the host for `up`, from the retained checkout for `clone`) rather than resuming mid-pipeline. A further recoverable failure MUST re-enter the prompt loop. Decline/EOF MUST terminate with a non-zero structured error and, for `clone`, MUST leave the retained checkout available for a later `--resume`.

### Requirement: Clone recovery persists edited config into workspace

After a successful `clone` recovery retry — an affirmed TTY edit-and-retry, or a later `clone --resume` of a retained checkout — the in-container workspace `devcontainer.json` MUST be the edited bytes, not the original file git-populated from the remote. That replacement MUST take effect after in-container populate completes, so a later in-container open MUST NOT require re-applying the recovery edit. Bind `up` recovery MUST remain host-edit only and MUST NOT perform an extra copy of the edited config into the container. `start` recovery MUST continue to delegate to `rebuild` and MUST NOT add a write path for an edited config. When there is no editable `devcontainer.json`, the CLI MUST NOT offer recovery and MUST NOT persist or overlay a config into the workspace.

#### Scenario: successful TTY clone recovery leaves edited workspace config

- Given `clone` failed after an editable config existed, the user affirmed the TTY recovery prompt, and the retained `devcontainer.json` was edited to valid bytes
- When the recovery retry succeeds through in-container populate
- Then the container workspace `devcontainer.json` is those edited bytes, not the original git-populated file

#### Scenario: successful clone --resume leaves edited workspace config

- Given a retained checkout whose `devcontainer.json` already holds the recovery edit
- When `clone --resume <config-dir>` succeeds through in-container populate
- Then the container workspace `devcontainer.json` is those edited bytes, not the original git-populated file

#### Scenario: later in-container open does not require re-fixing

- Given a successful `clone` recovery retry (TTY edit or `--resume`) has completed, including populate
- When the workspace is opened again in that container
- Then `devcontainer.json` is still the edited bytes and the user does not need to re-apply the recovery edit

#### Scenario: bind up recovery stays host-edit only

- Given an eligible `up` failure whose config path is the host checkout
- When the user affirms recovery, edits the host `devcontainer.json`, and retry succeeds
- Then the CLI does not perform an extra copy of the edited config into the container; the host file remains the workspace file

#### Scenario: start recovery adds no write path

- Given a selected managed container and `start` fails
- When recovery is offered
- Then the CLI still delegates to `rebuild` for that container and does not write an edited `devcontainer.json` as part of `start`

#### Scenario: no overlay when there is no editable config

- Given `clone` fails during git fetch before a config exists, or `up` finds no `devcontainer.json`
- When the command exits
- Then the CLI fails with the normal structured error, does not offer recovery, and does not persist or overlay a config into the workspace
