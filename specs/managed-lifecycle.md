# adevcontainer — Managed Lifecycle Specification

## Purpose

Unified managed-container selection for non-`up` lifecycle commands, named-volume reuse on `up`, `list`/`start`/`prune`, bring-up recovery for `up` and `start`, and related managed lifecycle operations shared by bind-mode and volume-mode workspaces.

## Requirements

### Requirement: Unified managed selection for lifecycle commands

Lifecycle commands share **one** selection model. Only `up` accepts `-w` / `--workspace`.

| Command | Selection |
|---------|-----------|
| `up` | `-w` / `--workspace` (default cwd) — bind-mode create/start/reuse |
| `exec`, `stop`, `delete`, `prune`, `inspect`, `start`, `rebuild` | `ManagedContainers.resolveSelection(name:)` only — `--name` and/or interactive picker over `devcontainer.managed=adevcontainer` |
| `clone`, `list`, `doctor` | no `-w` (unchanged) |

If the user passes `-w` / `--workspace` on any non-`up` command (including `rebuild`), the CLI MUST fail with a structured **usage** error whose message includes that `-w is only valid for up` (clearer than silently ignoring).

`rebuild` is the **forced rebuild** path. On config-hash mismatch, `up` MUST fail with `config_hash_mismatch` and a hint pointing to `adevcontainer rebuild` (managed selection `--name`/auto when applicable). `rebuild` MUST create a new selected managed container even when the resolved config hash equals the stamped `devcontainer.config_hash`, and MUST preserve the workspace volume and config named volumes (container-only delete then create).

**`exec`:** MUST resolve managed only (no ConfigResolver / host workspace path branch). User and workdir MUST come from labels `devcontainer.remote_user` and `devcontainer.workspace_folder` stamped at `up`/`clone`/`rebuild` create. When `devcontainer.remote_user` is non-empty, `exec` MUST pass that user to runtime exec. Empty label → omit exec `-u` (legacy / pre-change containers only; new creates stamp non-empty — see [core.md](core.md) **Remote connection user resolution** and **Deterministic identity and labels**). `adevcontainer exec` MUST run a command or shell inside the running managed container via AppleContainerRuntime. If the container is not running, exec MUST fail with a structured error.

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

#### Scenario: Exec uses stamped resolved remote connection user
- Given a running managed container stamped `devcontainer.remote_user=alice`
- When the user runs `adevcontainer exec --name <that-name> -- id -un`
- Then exec targets that container with user `alice`

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
| Named volumes from config `mounts` (`type=volume`) via `devcontainer.config_volumes` label | Yes, **only when unreferenced** after target container delete (see volume attachment gate) |
| Config `image` reference (from runtime inspect) | Yes |
| **Workspace volume for volume-mode** (`devcontainer.workspace_volume` / deterministic `*-ws` name) | **Yes, only when unreferenced** after target container delete |
| Derived Features tags | No (unless equal to config `image`) |
| Bind-mount host paths | No |
| Global volume/image prune | No |

**Identity and candidates (unchanged intent):**

- Identity resolution for prune MUST be managed-only (`--name` / picker), same as stop/delete/exec/inspect.
- Config named volumes MUST be taken from the `devcontainer.config_volumes` label when present.
- Missing `workspace_volume` label (bind-mode) means no workspace volume candidate.
- Labels define the **candidate volume set only**. The product MUST NOT invent Compose `external` support, shared/private naming conventions, or new public `devcontainer.json` fields for this decision.
- Same resolved volume name MUST be treated as the same volume (Docker-like sharing). No separate “private copy” identity.

**Ordering and fail-safe (MUST):**

1. Resolve the managed target (and apply recovery-helper skip first when applicable — unchanged: skip helper, its referenced volumes, and its image; exit 0).
2. Delete the **target container** (force as today). Missing container after resolve MAY be skipped as today.
3. **If target container delete fails** (runtime error on an existing container the command attempted to delete), the command MUST **not** delete any candidate volumes, MUST return non-zero, and MAY still attempt image cleanup only if that does not undermine the volume fail-safe (preferred: treat container failure as hard failure and skip volume deletes entirely).
4. Only after the target container is gone (deleted successfully or already absent), evaluate each **distinct** candidate volume name from labels (`config_volumes` + optional `workspace_volume`).

**Volume attachment gate (MUST):**

For each existing candidate volume name:

