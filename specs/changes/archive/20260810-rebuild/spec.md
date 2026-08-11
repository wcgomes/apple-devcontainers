# Change Spec: rebuild

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Rebuild command surface

The CLI MUST provide a subcommand `adevcontainer rebuild [--name <container>] [--skip-pull] [--vscode] [--json]` that re-creates an existing **managed** container from its current `devcontainer.json`.

**Selection (MUST be identical to `start`)**

- The selection set MUST be managed containers only (`devcontainer.managed=adevcontainer`), resolved via `ManagedContainers.resolveSelection`.
- `--name <container>` MUST select by exact container id or name match; a name matching no managed container MUST fail with a structured `container_not_found`-class error.
- With no `--name` and exactly one managed container, the CLI MUST select it automatically.
- With multiple managed containers and an interactive TTY stdin, the CLI MUST present the interactive numbered picker.
- With multiple managed containers and non-interactive stdin, the CLI MUST fail with a structured `selection_required` error requesting `--name`.
- `-w` / `--workspace` on `rebuild` MUST be a usage error with the existing gate message (`-w is only valid for up`); the existing global gate MUST apply to `rebuild` with no special case.
- Unknown or misspelled flags MUST fail closed per existing usage rules.

**Help surface**

- The main usage text MUST list `rebuild` with its flags.
- `adevcontainer rebuild --help` / `help rebuild` MUST print command-specific help via `printCommandHelp("rebuild")` describing selection, forced-recreate semantics, volume preservation, and the `--vscode` gate.
- The README MUST document `rebuild` (command row, quick-start note, and the volume-preservation/forced-recreate behavior).

#### Scenario: rebuild by name recreates the selected managed container
- Given exactly one managed bind-mode container selected with `--name <that-name>` and an edited `devcontainer.json` at its stamped config path
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the old container is deleted, a new container with the same name is created from the current config, and the command reports success

#### Scenario: rebuild auto-selects the single managed container
- Given exactly one managed container and no `--name`
- When the user runs `adevcontainer rebuild`
- Then the CLI selects that container automatically and proceeds (no picker, no error)

#### Scenario: rebuild interactive picker when multiple
- Given two managed containers and an interactive TTY stdin
- When the user runs `adevcontainer rebuild` without `--name`
- Then the CLI presents the interactive numbered picker and rebuilds the chosen container

#### Scenario: rebuild non-interactive multiple requires --name
- Given two managed containers and non-interactive stdin
- When the user runs `adevcontainer rebuild` without `--name`
- Then the CLI fails with a structured `selection_required`-class error requesting `--name` and must not delete or create anything

#### Scenario: -w on rebuild is usage error
- Given any managed container
- When the user runs `adevcontainer rebuild -w <path>`
- Then the CLI fails usage with the message that `-w is only valid for up` and nothing is deleted or created

#### Scenario: rebuild --name not found fails closed
- Given no managed container named `<unknown>`
- When the user runs `adevcontainer rebuild --name <unknown>`
- Then the CLI fails with a structured not-found error and does not create or delete any resource

#### Scenario: rebuild unknown flag fails closed
- Given any valid rebuild invocation plus an unknown flag
- When the user runs `adevcontainer rebuild <invocation> --not-a-flag`
- Then the CLI fails usage naming the unknown option

---

### Requirement: Rebuild config read (strict dual-mode)

Before any destructive step, `rebuild` MUST read the **current** `devcontainer.json` (committed or not) through the dual-mode mechanism shared with `PostAttachConfigLoader`:

