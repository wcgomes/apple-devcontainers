# adevcontainer — Managed Lifecycle Specification

## Purpose

Unified managed-container selection for non-`up` lifecycle commands, named-volume reuse on `up`, `list`/`start`/`prune`, and related managed lifecycle operations shared by bind-mode and volume-mode workspaces.

## Requirements

### Requirement: Unified managed selection for lifecycle commands

Lifecycle commands share **one** selection model. Only `up` accepts `-w` / `--workspace`.

| Command | Selection |
|---------|-----------|
| `up` | `-w` / `--workspace` (default cwd) — bind-mode create/start/reuse |
| `exec`, `stop`, `delete`, `prune`, `inspect`, `start`, `rebuild` | `ManagedContainers.resolveSelection(name:)` only — `--name` and/or interactive picker over `devcontainer.managed=adevcontainer` |
| `clone`, `list`, `doctor` | no `-w` (unchanged) |

If the user passes `-w` / `--workspace` on any non-`up` command (including `rebuild`), the CLI MUST fail with a structured **usage** error whose message includes that `-w is only valid for up` (clearer than silently ignoring).

`rebuild` is the **sole forced recreate** path: `up` has no `--recreate` flag. On config-hash mismatch, `up` MUST fail with `config_hash_mismatch` and a hint pointing to `adevcontainer rebuild` (managed selection `--name`/auto when applicable). `rebuild` MUST recreate the selected managed container even when the resolved config hash equals the stamped `devcontainer.config_hash`, and MUST preserve the workspace volume and config named volumes (container-only delete then create).

**`exec`:** MUST resolve managed only (no ConfigResolver / host workspace path branch). User and workdir MUST come from labels `devcontainer.remote_user` and `devcontainer.workspace_folder` stamped at `up`/`clone` create (empty label → omit). `adevcontainer exec` MUST run a command or shell inside the running managed container via AppleContainerRuntime. If the container is not running, exec MUST fail with a structured error.

**`inspect`:** MUST resolve managed only. MUST show resolved identity and state: name/id, running state, labels, and payload fields from runtime + labels:

| Field | Source |
|-------|--------|
| `remoteUser` | label `devcontainer.remote_user` |
| `remoteWorkspaceFolder` | label `devcontainer.workspace_folder` |
| `configPath` | label `devcontainer.config_file` |
| `workspacePath` | label `devcontainer.local_folder` |
| `configHash` | label `devcontainer.config_hash` |
| `portsAttributes` | `{}` in v1 (not stored on labels) |

If no container exists, inspect MUST fail structurally or report not-found consistently.

**`stop` / `delete`:** MUST NOT accept a workspace path parameter. Selection is `--name` / picker only. `adevcontainer stop` MUST stop the managed container if running. Already-stopped stop is success no-op. `adevcontainer delete` MUST remove the managed container only (stopping first if required). `delete` remains **container only** (no workspace volume / config volumes / images). Missing container MUST yield a clear structured error (or documented no-op policy applied consistently — prefer error for delete of unknown identity).

#### Scenario: Exec managed by name (bind or volume)
- Given a running managed container (from `up` or `clone`) with workspace_folder/remote_user labels
- When the user runs `adevcontainer exec --name <that-name> -- echo ok`
- Then exec targets that container id with labeled user/workdir

#### Scenario: -w on exec is usage error
- Given any args including `-w <path>` on `exec`
- When the user runs the command
- Then the CLI fails usage with a message that `-w is only valid for up`

#### Scenario: Stop by name for managed container
- Given a running managed container from clone or up
- When the user runs `adevcontainer stop --name <that-name>`
- Then the container is stopped

#### Scenario: Stop interactive when multiple
- Given two running managed containers, interactive TTY, no `--name`
- When the user runs `adevcontainer stop`
- Then the CLI presents an interactive picker and stops the selected container

#### Scenario: Delete does not remove workspace volume
- Given a volume-mode container and its `*-ws` volume
- When the user runs `adevcontainer delete` for that container
- Then the container is gone and the workspace volume still exists

#### Scenario: Inspect from labels
- Given a managed container with bind or volume managed labels
- When the user runs `adevcontainer inspect --name <that-name>`
- Then payload remoteUser/remoteWorkspaceFolder/configPath/workspacePath/configHash match labels and portsAttributes is empty

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

### Requirement: Prune command