- The product MUST determine whether **any other container** (managed or not, **running or stopped**) still has a **real volume mount** of that name, using existing attachment inspection semantics (`containersAttached` / `list --all` style mount inspection already used elsewhere in the product).
- The pruned target container MUST NOT count as an attachment (it is already deleted or was absent).
- **Unreferenced:** if no remaining container mounts the volume, and the volume exists, prune MUST delete it (same success/skip-missing behavior as today for the delete call itself).
- **Referenced (shared):** if one or more remaining containers mount the volume, prune MUST **preserve** the volume (MUST NOT call volume delete for it) and MUST emit a **stderr** status warning via the StatusPrinter pattern stating that the volume is preserved because it is still referenced, and listing the referencing containers preferably by **name and id** when both are available (name alone is acceptable when id is unavailable).
- Legitimate sharing MUST **not** by itself cause a non-zero exit. When the only volume-related deviations are share-preserves (and any missing-volume skips), and container/image deletes did not hard-fail, prune MUST exit **0**.

**Attachment inspection failure (MUST):**

- If listing or parsing attachments fails for a candidate volume (runtime list failure, unparseable payload, or equivalent inability to decide safely), prune MUST **preserve** that volume (MUST NOT delete it) and MUST treat the command as a **hard failure** (non-zero exit).
- The product MUST NOT delete a volume when it cannot prove the volume is unreferenced.

**Volume delete runtime failure (MUST):**

- If the runtime rejects deletion of a volume the command attempted to delete (volume exists and was judged unreferenced), that remains a **hard failure** (non-zero), same class as today’s “deleting an existing resource failed.”

**Unchanged (MUST NOT regress):**

- Missing candidate volumes are skipped without error solely for absence.
- Bind-mount host paths are never deleted; no global volume/image prune is invoked.
- Ordinary `delete` remains **container-only**; this change MUST NOT add a force-volumes flag or make `delete` remove volumes.
- Recovery helper prune skip behavior is unchanged.

**Exit summary (MUST):**

| Condition | Volume deletes | Exit |
|-----------|----------------|------|
| Recovery helper selected | None (full skip) | 0 |
| Target container delete failed | None | non-zero |
| Attachment inspection failed for a candidate | Preserve affected volume(s) | non-zero |
| Shared volume(s) preserved with warning only | Skip those; delete unreferenced others | 0 if no hard failures |
| Runtime volume/image delete of existing resource failed | Per attempt | non-zero |
| All handled or already absent; shares only warned | As above | 0 |

#### Scenario: Prune removes volume-mode workspace volume when unreferenced
- Given a volume-mode managed container with workspace volume `adev-{base}-{hash12}-ws` and optional config named volumes, and no other container mounts those volumes
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container is gone, unreferenced config named volumes are removed, the config image reference is removed per base policy, **and** the workspace volume `*-ws` is removed

#### Scenario: Prune bind-mode uses config_volumes label when unreferenced
- Given a bind-mode managed container with `config_volumes=vol-a,vol-b`, no workspace_volume label, and no other container mounts `vol-a` or `vol-b`
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container and labeled config volumes are removed; no `*-ws` volume delete is attempted solely for bind mode

#### Scenario: Prune still skips binds and global prune
- Given bind mounts in a bind-mode config
- When the user runs `adevcontainer prune` targeting that container
- Then host bind paths remain and no global volume/image prune is invoked

#### Scenario: Prune skips missing resources
- Given no managed dev container and no matching named volumes (or selection finds nothing to prune per existing managed selection rules)
- When the user runs `adevcontainer prune` in a situation where resources are already absent after valid selection handling
- Then the command succeeds without erroring solely because resources were already absent

#### Scenario: Prune preserves volume still mounted by another container
- Given managed container A selected for prune with candidate volume `shared-data`, and container B (running or stopped) still has a real volume mount of `shared-data`
- When the user runs `adevcontainer prune --name <A>`
- Then container A is deleted, volume `shared-data` still exists, no volume-delete was applied to `shared-data`, and stderr carries a StatusPrinter-style warning that the volume was preserved because it is referenced, listing B preferably by name and id
- And the command exits 0 when no other hard failures occur

#### Scenario: Prune deletes unreferenced candidate among mixed attachments
- Given prune candidates `vol-shared` and `vol-only`, where another container mounts only `vol-shared`, and `vol-only` has no remaining mounts after target delete
- When the user runs `adevcontainer prune` on the target
- Then `vol-only` is removed, `vol-shared` is preserved with a reference warning, and exit is 0 when no hard failures occur

#### Scenario: Stopped container attachment still protects volume
- Given another container that is **stopped** but still configured with a real volume mount of candidate volume `v1`
- When prune evaluates `v1` after deleting the target
- Then `v1` is preserved (stopped attachments count) with the same warning class as a running attacher

