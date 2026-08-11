# Proposal: Clone into named volume workspace

## Intent

Today `adevcontainer up` always bind-mounts a **host workspace directory**. That model assumes the developer already has a local checkout and wants live host↔container file sharing. Many workflows instead need: clone a git URL once, keep the tree **inside** the container filesystem (named volume), and start/stop that managed container later without a host bind.

On Apple `container`, named volumes sit on ext4/virtio-blk rather than virtiofs bind mounts — a justified performance path for large trees and IDE attach. This change establishes the durable outcome contract for **clone-in-volume**: a `clone` command that materializes a managed container whose workspace is a **named volume** populated by a **full git clone inside the container** (SSH agent forward / host HTTPS credential one-shot for auth; in-container git works in-guest), plus companion lifecycle commands and prune behavior that cleans up the workspace volume. Managed selection is **managed-only** (`--name` / picker); only `up` accepts `-w`.

## Scope

- Change id: **`clone-in-volume`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; suite under `Tests/adevcontainerTests/`; fixtures under `Tests/Fixtures/` as needed
- Realized base contract: union of `specs/<domain>.md`. This delta **adds** clone / start / list and volume-mode workspace semantics, and **modifies** managed selection (managed-only for `exec`/`stop`/`delete`/`prune`/`inspect`/`start`), prune resource set, bind-mode managed labels, and identity/labels for volume-mode containers.

### A. Commands (product surface)

| Command | Role |
|---------|------|
| `adevcontainer clone <git-url>` | Create managed container from git URL; workspace = named volume; v1 accepts **only** the URL (no `--branch` / `--depth`) |
| `adevcontainer start [--name]` | Start a stopped **managed** container; interactive TTY picker when multiple/unspecified |
| `adevcontainer list [--json]` | List **only** managed containers (`devcontainer.managed=adevcontainer`), client-side label filter |
| `adevcontainer exec` / `stop` / `delete` / `prune` / `inspect` | Managed: resolve via `--name` or picker among managed only — **no `-w`** |

**Identity model:** Only `up` accepts `-w` / `--workspace` (bind-mode create). Passing `-w` to any other command is a usage error. Both `up` (bind) and `clone` (volume) stamp `devcontainer.managed=adevcontainer` plus managed labels so containers appear in `list` and selection.

`doctor` remains. `delete` stays container-only. `prune` gains volume-mode workspace volume removal (see below).

### B. Clone flow (ordered)

1. **Require host `git`** on `PATH` (structured fail if missing).
2. **Sparse/shallow host clone (or equivalent)** into a temp directory sufficient to fetch **only** the devcontainer config. Config search order (same as today): `.devcontainer/devcontainer.json`, then `.devcontainer.json`.
3. **Missing config** → structured fail. MUST NOT invent a default image.
4. **Resolve config** via the existing pipeline (Features, runArgs, hooks, mounts, hostRequirements, etc.) with the temp dir as workspace root **for discovery/resolve only**. Default `workspaceFolder` and `${localWorkspaceFolderBasename}` use the **git URL repo basename** (explicit `workspaceFolder` still wins).
5. **Author identity (before Features/create):** host `git -C <sparse-temp> config --get user.name` / `user.email` (includeIf-aware). Env `ADEVCONTAINER_GIT_AUTHOR_NAME` / `ADEVCONTAINER_GIT_AUTHOR_EMAIL` (both set → skip prompt). TTY: confirm or collect; non-TTY: silent + warn if incomplete. Apply after populate as **local** repo config.
6. **Ensure in-container git:** if no admitted feature id is `git` or `common-utils`, append `ghcr.io/devcontainers/features/git:1`. **`up` does not inject.**
7. **Identity**
   - Hash material: **normalized git URL** + **config relative path** (not host temp path). Normalization strips `scheme://` userinfo; host git still gets the original URL.
   - Human base: sanitize(`name`) when non-empty after trim; else sanitize(repo basename from URL).