- **Bind mode** (no `devcontainer.workspace_mode=volume` label or `workspace_mode=bind`): resolve from labels `devcontainer.local_folder` + `devcontainer.config_file` on the **host** (same mechanism as `loadBindMode`), using `ConfigResolver.resolve`. If the stamped config file is missing or unreadable, the CLI MUST fail with a structured `config_not_found` error — never a silent nil.
- **Volume mode** (`devcontainer.workspace_mode=volume`): the config lives inside the workspace volume. If the selected container is **stopped**, the CLI MUST first auto-start it with a **bare runtime start** (no lifecycle hooks, no config re-resolve — it will be deleted anyway), then exec `cat` of the stamped config path inside the container (same mechanism as `loadVolumeMode`: exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename` from the stamped `devcontainer.workspace_folder`). If the auto-start or exec-cat fails, or the config is missing/unreadable, the CLI MUST fail with a structured error (`config_not_found` class) **before anything destructive**.
- Parsing/resolution failure of a readable config MUST fail with a structured `config_parse`-class error naming the config path — never a silent nil.
- v1 reads the **stamped** `devcontainer.config_file` path; the config path is assumed never to move. Rebuild MUST NOT re-run `up`-style config discovery to find an alternate path.
- Config read and resolution MUST complete before the old container is deleted.

#### Scenario: bind rebuild picks up current host config
- Given a bind-mode managed container whose stamped host config file now contains a changed `containerEnv` (edited on disk, not committed anywhere else)
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the new container is created from the current on-disk config and carries the changed env

#### Scenario: volume rebuild reads config from inside the workspace volume
- Given a volume-mode managed container whose config file inside the `*-ws` volume was edited since create
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the new container is created from the config read out of the workspace volume (current content) and carries the changed settings

#### Scenario: bind rebuild missing config file fails config_not_found before delete
- Given a bind-mode managed container whose stamped config file was deleted from the host
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with a structured `config_not_found` error and the old container is left untouched

#### Scenario: volume rebuild unreadable config fails before delete
- Given a volume-mode managed container whose config file is missing or unreadable inside the workspace volume
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with a structured `config_not_found` error, nothing is deleted, and the old container remains

#### Scenario: volume rebuild auto-starts stopped container bare before reading
- Given a stopped volume-mode managed container with a readable config inside the volume
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI starts the container with a bare runtime start (no lifecycle hooks executed) before `cat`-reading the config, and then proceeds to delete it and recreate

#### Scenario: volume rebuild parse failure is config_parse
- Given a volume-mode managed container whose in-volume config exists but fails JSONC/JSON parsing (or resolve admission)
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with a structured `config_parse`-class error and the old container is left untouched

#### Scenario: bind rebuild parse failure is config_parse before delete (no recovery)
- Given a bind-mode managed container whose stamped host config exists but fails JSONC/JSON parsing (or resolve admission)
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with a structured `config_parse`-class error, the old container is left untouched, and no recovery session or editor is offered

---

### Requirement: Rebuild identity preservation

The re-created container MUST keep the identity of the selected container:

- **Seeded identity:** bind mode seeds from `devcontainer.local_folder` + `devcontainer.config_file` (re-resolved on host); volume mode seeds from `devcontainer.git_url` + `devcontainer.config_file` (+ `devcontainer.workspace_volume`, `devcontainer.workspace_folder`).
- The re-created container MUST use the **same container name** as the selected container, and (volume mode) MUST mount the **same workspace volume** (`*-ws`).
- Stamps that define identity — `devcontainer.managed`, `devcontainer.workspace_mode`, `devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.git_url`, `devcontainer.workspace_volume` — MUST remain identical to the selected container's values.
- Only `devcontainer.config_hash` and labels derived from the newly resolved config (`devcontainer.workspace_folder`, `devcontainer.remote_user`, `devcontainer.config_volumes`) MAY change to the freshly resolved values.
- Rebuild MUST proceed even when the resolved config hash **equals** the stamped `devcontainer.config_hash` (it is a user-forced recreate, not drift detection; derived Features tag reuse makes the unchanged case cheap). There MUST be no skip/abort solely for hash equality.

#### Scenario: bind rebuild keeps name and updates hash labels
- Given a bind-mode managed container with name `adev-{base}-{hash12}` created from a workspace+config path
- When the user runs `adevcontainer rebuild --name <that-name>` after editing the config
- Then the new container has the same name `adev-{base}-{hash12}` and a `devcontainer.config_hash` matching the current config, with managed/workspace_mode/local_folder/config_file labels unchanged

#### Scenario: volume rebuild keeps name and workspace volume
- Given a volume-mode managed container with name `adev-{base}-{hash12}` and workspace volume `adev-{base}-{hash12}-ws`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the new container has the same name and its workspace mount is the same `*-ws` volume (labels `git_url` and `workspace_volume` unchanged)

#### Scenario: equal config hash still rebuilds
- Given a managed container whose current resolved config hash equals the stamped `devcontainer.config_hash`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI still deletes and re-creates the container (forced recreate) and reports success

#### Scenario: derived labels refresh to new resolved values
- Given a managed container whose edited config changes `workspaceFolder`, `remoteUser`, or adds a `type=volume` mount
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the new container's `devcontainer.workspace_folder` / `devcontainer.remote_user` / `devcontainer.config_volumes` labels match the new resolved values while identity stamps stay fixed

---

### Requirement: Rebuild volume preservation invariant

The volume-preservation invariant is the core contract of `rebuild`:

- Rebuild MUST **not** delete, recreate, or re-populate the workspace `*-ws` volume (volume mode).
- Rebuild MUST **not** delete any config `type=volume` named volume (both modes).
- On a successful rebuild, the only pre-create deletion MUST be the **old container itself**, following the existing container-only `delete` contract (stop first if required). On a post-delete failure, recovery MAY additionally delete the failed **new container** and (volume path only) the marked recovery helper as container-only cleanup. No workspace volume, config volume, or image deletion is part of rebuild or recovery. Bind recovery MUST NOT create or delete a recovery helper.
- Create MUST reuse existing named volumes: the runtime `ensureVolume` list-then-reuse behavior applies to the workspace `*-ws` volume and to every config `type=volume` source — existing volumes are reused (status indicating reuse), missing ones are created, and existing ones MUST NOT be recreated.
- Newly declared config volumes (added to the edited config) MUST be created and mounted; volumes removed from the edited config MUST NOT be deleted by rebuild (they are simply no longer mounted; `prune` remains the removal path).
- Rebuild MUST NOT run git re-clone or `git pull` inside the workspace volume (no populate step).

#### Scenario: rebuild preserves workspace volume data
- Given a volume-mode managed container whose `*-ws` volume contains a file `data/keep.txt` written after create
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the rebuild succeeds and `data/keep.txt` is still present in the same `*-ws` volume (no delete/recreate/re-populate)

#### Scenario: rebuild preserves config named volumes
- Given a managed container (bind or volume) with a config `type=volume` mount whose source volume contains data
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the config named volume still exists with its data and is mounted on the new container

#### Scenario: successful rebuild deletes only the old container
- Given a volume-mode managed container, its `*-ws` volume, and two config named volumes
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the runtime is asked to delete the old container (by name) for the replacement and is never asked to delete the `*-ws` volume or any config named volume; any later failure cleanup is limited to container-only deletion of the failed new container/helper

#### Scenario: rebuild creates newly declared config volume
- Given a managed container whose edited config adds a `type=volume` mount `new-vol` that does not exist
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `new-vol` is created and mounted, and all pre-existing volumes are reused

#### Scenario: rebuild does not re-clone or pull in the volume
- Given a volume-mode managed container with a populated `*-ws` volume
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then no git clone and no `git pull` is executed inside the workspace volume during rebuild

---

### Requirement: Rebuild pre-delete ordering gate

The follow-up failure surface of `rebuild` MUST be split at the delete of the old container. For a clone-origin volume target eligible for helper-based recovery, the recovery helper image and raw-config recovery session MUST also be prepared before that delete. Bind-mode recovery MUST NOT require helper-image preflight or volume raw-config capture before delete.

**Before delete (non-destructive gate)**

- In order: selection and stamp read → strict config read and resolution (see Rebuild config read) → for a clone-origin volume target only, capture the raw in-volume config into the secure recovery session and preflight the immutable arm64-pinned Alpine recovery helper image → `hostRequirements` preflight (fail on capacity shortfall, unreadable host, or parse/unknown keys per existing preflight) → when resolved features are non-empty, the build.rosetta consent gate + Features fetch/build (derived tag `adev-{base}:{hash12}` reuse when base image + features material is unchanged); `--skip-pull` honored (no pull invoked when set).
- Any failure in this span MUST fail `rebuild` with a structured error and MUST leave the old container **running/untouched** (no delete). Pre-delete failures MUST NOT offer recovery in either mode.

**After delete**

- Once the old container is deleted, create-path failures MUST first delete the **new** container (delete-on-fail) and MUST surface a structured failure plus a status warning that the old container was already removed.
- For an eligible **clone-origin volume** target, new-container create failure, new-container start failure, and non-zero `onCreate`, `updateContent`, `postCreate`, or `postStart` failure MUST additionally offer the **volume recovery session** defined below after failed-container attachment cleanup is verified.
- For an eligible **bind-mode** target, the same hard post-delete failure set MUST additionally offer the **bind recovery session** defined below after failed-container cleanup is verified. Bind recovery MUST NOT create a recovery helper, MUST NOT preflight or pull a helper image, and MUST NOT perform volume mount or atomic helper write operations.
- A TTY session (without `--json`) MUST first print the structured failure, then prompt whether to open the recovery editor (default Y); affirmative MAY continue into the editor loop and a successful retry; decline/EOF/non-affirmative or recovery failure remains non-zero with retained recovery details (same quality as non-TTY retain). Non-TTY/`--json` returns the structured failure with retained recovery details and MUST never prompt or open an editor (volume: helper/temp; bind: host path + retry commands only).
- Volume targets without clone-origin stamps retain the warning-only post-delete behavior and MUST NOT create a recovery helper or bind-style recovery session.
- Settings/extension soft-fail, VS Code open soft-fail, and `postAttach` failure MUST retain their existing semantics and MUST NOT enter either recovery session.
- The command MUST NOT report success after the old container was deleted unless the new container completed its lifecycle.

#### Scenario: hostRequirements shortfall fails before delete
- Given a managed container and a config whose `hostRequirements.memory` exceeds host capacity
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `rebuild` fails with a structured hostRequirements error and the old container is still present (not deleted)

#### Scenario: features build failure fails before delete
- Given a managed container whose config has features and the rosetta consent is declined or the derived image build fails
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `rebuild` fails with a structured error and the old container is still present (not deleted)

#### Scenario: bind hard post-delete failure offers bind recovery (not helper)
- Given a bind-mode managed container whose edited config's `postCreateCommand` exits non-zero
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the old container is deleted, the new container's create-path hook fails, the **new** container is deleted (delete-on-fail), the command fails structured with a warning that the old container was already removed, no recovery helper is created, and bind recovery is offered (TTY: structured failure then open-editor prompt then optional host-path editor; non-TTY/JSON: structured host-path details only, never prompt or editor)

#### Scenario: --skip-pull honored on rebuild
- Given a managed container and a config whose image would normally be pulled on create
- When the user runs `adevcontainer rebuild --name <that-name> --skip-pull`
- Then no `container image pull` is invoked during rebuild and rebuild proceeds with the locally available image

---

### Requirement: Volume-mode recovery session after post-delete provisioning failure

`rebuild` MUST offer a **helper-based** recovery session only for a selected managed **clone-origin volume-mode** container. In v1, clone origin is established by the existing identity stamps `devcontainer.managed=adevcontainer`, `devcontainer.workspace_mode=volume`, a non-empty `devcontainer.git_url`, a non-empty `devcontainer.workspace_volume`, and a stamped `devcontainer.config_file`. Bind-mode containers MUST use the bind recovery session requirement instead of this requirement. Volume-mode targets without those clone-origin stamps MUST NOT enter this recovery flow.

For an eligible volume target, `rebuild` MUST prepare the recovery capability before deleting the old container:

- An immutable, lightweight Alpine helper image pinned to `linux/arm64` MUST be verified available (pulling it before the delete when permitted by the command's normal image policy). If it is unavailable or cannot be verified, `rebuild` MUST fail with a structured recovery-unavailable error before deleting the old container.
- The exact raw bytes read from the in-volume stamped config MUST be retained in a secure host recovery session before the delete. The session directory MUST be private to the invoking user (`0700`) and the config file MUST be private (`0600`); the raw bytes MUST NOT be placed in labels, progress output, or JSON fields.

Recovery MUST be offered only for these hard post-delete provisioning failures: failure to create the new container, failure to start the new container, or a non-zero `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, or `postStartCommand`. Volume ensure/writable-step failures and every other post-delete failure not listed here MUST retain the existing structured failure/warning behavior and MUST NOT create a recovery helper. Before a helper is mounted, any failed new container MUST be cleaned up and the runtime MUST verify that it is no longer attached to the workspace volume. A failed hook MAY have modified workspace data; recovery restores edit access and retry capability, not filesystem transaction rollback or image rollback.

The recovery helper MUST run from the pinned helper image, mount the exact existing `devcontainer.workspace_volume` (`*-ws`) read-write at the effective workspace path, and MUST NOT delete, recreate, or repopulate that workspace volume or any config named volume. It MUST retain the selected container's name and managed identity labels, add a visible recovery marker such as `devcontainer.recovery=adevcontainer`, and remain addressable by `exec --name` and `rebuild --name`. Ordinary `list` MUST visibly mark the helper as recovery. Ordinary `prune` MUST protect a marked recovery helper and its referenced volumes. These list/prune helper rules apply **only** to volume recovery helpers; bind recovery MUST NOT create a marked helper and therefore MUST NOT depend on list/prune helper protection.

**TTY recovery (prompt-then-editor):** When stdin is a TTY and `--json` is absent, the CLI MUST **not** auto-open an editor. It MUST:

1. Print the structured failure / failure reason clearly on stderr (hook exit, create fail, etc.) with the same information quality as the non-TTY retain path for this mode.
2. Prompt whether to open the recovery editor now. The prompt MUST use default **Y** (open editor): Enter alone or an affirmative answer (`y`, `Y`, or yes-class) confirms; `n`, `N`, or no-class declines. Prompt wording and stdin line-read HOW are shared with bind recovery (see design).
3. On affirmative: select the first usable editor in this order: `$VISUAL`, `$EDITOR`, `/usr/bin/nano`, `/usr/bin/vi`. Open the secure host temp file, validate the edited bytes with the same volume-mode config resolution and admission rules (including the stamped workspace-folder basename), write valid bytes atomically into the existing workspace volume through the helper, verify readback, and retry the rebuild. Invalid config MUST be reported and the editor MUST be reopened; the loop MUST continue until a retry succeeds or the user cancels (editor interrupt/EOF). Editor cancellation MUST retain the helper and secure temp session and return structured recovery details rather than deleting a volume.
4. On decline, EOF on the prompt, or any non-affirmative answer: treat as defer of the immediate editor loop. The CLI MUST retain the helper and secure temp session, print the same structured recovery details and exact shell-quoted edit, `adevcontainer rebuild --name ...` retry, and container-only-delete/temp-file cleanup commands as the non-TTY retain path, and exit non-zero. It MUST NOT open an editor and MUST NOT delete recovery state solely because the operator deferred.

**Non-TTY and `--json`:** The CLI MUST never launch an editor or prompt (including the open-editor-now prompt). It MUST leave the helper running and secure temp file available and return structured recovery details containing the helper identity, workspace volume, config path, session/temp path (and conflict-file path when applicable), failure reason, and exact shell-quoted edit, `adevcontainer rebuild --name ...` retry, and container-only-delete/temp-file cleanup commands. A later named retry MUST write the edited temp file to the volume and verify it before `rebuild` reads the config; it MUST NOT delete the helper before that write unless the command continues in the same interactive flow.

Safe write-back MUST use a same-directory temporary file in the helper and an atomic replacement of the existing config path. The helper MUST read the replacement back and compare its content hash with the validated host file. If the volume content has changed from the session's expected baseline, the CLI MUST preserve the current volume bytes in a second secure conflict file, retain the edited temp file, and report a structured recovery-conflict error without overwriting the volume or deleting any volume. TTY recovery MUST reopen the editor with the conflict visible; non-TTY/JSON MUST require the next explicit named retry to acknowledge the captured baseline before applying the retained edit.

After a retry completes the full lifecycle successfully, the CLI MUST read the stamped config through the successful final container and verify that its content/hash equals the edited bytes before reporting recovery success. Because the final container already mounts the same workspace volume, a redundant post-success copy is neither required nor permitted as a separate recovery step. The helper MUST be removed container-only at the retry's own delete gate, after the edited bytes have been written/read back and the retry's pre-delete checks have succeeded; a later retry MUST never delete it before those steps. After final-container verification, the CLI MUST ensure no helper remains and MUST remove the secure temp session. Helper creation, start, failed-container cleanup/verification, write-back, readback, final verification, or cleanup failure MUST return a structured recovery-unavailable or rollback-style error without deleting the workspace or config named volumes.

#### Scenario: volume-only recovery session is offered for a hard create failure
- Given a clone-origin volume-mode managed container with an existing `*-ws` volume and an edited config that causes new-container creation to fail after the old container is deleted
- When `adevcontainer rebuild --name <that-name>` reaches the post-delete failure
- Then the failed new-container attachment is cleaned and verified, a marked helper with the same identity/name mounts the existing `*-ws` volume read-write, and the command enters TTY recovery (structured failure then open-editor prompt) or returns non-TTY/JSON recovery details without deleting or recreating any volume

#### Scenario: volume TTY recovery prints failure then prompts before editor
- Given an eligible volume hard post-delete failure on a TTY without `--json`
- When recovery is offered
- Then the CLI first prints the structured failure/reason on stderr, then prompts to open the recovery editor now with default Y, and does not launch an editor before that prompt is answered

#### Scenario: volume TTY affirmative prompt opens editor then existing edit loop
- Given an eligible volume TTY recovery session after the open-editor prompt
- When the operator answers affirmatively (Enter or y/Y/yes-class)
- Then the CLI selects an editor per fixed precedence, opens the secure host temp file, and continues the existing validate/atomic-write/retry loop

#### Scenario: volume TTY decline or EOF defers with retained helper and retry instructions
- Given an eligible volume TTY recovery session after the structured failure is printed
- When the operator answers n/N/no-class, or the prompt reads EOF
- Then no editor is launched, the marked helper and secure temp session remain, the CLI prints the same structured recovery details and exact edit/`adevcontainer rebuild --name <helper-name>`/cleanup commands as non-TTY retain, and the command exits non-zero

#### Scenario: editor selection follows the fixed precedence
- Given an eligible TTY recovery session (volume or bind) where the operator affirmed the open-editor prompt, `$VISUAL` is unusable, `$EDITOR` is usable, and `/usr/bin/nano` and `/usr/bin/vi` are present
- When recovery starts an edit attempt
- Then it invokes `$EDITOR` and does not invoke either fallback; if `$EDITOR` is unusable it tries `/usr/bin/nano`, then `/usr/bin/vi`, in that order

#### Scenario: helper image is preflighted before deletion
- Given an eligible clone-origin volume container and an arm64-pinned Alpine helper image that cannot be verified or made available
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then rebuild fails with a structured recovery-unavailable error before deleting the old container, leaves the old container untouched, and makes no helper or volume mutation

#### Scenario: safe atomic copy and readback protects the in-volume config
- Given a running recovery helper, a valid edited temp file, and an unchanged workspace-volume config hash
- When recovery writes the edited file back
- Then bytes are written through the helper to a same-directory temporary file and atomically replaced at the stamped config path, the target is read back and has the expected hash, and no volume delete, volume create, or partial target write is used

#### Scenario: TTY recovery writes before retry and can complete in one flow
- Given an eligible volume recovery session on a TTY where the operator affirmed the open-editor prompt and an editor result that resolves successfully
- When recovery applies the edit and retries rebuild
- Then the edited bytes are written to and verified in the workspace volume before the retry reads config, the helper is removed only as part of the retry's controlled replacement, and the flow continues through the normal rebuild lifecycle

#### Scenario: non-TTY and JSON recovery never prompt or edit
- Given an eligible hard post-delete provisioning failure on a clone-origin volume target and either non-interactive stdin or `--json`
- When rebuild returns the failure
- Then no editor process and no open-editor prompt is launched, the marked helper and secure temp file remain, and the structured result includes the session details plus exact edit, `adevcontainer rebuild --name <helper-name>`, and container-only-delete/temp cleanup commands

#### Scenario: recovery helper preserves identity and safe selection
- Given a recovery helper created for a failed container named `<name>`
- When the user runs `list`, `exec --name <name>`, `rebuild --name <name>`, or `prune`
- Then `list` visibly marks the helper as recovery, `exec` can target it, named rebuild selects it as the recovery session endpoint, and ordinary `prune` skips the helper and all its referenced volumes

#### Scenario: recovery preserves volumes and does not roll back workspace data
- Given a failed create-path hook that changed a workspace file before exiting non-zero
- When recovery is offered and a later retry succeeds
- Then the exact existing workspace `*-ws` volume and all config named volumes remain present with their data, no clone/repopulate or volume delete/recreate occurs, and the hook's filesystem changes are not claimed to be rolled back

#### Scenario: helper or attachment cleanup failure is recovery-unavailable
- Given an eligible hard failure where the failed new container cannot be detached/verified, or helper creation/start/write-back/cleanup fails
- When recovery attempts to establish or complete the session
- Then rebuild returns a structured recovery-unavailable or rollback-style error, leaves the secure session when possible, and does not delete the workspace or config named volumes

#### Scenario: invalid config retries without writing an invalid file
- Given a TTY volume recovery session whose edited temp file fails JSONC parsing, admission, or resolution
- When the editor exits with that invalid content
- Then the CLI reports the structured validation error, does not write the invalid bytes to the volume and does not start rebuild, and reopens the editor until the user supplies valid content or cancels

#### Scenario: successful retry verifies final-container visibility before cleanup
- Given a valid edited config has been atomically written and read back from the workspace volume
- When the retried rebuild creates and completes the final container lifecycle
- Then the final container reads the same edited content/hash through its normal config path, rebuild reports success only after that verification, no helper remains, and the secure temp session is removed; no redundant copy is performed because both containers mount the same volume

#### Scenario: soft failures and non-clone volume failures do not offer recovery
- Given either a volume ensure/writable-step failure, a non-clone volume hard post-delete failure, a settings/extension soft-fail, a VS Code open soft-fail, or a `postAttachCommand` failure
- When the failure is reported
- Then existing rebuild behavior remains in force (hard-failure warning/delete-new, soft-fail success/status, or postAttach fail-keep respectively), no recovery editor/helper is launched, and no recovery prompt is shown

#### Scenario: volume recovery path unchanged when bind recovery exists
- Given a clone-origin volume-mode hard post-delete failure
- When recovery is offered
- Then the volume helper-based session still applies (helper image, secure temp, atomic write-back, list/prune protection) and bind host-path editing is not substituted for the volume path

---

### Requirement: Bind-mode recovery session after post-delete provisioning failure

`rebuild` MUST offer a **host-editor** recovery session for a selected managed **bind-mode** container after the same hard post-delete provisioning failures as volume recovery. Bind origin is established by managed stamps without `devcontainer.workspace_mode=volume` (or with `workspace_mode=bind`) plus non-empty stamped `devcontainer.local_folder` and `devcontainer.config_file`.

Bind recovery MUST NOT:

- Create a recovery helper container
- Preflight, pull, or run an Alpine (or any) recovery helper image
- Mount a workspace volume for editing
- Perform atomic helper write-back or `container cp`
- Attach `devcontainer.recovery` (or related) labels to any container
- Depend on list/prune helper protection rules

Recovery MUST be offered only for these hard post-delete provisioning failures: failure to create the new container, failure to start the new container, or a non-zero `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, or `postStartCommand`. Every other post-delete failure not listed here MUST retain the existing structured failure/warning behavior and MUST NOT start bind recovery. Before recovery starts, any failed new container MUST be cleaned up (delete-on-fail). A failed hook MAY have modified host workspace files under the bind mount; recovery restores edit access and retry capability, not filesystem transaction rollback or image rollback.

The edit target MUST be the **host stamped config path** formed from `devcontainer.local_folder` + `devcontainer.config_file` (the same path the bind-mode strict reader uses). The implementation MUST prefer editing that path **directly**. A private temp copy of the edit target is NOT required for bind recovery. Session metadata MAY optionally record baseline hashes or conflict notes without inventing a helper write path; if baseline tracking is implemented, it MUST NOT change the editor target away from the host stamped path unless a true conflict-handling path is needed, and even then the operator-facing edit path remains the host stamped file.

**TTY recovery (prompt-then-editor):** When stdin is a TTY and `--json` is absent, the CLI MUST **not** auto-open an editor. It MUST:

1. Print the structured failure / failure reason clearly on stderr with the same information quality as the non-TTY retain path for bind recovery.
2. Prompt whether to open the recovery editor now using the **same** default-Y prompt wording and stdin line-read contract as volume recovery (shared HOW in design).
3. On affirmative: select the first usable editor in this order: `$VISUAL`, `$EDITOR`, `/usr/bin/nano`, `/usr/bin/vi` (same precedence as volume recovery). Open the host stamped config path, validate the edited bytes with the same **bind-mode** strict config resolution and admission rules used by rebuild's bind reader, and retry the rebuild when validation succeeds. Invalid config MUST be reported and the editor MUST be reopened; the loop MUST continue until a retry succeeds or the user cancels (editor interrupt/EOF). Editor cancellation MUST leave the host file as the user left it, MUST NOT create or retain a helper, and MUST return structured recovery details (host path + retry command) rather than inventing helper cleanup.
4. On decline, EOF on the prompt, or any non-affirmative answer: treat as defer of the immediate editor loop. The CLI MUST retain recovery state for later retry (host stamped file as left; any resume stamps), print the same structured recovery details and exact shell-quoted edit hint plus `adevcontainer rebuild --name ...` retry as the non-TTY retain path, and exit non-zero. It MUST NOT open an editor and MUST NOT invent helper cleanup.

**Non-TTY and `--json`:** The CLI MUST never launch an editor or prompt (including the open-editor-now prompt). It MUST return structured recovery details containing at least: host config path, selected container name/id, failure kind/classification, and exact shell-quoted edit hint for the host path plus `adevcontainer rebuild --name ...` retry. Cleanup commands, when present, MUST NOT mention helper delete, volume delete, or prune of a recovery helper. There is no helper identity, workspace volume field, or secure temp path required for bind recovery details (those fields are volume-only).

After a successful TTY edit (post-affirmative prompt), the retry MUST read config from the host stamped path through the normal bind-mode strict reader (the edited bytes are already there). Final success follows the normal rebuild lifecycle; no helper cleanup step applies. Editor launch failure after candidate resolution MUST return a structured recovery-unavailable error aligned with existing recovery codes where applicable. Editor-loop cancellation MUST use a structured recovery-cancelled outcome when the TTY loop is abandoned after the editor was opened. Prompt defer (decline/EOF) MUST exit non-zero with retained structured recovery details equivalent to non-TTY retain (recovery-cancelled or an equivalent deferred-recovery classification is acceptable if documented in design; it MUST NOT delete retained state).

#### Scenario: bind TTY recovery after postCreate failure prints failure then prompts before editor
- Given a bind-mode managed container whose stamped host config's `postCreateCommand` exits non-zero after the old container is deleted
- When `adevcontainer rebuild --name <that-name>` reaches the post-delete failure on a TTY without `--json`
- Then the failed new container is deleted, no recovery helper is created, the CLI first prints the structured failure/reason on stderr, then prompts to open the recovery editor now with default Y, and does not launch an editor before that prompt is answered

#### Scenario: bind TTY affirmative prompt opens host stamped path
- Given a bind TTY recovery session after the open-editor prompt
- When the operator answers affirmatively (Enter or y/Y/yes-class)
- Then the CLI opens an editor on the host stamped config path (`local_folder` + `config_file`), validates with bind-mode strict rules, and on valid edit retries rebuild without volume ops or helper labels

#### Scenario: bind TTY decline or EOF defers with retained host path and retry instructions
- Given a bind TTY recovery session after the structured failure is printed
- When the operator answers n/N/no-class, or the prompt reads EOF
- Then no editor is launched, no recovery helper is created, the host file remains as left, the CLI prints the same structured recovery details (host path, failure kind, shell-quoted edit hint, `adevcontainer rebuild --name <name>` retry) as non-TTY retain, and the command exits non-zero

#### Scenario: bind TTY invalid config reopens editor without starting rebuild
- Given a bind TTY recovery session where the operator already affirmed the open-editor prompt and whose host stamped file fails JSONC parsing, admission, or resolution after the editor exits
- When validation fails
- Then the CLI reports the structured validation error, does not start rebuild, and reopens the editor until the user supplies valid content or cancels

#### Scenario: bind TTY editor cancel retains host file only
- Given a bind TTY recovery session where the editor was already opened after an affirmative prompt
- When the user cancels via editor interrupt/EOF
- Then the command exits non-zero with structured recovery-cancelled (or equivalent) details including the host config path and `rebuild --name` retry, no helper exists, and the host file remains as the user left it

#### Scenario: bind non-TTY and JSON recovery never prompt or edit
- Given a bind-mode hard post-delete provisioning failure and either non-interactive stdin or `--json`
- When rebuild returns the failure
- Then no editor process and no open-editor prompt is launched, no recovery helper is created, and the structured result includes the host config path, failure kind, shell-quoted edit hint for that path, and `adevcontainer rebuild --name <name>` retry, with no helper-delete cleanup command

#### Scenario: bind pre-delete parse still no recovery
- Given a bind-mode managed container whose stamped host config fails parse before the old container is deleted
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with `config_parse`, the old container is untouched, and no recovery editor or recovery details for post-delete recovery are offered

#### Scenario: bind recovery does not create helper or recovery labels
- Given any bind-mode eligible hard post-delete failure
- When recovery is offered or completed (TTY or non-TTY)
- Then the runtime is never asked to create a recovery helper, no container receives `devcontainer.recovery` labels, no Alpine helper image is preflighted solely for bind recovery, and list/prune helper rules are not exercised for that session

#### Scenario: bind recovery shares failure matrix with volume recovery
- Given a bind-mode managed container
- When new-container create, new-container start, or any of `onCreate`/`updateContent`/`postCreate`/`postStart` fails after old-container deletion
- Then bind recovery is offered
- When settings/extension soft-fail, VS Code open soft-fail, or `postAttach` fails
- Then bind recovery is not offered and existing soft-fail / fail-keep semantics remain

---

### Requirement: Rebuild create-path parity

After the old container is deleted, `rebuild` MUST run the full create-path matrix like a fresh `up`/`clone` create on the **new** container:

- Create uses the derived image when resolved features are non-empty (host-native platform, same rosetta consent gate and derived-tag reuse as `up`/`clone`), else the config `image`.
- Lifecycle hooks onCreate → updateContent → postCreate → postStart run via runtime exec; non-zero exit of any create-path hook MUST follow delete-on-fail (of the new container) per the after-delete policy and MUST then offer the mode-appropriate recovery session (volume helper session for clone-origin volume; bind host-editor session for bind mode).
- Settings apply (`customizations.vscode.settings`) runs after create-path hooks and is **not** gated on `--vscode` (soft-fail semantics unchanged); settings failure MUST NOT start recovery.
- `--vscode`: after lifecycle success, best-effort open; on open **success**, extensions apply then the postAttach gate runs (config then feature postAttach via exec, fail-keep on non-zero); on open soft-fail or absent flag, postAttach is skipped with status when present — identical to `up`/`clone`. Open soft-fail and postAttach failure MUST NOT start recovery.
- **Volume mode only:**
  - The features list MUST be passed through `FeatureGitEnsure.ensurePresent` (re-inject `ghcr.io/devcontainers/features/git:1` when neither `git` nor `common-utils` is admitted, clone parity) before the Features gate; no double-add when already covered.
  - `ensureWorkspaceWritableByRemoteUser` MUST run only when the effective `remoteUser` of the newly resolved config **differs** from the stamped `devcontainer.remote_user`; when equal, it MUST be skipped (existing tree is left as is).
  - `CreateRequest.fromVolumeMode` MUST set `enableSSHForward` only when a host ssh-agent is present (`SSH_AUTH_SOCK` set and non-empty) — parity with the clone HTTPS branch; absence of an agent MUST NOT fail rebuild (no clone occurs on rebuild).
- Bind mode uses the standard `CreateRequest.from` with the preserved host workspace bind.

#### Scenario: bind rebuild runs full create-path hooks on the new container
- Given a bind-mode managed container whose edited config has `postStartCommand` and `postCreateCommand`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then after create/start the hooks run on the new container in the fresh-create order (onCreate → updateContent → postCreate → postStart) and rebuild reports success

#### Scenario: volume rebuild re-injects git feature
- Given a volume-mode managed container whose edited in-volume config has no `git`/`common-utils` feature
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `FeatureGitEnsure.ensurePresent` appends `ghcr.io/devcontainers/features/git:1` and the Features path sees the injected feature (no second git feature when already covered)

#### Scenario: volume rebuild writable step runs only when remoteUser changed
- Given a volume-mode managed container whose stamped `devcontainer.remote_user` equals the newly resolved remote user
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `ensureWorkspaceWritableByRemoteUser` is not invoked
- Given a volume-mode managed container whose edited config changes `remoteUser` to a different user
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `ensureWorkspaceWritableByRemoteUser` runs against the new effective user

#### Scenario: volume rebuild ssh forward only with agent
- Given a volume-mode managed container and host `SSH_AUTH_SOCK` unset or empty
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the create request is built with `enableSSHForward: false` and rebuild does not fail solely for the missing agent
- Given the same container and host `SSH_AUTH_SOCK` set and non-empty
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the create request is built with `enableSSHForward: true` (create argv includes `--ssh` unless already in runArgs)

#### Scenario: rebuild --vscode gates extensions and postAttach
- Given a managed container whose config has extensions and `postAttachCommand`, and host `code` launch succeeds (or mocks equivalent)
- When the user runs `adevcontainer rebuild --name <that-name> --vscode`
- Then after lifecycle success the CLI opens VS Code, applies extensions after open success, then runs postAttach (config then feature), and rebuild reports success when postAttach exits 0

#### Scenario: settings apply not gated on rebuild
- Given a managed container whose edited config has well-formed `customizations.vscode.settings`
- When the user runs `adevcontainer rebuild --name <that-name>` without `--vscode`
- Then settings apply runs after create-path hooks (soft-fail) and rebuild reports success

#### Scenario: create-path hook failure deletes the new container and offers mode-appropriate recovery
- Given a managed container whose edited config's `onCreateCommand` exits non-zero
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the **new** container is deleted (delete-on-fail), the old container was already removed (warning), and the workspace volume and config volumes remain; if the target is clone-origin volume mode, a marked recovery helper/session is offered after attachment verification; if the target is bind mode, bind host-editor recovery is offered with no helper; otherwise the structured failure is returned with no recovery session
- And a TTY flow MAY retry to success

---

### Requirement: Rebuild output and exit parity

`rebuild` MUST emit output and exits with parity to `up`/`clone`:

- Success with `--json` MUST print machine-readable JSON on stdout with at least `outcome`, `containerId`, `remoteUser`, and `remoteWorkspaceFolder` (up-parity shape); a volume-mode rebuild MAY additionally include `gitUrl` and `workspaceVolume` (clone-parity fields). The `containerName` field MAY be included.
- Human success output MUST mirror `up`'s lines (outcome, containerId, remoteUser, remoteWorkspaceFolder, optional containerName).
- Progress/status lines MUST go to stderr via `StatusPrinter` norms; `ADEVCONTAINER_QUIET=1` silences them; `--json` keeps stdout pure.
- Failure MUST exit non-zero with the existing structured error path (no success JSON on stdout for `--json` invocations). An eligible non-TTY or `--json` post-delete hard failure MUST include the structured recovery details and exact edit/retry/cleanup commands defined by the mode-appropriate recovery session requirement (volume helper details vs bind host-path details).
- Exit codes: 0 on success, non-zero on any failure.

#### Scenario: rebuild --json success shape for bind
- Given a successful bind-mode rebuild invoked with `--json`
- When the machine-readable result is parsed
- Then it includes `outcome`, `containerId`, `remoteUser`, and `remoteWorkspaceFolder` and stdout contains no progress lines

#### Scenario: rebuild --json success shape for volume mode
- Given a successful volume-mode rebuild invoked with `--json`
- When the machine-readable result is parsed
- Then it includes the up-shape fields and MAY include `gitUrl` and `workspaceVolume` identifying the preserved volume

#### Scenario: rebuild failure exits non-zero with structured error
- Given a rebuild that fails (e.g. `config_not_found` or a post-delete hook failure)
- When the command returns
- Then the exit code is non-zero, stderr carries the structured error, and no success JSON is printed on stdout

---

## MODIFIED Requirements

### Requirement: Unified managed selection for lifecycle commands

*(Delta only — replace the selection table and the `-w` gate sentence; other content unchanged.)*

Lifecycle commands share **one** selection model. Only `up` accepts `-w` / `--workspace`.

| Command | Selection |
|---------|-----------|
| `up` | `-w` / `--workspace` (default cwd) — bind-mode create/start/reuse |
| `exec`, `stop`, `delete`, `prune`, `inspect`, `start`, `rebuild` | `ManagedContainers.resolveSelection(name:)` only — `--name` and/or interactive picker over `devcontainer.managed=adevcontainer` |
| `clone`, `list`, `doctor` | no `-w` (unchanged) |

If the user passes `-w` / `--workspace` on any non-`up` command (including `rebuild`), the CLI MUST fail with a structured **usage** error whose message includes that `-w is only valid for up` (clearer than silently ignoring).

`rebuild` is the **sole forced recreate** path: `up` has no `--recreate` flag. On config-hash mismatch, `up` MUST fail with `config_hash_mismatch` and a hint pointing to `adevcontainer rebuild` (managed selection `--name`/auto when applicable). `rebuild` MUST recreate the selected managed container even when the resolved config hash equals the stamped `devcontainer.config_hash`, and MUST preserve the workspace volume and config named volumes (container-only delete then create).

#### Scenario: rebuild is selectable like other lifecycle commands
- Given a running managed container (bind or volume) with `devcontainer.managed=adevcontainer`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the rebuild targets that managed container through the same resolution rules as `start`/`stop`/`delete`

#### Scenario: -w on rebuild is usage error
- Given any rebuild invocation including `-w <path>`
- When the user runs the command
- Then the CLI fails usage with a message that `-w is only valid for up`

#### Scenario: rebuild multiple non-interactive requests --name
- Given two managed containers and non-interactive stdin
- When the user runs `adevcontainer rebuild` without `--name`
- Then the CLI fails with the `selection_required`-class structured error requesting `--name` (same as `start`)

---

### Requirement: Up lifecycle (create, start, reuse)

*(Delta only — replace the drift/recreate policy sentence and add the matrix row; other rows unchanged.)*

**Recreate/drift policy**

`up` reuses a running or stopped container with matching identity. When the config/features hash drifts (stamped `devcontainer.config_hash` ≠ resolved hash), `up` MUST fail closed with structured `config_hash_mismatch` and MUST NOT delete or recreate; the error hint MUST point to `adevcontainer rebuild` (managed selection: `--name` or auto when applicable). There is no `up --recreate` flag; unknown `--recreate` MUST fail as an unknown option (usage). Equal-hash force recreate and volume-preserving forced recreate are **only** via `rebuild`: an **explicit user-forced recreate** that MUST NOT require hash drift and MUST preserve volumes — it reads the current config, completes resolution/preflight/Features work first, deletes the old container **only** (container-only delete), and creates the new container reusing the existing workspace volume and config named volumes (see Rebuild requirements).

**Lifecycle hook matrix by path** (new row; existing rows unchanged)

| Path | Lifecycle |
|------|-----------|
| `rebuild <name>` (forced recreate after container-only delete of the old container) | full fresh create-path onCreate → updateContent → postCreate → postStart on the **new** container; delete-on-fail applies to the **new** container; the old container was already removed (status warning on post-delete failure); a clone-origin volume failure in create/start/create-path hooks additionally offers the volume recovery session; a bind-mode failure in the same set offers the bind host-editor recovery session; non-clone volume targets retain warning-only behavior |

postAttach gating applies on `rebuild` exactly as on `up`/`clone` (after successful `--vscode` open; skip with status otherwise; failure keeps the new container). Settings/open soft-fail and postAttach failure MUST NOT enter either recovery session.

#### Scenario: rebuild hook matrix row applies
- Given a managed container being rebuilt with a config carrying all four create-path hooks
- When `rebuild` runs the fresh create-path on the new container
- Then onCreate → updateContent → postCreate → postStart execute in order on the new container, and a first-hook failure deletes only the new container

#### Scenario: rebuild does not require hash drift
- Given a managed container whose current config hash equals the stamped hash
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then rebuild recreates the container (no hash-mismatch precondition), unlike `up` reuse which would have kept the running container

#### Scenario: up hash mismatch hints rebuild
- Given a managed bind-mode container whose stamped `devcontainer.config_hash` does not match the resolved config hash
- When the user runs `adevcontainer up` for that workspace
- Then the CLI fails with `config_hash_mismatch` and does not delete the container
- And the error hint mentions `adevcontainer rebuild` and managed selection (`--name` or auto)
- And the hint does not mention `--recreate`

#### Scenario: up --recreate is unknown flag
- Given any `up` (or other) invocation that includes `--recreate`
- When the CLI parses global options
- Then the CLI fails with a structured **usage** error for unknown option `--recreate` (fail closed; no recreate path)

---

### Requirement: Volume-mode workspace mount and labels

*(Delta only — amend the workspace volume freshness rule; other bullets unchanged.)*

1. **Workspace volume freshness (re-clone) — `clone` only:** If the workspace named volume already exists, `clone` MUST delete it and recreate it empty before mount; MUST NOT reuse a dirty existing workspace volume tree. (Config `type=volume` mounts remain list-then-create/reuse per Named volume reuse policy — only the clone workspace `*-ws` volume is delete-and-recreate.)
2. **`rebuild` carve-out:** `rebuild` of a volume-mode managed container MUST **reuse** the existing `*-ws` volume tree with its data and MUST NOT delete, recreate, or re-populate it; MUST NOT run git re-clone or `git pull` inside it. The freshness rule applies to `clone` only.

#### Scenario: clone still recreates stale workspace volume
- Given a workspace volume `adev-{base}-{hash12}-ws` that already exists with residual files (e.g. after a prior container-only delete)
- When the user runs `adevcontainer clone` for the same URL/config identity
- Then the CLI deletes that volume, recreates it empty, and mounts the fresh volume (unchanged behavior)

#### Scenario: rebuild reuses the workspace volume instead of recreating
- Given a volume-mode managed container whose `*-ws` volume exists with data
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI does not delete or recreate the volume, mounts the same volume on the new container, and the data remains present (no re-clone)

---

### Requirement: Optional `--vscode` flag on up, start, clone, and rebuild

*(Delta only — extend the command list and the parity sentence; other content unchanged.)*

The CLI MUST accept an optional boolean flag `--vscode` on:

- `adevcontainer up`
- `adevcontainer start`
- `adevcontainer clone`
- `adevcontainer rebuild`

On `rebuild`, `--vscode` behavior MUST be identical to the `up`/`clone` create path: after rebuild lifecycle success on the new container, attempt a best-effort open of a new VS Code window on the resolved remote workspace folder; on open **success**, run extensions apply then the postAttach gate; on open **soft-fail**, skip both with status when present — never failing rebuild solely due to open.

#### Scenario: rebuild with --vscode opens after recreate
- Given a successful `adevcontainer rebuild` that yields a running managed container and a resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer rebuild … --vscode` (host `code` available and launch succeeding, or mocks equivalent)
- Then after lifecycle success the CLI attempts to open a new VS Code window on the resolved remote workspace folder
- And rebuild still reports success when open succeeds and postAttach is absent or exits 0

#### Scenario: rebuild without --vscode behavior unchanged
- Given any valid `rebuild` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of rebuild, and no postAttach exec runs (status line only when postAttach is present)

---

### Requirement: postAttachCommand policy (CLI-only)

*(Delta only — extend the run gate and consistency sentence to rebuild; all other policy text unchanged.)*

**When postAttach RUNS**

The CLI MUST execute postAttach only when **all** of the following hold on `up`, `start`, `clone`, or `rebuild`:

1. `--vscode` is set, and
2. The best-effort VS Code open outcome is **success** (host `code` launch succeeded per **VS Code best-effort open**).

**Consistency**

The gated policy MUST apply consistently on `up`, `start`, `clone`, and `rebuild`. Presence of `postAttachCommand` alone MUST NOT fail rebuild when postAttach is skipped. A non-zero postAttach on rebuild MUST fail the command and MUST keep the **new** container (no delete solely due to postAttach failure); postAttach failure MUST NOT start a volume or bind recovery session.

#### Scenario: rebuild postAttach failure fails command but keeps new container
- Given a successful rebuild with `--vscode`, successful open, and `postAttachCommand` that exits non-zero
- When the postAttach gate runs
- Then rebuild fails with a structured error naming postAttach
- And the new container still exists (not deleted solely due to postAttach failure)
- And no recovery helper or editor session is created
- And no success JSON is emitted on the error path

#### Scenario: rebuild postAttach skipped when open soft-fails
- Given a successful rebuild with `--vscode` and open soft-fail (missing `code` or launch failure)
- When the postAttach gate would apply
- Then the CLI MUST NOT execute `postAttachCommand`
- And rebuild still exits successfully (open soft-fail alone never fails rebuild)
- And no recovery helper or editor session is created

---

### Requirement: Derived image build (native arm64; no Rosetta)

*(Delta only — extend the reuse sentence at the end of the requirement with the rebuild clause; other content unchanged.)*

Reuse running / start stopped: MUST NOT re-fetch/rebuild features (already baked into the image on create). Config hash (including features) still drives recreate when features change.

**Rebuild reuse clause**

On `rebuild`, the same derived-tag identity material applies: when the rebuilt config's base image + features material is **unchanged**, the existing derived tag `adev-{base}:{hash12}` MUST be reused (no `container build`), making the unchanged config cheap; when the material **changed**, the derived image MUST be built before the old container is deleted (pre-delete ordering gate). Feature option changes alter the material and MUST produce a different derived tag, engaging the build path.

#### Scenario: rebuild with unchanged features material reuses derived tag
- Given a managed container created from a config with OCI features and an existing derived tag `adev-{base}:{hash12}` for the same material
- When the user runs `adevcontainer rebuild --name <that-name>` without changing feature material
- Then no `container build` is invoked and the new container is created from the existing derived tag

#### Scenario: rebuild with changed features material builds before delete
- Given a managed container whose edited config changes a feature ref or option
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then a new derived image is built (new tag material), the build completes **before** the old container is deleted, and the new container is created from the new derived image

---

## REMOVED Requirements

(none)
