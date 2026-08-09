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
- The only deletion MUST be the **old container itself**, following the existing container-only `delete` contract (stop first if required). No workspace volume, config volume, or image deletion is part of rebuild.
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

#### Scenario: rebuild deletes only the old container
- Given a volume-mode managed container, its `*-ws` volume, and two config named volumes
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the runtime is asked to delete exactly the old container (by name) and is never asked to delete the `*-ws` volume or any config named volume

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

The follow-up failure surface of `rebuild` MUST be split at the delete of the old container:

**Before delete (non-destructive gate)**

- In order: selection and stamp read → strict config read and resolution (see Rebuild config read) → `hostRequirements` preflight (fail on capacity shortfall, unreadable host, or parse/unknown keys per existing preflight) → when resolved features are non-empty, the build.rosetta consent gate + Features fetch/build (derived tag `adev-{base}:{hash12}` reuse when base image + features material is unchanged); `--skip-pull` honored (no pull invoked when set).
- Any failure in this span MUST fail `rebuild` with a structured error and MUST leave the old container **running/untouched** (no delete).

**After delete**

- Once the old container is deleted, failures follow `up --recreate` semantics: create-path failures MUST delete the **new** container (delete-on-fail) and MUST fail with a structured error plus a status warning that the old container was already removed.
- The command MUST NOT report success after the old container was deleted unless the new container completed its lifecycle.

#### Scenario: hostRequirements shortfall fails before delete
- Given a managed container and a config whose `hostRequirements.memory` exceeds host capacity
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `rebuild` fails with a structured hostRequirements error and the old container is still present (not deleted)

#### Scenario: features build failure fails before delete
- Given a managed container whose config has features and the rosetta consent is declined or the derived image build fails
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `rebuild` fails with a structured error and the old container is still present (not deleted)

#### Scenario: failure after delete deletes the new container and warns
- Given a managed container whose edited config's `postCreateCommand` exits non-zero
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the old container is deleted, the new container's create-path hook fails, the **new** container is deleted (delete-on-fail), the command fails structured, and stderr includes a warning that the old container was already removed

#### Scenario: --skip-pull honored on rebuild
- Given a managed container and a config whose image would normally be pulled on create
- When the user runs `adevcontainer rebuild --name <that-name> --skip-pull`
- Then no `container image pull` is invoked during rebuild and rebuild proceeds with the locally available image

---

### Requirement: Rebuild create-path parity

After the old container is deleted, `rebuild` MUST run the full create-path matrix like a fresh `up`/`clone` create on the **new** container:

- Create uses the derived image when resolved features are non-empty (host-native platform, same rosetta consent gate and derived-tag reuse as `up`/`clone`), else the config `image`.
- Lifecycle hooks onCreate → updateContent → postCreate → postStart run via runtime exec; non-zero exit of any create-path hook MUST follow delete-on-fail (of the new container) per the after-delete policy.
- Settings apply (`customizations.vscode.settings`) runs after create-path hooks and is **not** gated on `--vscode` (soft-fail semantics unchanged).
- `--vscode`: after lifecycle success, best-effort open; on open **success**, extensions apply then the postAttach gate runs (config then feature postAttach via exec, fail-keep on non-zero); on open soft-fail or absent flag, postAttach is skipped with status when present — identical to `up`/`clone`.
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

#### Scenario: create-path hook failure deletes the new container
- Given a managed container whose edited config's `onCreateCommand` exits non-zero
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the command fails structured, the **new** container is deleted (delete-on-fail), the old container was already removed (warning), and the workspace volume and config volumes remain

---

### Requirement: Rebuild output and exit parity

`rebuild` MUST emit output and exits with parity to `up`/`clone`:

- Success with `--json` MUST print machine-readable JSON on stdout with at least `outcome`, `containerId`, `remoteUser`, and `remoteWorkspaceFolder` (up-parity shape); a volume-mode rebuild MAY additionally include `gitUrl` and `workspaceVolume` (clone-parity fields). The `containerName` field MAY be included.
- Human success output MUST mirror `up`'s lines (outcome, containerId, remoteUser, remoteWorkspaceFolder, optional containerName).
- Progress/status lines MUST go to stderr via `StatusPrinter` norms; `ADEVCONTAINER_QUIET=1` silences them; `--json` keeps stdout pure.
- Failure MUST exit non-zero with the existing structured error path (no success JSON on stdout for `--json` invocations).
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

`rebuild` is a **forced recreate**: unlike `up --recreate` (hash-mismatch/forced delete-and-recreate on `up`), `rebuild` MUST recreate the selected managed container even when the resolved config hash equals the stamped `devcontainer.config_hash`, and MUST preserve the workspace volume and config named volumes (container-only delete then create).

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

`up --recreate` remains the hash-mismatch-triggered / forced delete-and-recreate path on `up`: `up` reuses a running or stopped container with matching identity and recreates when the config/features hash drifts or `--recreate` is passed. `rebuild` is an **explicit user-forced recreate** that MUST NOT require hash drift and MUST preserve volumes: it reads the current config, completes resolution/preflight/Features work first, deletes the old container **only** (container-only delete), and creates the new container reusing the existing workspace volume and config named volumes (see Rebuild requirements).

**Lifecycle hook matrix by path** (new row; existing rows unchanged)

| Path | Lifecycle |
|------|-----------|
| `rebuild <name>` (forced recreate after container-only delete of the old container) | full fresh create-path onCreate → updateContent → postCreate → postStart on the **new** container; delete-on-fail applies to the **new** container; the old container was already removed (status warning on post-delete failure) |

postAttach gating applies on `rebuild` exactly as on `up`/`clone` (after successful `--vscode` open; skip with status otherwise; failure keeps the new container).

#### Scenario: rebuild hook matrix row applies
- Given a managed container being rebuilt with a config carrying all four create-path hooks
- When `rebuild` runs the fresh create-path on the new container
- Then onCreate → updateContent → postCreate → postStart execute in order on the new container, and a first-hook failure deletes only the new container

#### Scenario: rebuild does not require hash drift
- Given a managed container whose current config hash equals the stamped hash
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then rebuild recreates the container (no hash-mismatch precondition), unlike `up` reuse which would have kept the running container

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

The gated policy MUST apply consistently on `up`, `start`, `clone`, and `rebuild`. Presence of `postAttachCommand` alone MUST NOT fail rebuild when postAttach is skipped. A non-zero postAttach on rebuild MUST fail the command and MUST keep the **new** container (no delete solely due to postAttach failure).

#### Scenario: rebuild postAttach failure fails command but keeps new container
- Given a successful rebuild with `--vscode`, successful open, and `postAttachCommand` that exits non-zero
- When the postAttach gate runs
- Then rebuild fails with a structured error naming postAttach
- And the new container still exists (not deleted solely due to postAttach failure)
- And no success JSON is emitted on the error path

#### Scenario: rebuild postAttach skipped when open soft-fails
- Given a successful rebuild with `--vscode` and open soft-fail (missing `code` or launch failure)
- When the postAttach gate would apply
- Then the CLI MUST NOT execute `postAttachCommand`
- And rebuild still exits successfully (open soft-fail alone never fails rebuild)

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