8. **Container name:** existing scheme `adev-{base}-{hash12}` (empty base → `adev-{hash12}`; ≤ 63 chars).
9. **Workspace volume name:** `adev-{base}-{hash12}-ws` — MUST include the same container identity; if length must be clipped, keep `hash12` and the `-ws` suffix.
10. **Workspace volume:** if `adev-*-ws` already exists → **delete + create empty** (fresh tree on re-clone). If managed container name already exists → **fail closed** (no silent reuse).
11. **Create** container with workspace mount = **named volume** (NOT host bind). Labels MUST include (at minimum):
    - `devcontainer.managed=adevcontainer`
    - `devcontainer.git_url=<normalized url>` (scheme userinfo stripped)
    - `devcontainer.workspace_volume=<volume name>`
    - `devcontainer.workspace_mode=volume`
    - Adapt `devcontainer.local_folder` for volume mode (`volume://…` — no durable host path)
    - `devcontainer.config_file` + config hash labels; `devcontainer.workspace_folder` / `devcontainer.remote_user` for exec
    - `devcontainer.config_volumes` when config has `type=volume` mounts
12. **Start** the container. **SSH URL:** require `SSH_AUTH_SOCK`; inject `create --ssh` if not already in runArgs.
13. **Populate volume (in-container full clone):** after Features ensure git, run **full `git clone` inside the container** into `workspaceFolder` (before create-path hooks). Verify `workspaceFolder/.git`. No host full clone + tar-pipe on the happy path.
    - **HTTPS:** host `git credential fill` → one-shot into guest clone; optional fallbacks `ADEVCONTAINER_GIT_TOKEN` / `gh auth token`; then guest `credential.helper store`.
    - **SSH:** agent already forwarded via `--ssh`.
14. **Create-path lifecycle hooks** — same matrix as `up` fresh create: onCreate → updateContent → postCreate → postStart; on start/populate/hook failure after create: delete container **and** workspace volume.
15. **ALWAYS** delete config-fetch temp dirs on success **or** failure (`defer`). Cleanup failure → stderr warn only; MUST NOT flip overall success to failure solely due to temp cleanup.
16. **Success JSON** like `up` (`outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder`, …) **plus** `gitUrl` (normalized) and `workspaceVolume`.

### C. Auth (by URL scheme)

- **NO** GCM install/detect in the guest; **NO** browser/device-code re-auth product flow; **NO** mounting host `~/.git-credentials`.
- **NO** PAT/token CLI flags as primary UX (optional env `ADEVCONTAINER_GIT_TOKEN` escape hatch OK; optional `gh auth token` for github.com).
- Host git receives the **original** caller-supplied URL for config-only fetch; identity/labels/JSON use normalized form with `scheme://` userinfo stripped.
- **SSH:** require `SSH_AUTH_SOCK`; inject Apple `container create --ssh` so the agent is available in-guest for clone + later push.
- **HTTPS:** host `git credential fill` (GCM/osxkeychain transparent) → one-shot into in-container clone (GIT_ASKPASS/env; never log secrets) → configure guest `credential.helper store` + approve after clone.
- **In-container git binary:** after resolve + identity, clone auto-appends `ghcr.io/devcontainers/features/git:1` when neither `git` nor `common-utils` is admitted. Does not apply to `up`.

### D. `start`

- Lists/filters containers with `devcontainer.managed=adevcontainer` (client-side after JSON list).
- Interactive TTY select when the target is ambiguous or unspecified and stdin is a TTY.
- `--name` selects explicitly.
- Starts a stopped container; if already running → success no-op (structured success).
- MUST NOT re-clone; MUST NOT run the full `up` / `clone` create path.
- **Hooks policy (locked):** for volume-mode containers, `start` is **runtime start only** — **no lifecycle hooks**. Existing `up` start-stopped policy (run `postStartCommand` only) remains for **bind-mount** workspaces on the `up` path.

### E. Managed selection (`exec` / `stop` / `delete` / `prune` / `inspect`)

- **Managed-only:** `--name` or interactive picker among containers labeled `devcontainer.managed=adevcontainer`.
- **No `-w` / cwd workspace resolution** on these commands (or on `start` / `list`). Only `up` accepts `-w`.
- `exec` workdir/user from labels `devcontainer.workspace_folder` / `devcontainer.remote_user` when set at create (both bind and volume).

### F. `list`

- Managed containers only (`devcontainer.managed=adevcontainer`).
- Default: human-readable table (name/id, state, git URL and/or workspace mode as useful columns).
- `--json`: machine-readable array/object of managed container records.

### G. `delete` / `prune`