`adevcontainer prune` MUST remove:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`) via `devcontainer.config_volumes` label | Yes |
| Config `image` reference (from runtime inspect) | Yes |
| **Workspace volume for volume-mode** (`devcontainer.workspace_volume` / deterministic `*-ws` name) | **Yes** |
| Derived Features tags | No (unless equal to config `image`) |
| Bind-mount host paths | No |
| Global volume/image prune | No |

Identity resolution for prune MUST be managed-only (`--name` / picker), same as stop/delete/exec/inspect. Config named volumes MUST be taken from the `devcontainer.config_volumes` label when present. Missing `workspace_volume` label (bind-mode) means no workspace volume delete. Missing resources are skipped. Exit non-zero only if deleting an **existing** resource fails.

#### Scenario: Prune removes volume-mode workspace volume
- Given a volume-mode managed container with workspace volume `adev-{base}-{hash12}-ws` and optional config named volumes
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container is gone, config named volumes are removed, the config image reference is removed per base policy, **and** the workspace volume `*-ws` is removed

#### Scenario: Prune bind-mode uses config_volumes label
- Given a bind-mode managed container with `config_volumes=vol-a,vol-b` and no workspace_volume label
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container and labeled config volumes are removed; no `*-ws` volume delete is attempted solely for bind mode

#### Scenario: Prune still skips binds and global prune
- Given bind mounts in a bind-mode config
- When the user runs `adevcontainer prune` targeting that container
- Then host bind paths remain and no global volume/image prune is invoked

#### Scenario: Prune skips missing resources
- Given no workspace container and no matching named volumes
- When the user runs `adevcontainer prune`
- Then the command succeeds without erroring solely because resources were already absent

---

### Requirement: Named volume reuse on up

When ensuring named volumes during `up`, the runtime MUST list existing volumes first. If a named volume from config already exists, `up` MUST reuse it (status indicating already exists / reusing) and MUST NOT fail solely because the volume exists. If missing, `up` MUST create it, then mount it.

#### Scenario: Existing named volume is reused
- Given a config with a `type=volume` mount and that volume already exists on the host
- When the user runs `adevcontainer up`
- Then `up` succeeds, reuses the existing volume, and does not error solely due to volume existence

#### Scenario: Missing named volume is created
- Given a config with a `type=volume` mount and that volume does not exist
- When the user runs `adevcontainer up`
- Then the volume is created and mounted and `up` can succeed

---

### Requirement: List managed containers

The CLI MUST provide `adevcontainer list` that:

1. Obtains the container list via AppleContainerRuntime machine JSON.
2. **Filters client-side** to containers whose labels include `devcontainer.managed=adevcontainer`.
3. Default output: human-readable **table** (at least name/id and state; SHOULD include git URL and/or workspace mode when labels present).
4. `--json`: machine-readable listing of the same managed set (array or documented object envelope).

Containers without the managed label MUST NOT appear in `list`. Both `up` (bind) and `clone` (volume) create paths MUST stamp `devcontainer.managed=adevcontainer` so both appear. Historical unlabeled containers (if any) remain invisible to `list` / managed selection.

#### Scenario: List shows only managed containers
- Given one managed (clone or up) container and one unlabeled container
- When the user runs `adevcontainer list`
- Then only the managed container appears in the default table

#### Scenario: List includes bind-mode up container
- Given a container created by `up` with managed bind labels
- When the user runs `adevcontainer list`
- Then that container appears in the managed set

#### Scenario: List JSON is machine-readable
- Given at least one managed container
- When the user runs `adevcontainer list --json`
- Then stdout parses as JSON describing the managed set and does not include progress lines

---

### Requirement: Start managed container

The CLI MUST provide `adevcontainer start` that starts a **stopped** managed container.

**Selection**

- `--name <container-name-or-id>` selects explicitly.
- If no name is provided and exactly one managed container is eligible, the CLI MAY select it automatically.
- If multiple managed containers exist and none is selected, and stdin is an interactive TTY, the CLI MUST present an interactive picker.
- If multiple exist and stdin is not a TTY (non-interactive), the CLI MUST fail with a structured error requesting `--name`.
- Selection set MUST be managed containers only (`devcontainer.managed=adevcontainer`).

**Runtime behavior**

- If the selected container is stopped → start it via AppleContainerRuntime.
- If already running → success **no-op** (MUST NOT error solely because it was already running).
- MUST NOT re-clone the git URL.
- MUST NOT run the full `up` or `clone` create path (no Features rebuild, no volume re-populate, no config re-resolve required for start).

**Lifecycle hooks on start (locked split)**

| Workspace origin | `start` / start-stopped hooks |
|------------------|-------------------------------|
| **Volume-mode / clone-origin** (`devcontainer.workspace_mode=volume`) | **Runtime start only** — MUST NOT run lifecycle hooks (`postStartCommand` included) |
| **Bind-mode** via `up` | `up` start-stopped (same container, via `up` path) runs **`postStartCommand` only** per base contract. Bare `adevcontainer start` on a bind managed container is runtime start only (no config re-resolve / no hooks) in v1. |

Rationale: clone config may have lived only in a temp directory that is gone after clone; bare `start` MUST remain reliable without recovering full config from disk. Labels remain available for identity/list; hook re-execution on bare `start` is out of scope for v1 (use `up` for bind postStart).

#### Scenario: Start stopped managed container
- Given a managed container created by clone that is stopped
- When the user runs `adevcontainer start --name <that-name>`
- Then the container is running and the command succeeds without re-cloning

#### Scenario: Start already running is no-op success
- Given a managed container that is already running
- When the user runs `adevcontainer start --name <that-name>`
- Then the command succeeds and does not recreate the container

#### Scenario: Start interactive picker when multiple
- Given two stopped managed containers and an interactive TTY stdin
- When the user runs `adevcontainer start` without `--name`
- Then the CLI presents an interactive selection UI and starts the chosen container

#### Scenario: Volume-mode start runs no hooks
- Given a volume-mode managed container with labels from clone and a config that had `postStartCommand` at create time
- When the user runs `adevcontainer start --name <that-name>` on a stopped container
- Then the container starts and **no** lifecycle hooks are executed on this path