#### Scenario: Labels discover candidates; mounts decide deletion
- Given a managed container whose labels list volume `from-label` but after target delete no remaining container mounts `from-label`
- When prune runs
- Then `from-label` is a delete candidate because of the label and is deleted because mounts show it unreferenced
- Given instead the labels omit `other-vol` even if some host volume exists by that name
- When prune runs
- Then prune MUST NOT delete `other-vol` solely because it exists on the host (not in the candidate set)

#### Scenario: Container delete failure blocks all volume deletes
- Given a managed prune target whose container delete fails at the runtime
- When the user runs `adevcontainer prune --name <that-name>`
- Then the command returns non-zero and MUST NOT delete any candidate volumes (including unreferenced ones)

#### Scenario: Attachment inspection failure preserves volume and fails
- Given a candidate volume that exists and attachment list/parse fails so prune cannot prove the volume is unreferenced
- When prune evaluates that volume
- Then the volume is left in place, the command exits non-zero, and no success is claimed for that volume delete

#### Scenario: Runtime volume delete rejection remains hard failure
- Given an unreferenced existing candidate volume whose runtime `volume delete` fails
- When prune attempts deletion
- Then the command exits non-zero (hard failure)

#### Scenario: Recovery helper skip unchanged
- Given a marked recovery helper selected for prune
- When the user runs `adevcontainer prune --name <helper>`
- Then the helper, its referenced workspace/config volumes, and its image are not removed, and the command exits 0

#### Scenario: delete remains container-only
- Given any managed container
- When the user runs ordinary `adevcontainer delete --name <that-name>`
- Then only the container is removed; named volumes are not deleted by `delete`, and no force-volumes flag is required or introduced by this change

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
- Then the command succeeds without changing the container

#### Scenario: Start interactive picker when multiple
- Given two stopped managed containers and an interactive TTY stdin
- When the user runs `adevcontainer start` without `--name`
- Then the CLI presents an interactive selection UI and starts the chosen container

#### Scenario: Volume-mode start runs no hooks
- Given a volume-mode managed container with labels from clone and a config that had `postStartCommand` at create time
- When the user runs `adevcontainer start --name <that-name>` on a stopped container
- Then the container starts and **no** lifecycle hooks are executed on this path

---

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

See also: [clone.md](clone.md) **clone volume recovery (retained checkout)** and **Clone recovery persists edited config into workspace**.

---

### Requirement: start failure delegates to rebuild

When `start` fails to start a selected managed container, the CLI MUST offer recovery mode by delegating to `rebuild` for that container rather than re-running `start` (the container's ports/labels are baked at create). In a TTY (without `--json`) it MUST prompt (default Y) and, on affirmative, run `RebuildCommand` for the same container. On decline/EOF, non-TTY, or `--json`, it MUST fail with the original error and a hint to run `adevcontainer rebuild --name <name>`; it MUST NOT open an editor or re-run `start`.

#### Scenario: start failure hands off to rebuild

- Given a selected managed container and `runtime.start` fails
- When stdin is a TTY and the user affirms the recovery prompt
- Then the CLI runs `rebuild` for that container (which provides its own recovery); otherwise it fails with a hint to run `adevcontainer rebuild --name <name>`

---

### Requirement: bind up recovery (host config editor)

For an eligible `up` failure in a TTY, recovery MUST print the structured failure, prompt whether to enter recovery (default Y), and on affirmative open the editor on the host `devcontainer.json` path and validate with bind-mode strict resolve rules. Invalid content MUST reopen the editor without retrying; a valid edit MUST retry by re-resolving from the host and re-running the create path. Decline/EOF MUST fail non-zero with the original error. Non-TTY/`--json` MUST never prompt or edit and MUST fail with the original error plus an edit/retry hint for the host config path. `up` recovery MUST NOT create a helper container or a retained checkout (the config already lives on the host).

#### Scenario: bind up recovery edits the host config and retries

- Given `up` failed at create/start/hooks and the config path is the host checkout
- When the user affirms the prompt and edits the config to a valid state
- Then the CLI re-resolves from the host config and re-runs the create path; on success it reports success and no helper/checkout is left behind

---

### Requirement: Retry re-executes from scratch

After an edit, the retry MUST re-execute from the resolved config (re-resolve from the host for `up`, from the retained checkout for `clone`) rather than resuming mid-pipeline. A further recoverable failure MUST re-enter the prompt loop. Decline/EOF MUST terminate with a non-zero structured error and, for `clone`, MUST leave the retained checkout available for a later `--resume`.