- **`delete`:** container only (unchanged) — MUST NOT remove the workspace volume or config named volumes.
- **`prune`:** existing resource set **plus**, for volume-mode workspaces (`devcontainer.workspace_mode=volume` / known workspace volume label), MUST also remove the workspace volume `*-ws` (name from label or deterministic identity). Config `type=volume` mounts and config image behavior unchanged. Still no bind host-path deletes; no global prune.

### H. Non-goals

- `--branch` / `--depth` / submodule flags on `clone`
- Explicit GCM detection/install **in-guest**; browser/device-code re-auth product flow
- PAT / token **CLI flags** as primary UX
- Mounting host `~/.git-credentials` / home
- Default image when `devcontainer.json` is missing
- Host↔volume live sync after populate
- Docker Compose / multi-service
- Alternate command names (`play`, `run`) for this flow
- Former `-w` workspace resolution (superseded by managed-only identity)

### I. Perf note (approach justification only)

Named volumes on Apple `container` use a different storage path than virtiofs binds (ext4/virtio-blk). Volume-mode clone is a deliberate performance and isolation feature, not a bind replacement for every workflow. No numeric perf SLO is required for v1.

## Approach

Lite SDD: this proposal + delta `spec.md` + dependency-ordered `tasks.md`. Implementation evolution (shipped):

1. Volume-mode identity and `CreateRequest` workspace mount (named volume + labels including `config_volumes`; optional `--ssh` inject).
2. Host git client: presence check + sparse/shallow config fetch only on happy path.
3. Host HTTPS credential provider (`git credential fill` + optional token/`gh` fallbacks).
4. `clone` orchestration: config temp → resolve → identity prompt → ensure git Feature → create/start with SSH forward when needed → **in-container full clone** + verify `.git` → hooks → failure cleanup container+ws volume → JSON.
5. `list` / `start` with managed-label discovery and TTY picker.
6. Unified managed selection: `exec`/`stop`/`delete`/`prune`/`inspect` managed-only (`--name`/picker); `-w` only on `up`; bind `up` stamps managed labels.
7. `prune` extension for `*-ws` workspace volumes and label-driven config volumes.
8. Test-first MiniTest coverage (`swift run adevcontainerTests`); mock git, credentials, and runtime so the default suite needs no network or live Apple `container` unless opt-in E2E.

All Apple `container` subprocesses remain behind **AppleContainerRuntime**. Host `git` / credential fill is a separate process boundary.

## Locked product decisions (summary)

| Topic | Decision |
|-------|----------|
| `clone` args | URL only in v1 |
| Workspace mount | Named volume, not host bind |
| Populate | **In-container** full `git clone` + verify `.git` (no host full clone/tar-pipe happy path) |
| Auth SSH | `SSH_AUTH_SOCK` required; inject `create --ssh`; via same forward |
| Auth HTTPS | Host `git credential fill` one-shot → guest clone; optional `ADEVCONTAINER_GIT_TOKEN` / `gh auth token`; then guest `credential.helper store` |
| Auth non-goals | No GCM-in-guest; no PAT CLI primary UX; no host credentials mount |
| Identity prompt | Before Features/create; host git config + optional env; TTY confirm/collect; apply local after clone |
| git Feature inject | `ghcr.io/devcontainers/features/git:1` when no `git`/`common-utils`; clone only |
| Missing config | Structured fail; no default image |
| Identity hash | Normalized git URL (userinfo stripped) + config relative path |
| workspaceFolder default | Git URL repo basename (not temp dir); explicit wins |
| Human base (volume) | `name` else git URL repo basename |
| Volume name | `adev-{base}-{hash12}-ws` (identity + `-ws`) |
| Re-clone ws volume | Delete + create empty if exists |
| Existing container name | Fail closed (no silent reuse) |
| Failure cleanup | Delete container + workspace volume |
| Managed label | `devcontainer.managed=adevcontainer` on **both** bind (`up`) and volume (`clone`) |
| Bind labels | `workspace_mode=bind` + `workspace_folder` / `remote_user` on `up` create |
| `config_volumes` label | Comma-separated config `type=volume` names; prune uses it |
| `start` hooks (volume-mode) | Runtime start only — no hooks |
| `up` start-stopped (bind) | Unchanged — `postStart` only |
| Managed selection | Managed-only (`--name`/picker); `-w` **only** on `up` |
| `list` | Managed only; table / `--json` |
| `delete` | Container only |
| `prune` | Also remove volume-mode workspace volume (+ config volumes via label) |

(End of file)
