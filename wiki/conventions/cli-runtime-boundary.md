# Convention: CLI ↔ Apple container runtime boundary

All host runtime interaction goes through **AppleContainerRuntime**. No other module shells out to `container`.

## Subprocess rules

- Invoke Apple `container` as a subprocess (typical binary: `/usr/local/bin/container`).
- Prefer/require **machine-readable JSON** output for anything parsed.
- **Parse only machine JSON** — never scrape human tables/TTY text for control flow.
- Non-zero exit + stderr → map to structured CLI errors (command, args class, message).
- `doctor` validates binary presence/version/runnability before `up` paths rely on it.
- **ProcessRunner:** async-drain stdout/stderr pipes before and during `wait`, or a full pipe can deadlock the child.
- **InteractiveProcessRunner:** after Foundation `Process` launch, put the child in the TTY foreground process group (`tcsetpgrp`), **verify** `tcgetpgrp == childPG` (short retry), and `SIGCONT` the **process group** (`kill(-pg, SIGCONT)`), not only the leader PID. Inherited stdio alone is insufficient — without a verified foreground claim, full-screen editors (`nano`/`vi`) and `container exec -it` helpers stop on SIGTTIN (`STAT=T`); leader-only continue leaves siblings stopped so the shell looks correct but accepts no keyboard. Claim failure on an interactive TTY path emits a stderr warning (no silent fail-open). Used by interactive `exec` and recovery TTY editor.

## Apple container machine JSON (list/inspect; tested 1.2.x)

Parse these paths from machine JSON (not human tables). Shape documented against Apple container **1.2.x**:

| Path | Meaning |
|------|---------|
| `configuration.id` | Container id (same value as `create --name` when name is set) |
| `status.state` | Lifecycle state |
| `configuration.labels` | Labels map |

**Image inspect (connection-user / Features base USER):** Apple image JSON nests config under `variants[].config.config` (not top-level `Config`). Read **OCI USER** from `variants[].config.config.User`. Labels may include `devcontainer.metadata` (JSON array/object) with `remoteUser` / `containerUser` — official Microsoft base images often ship **OCI USER root** + metadata `remoteUser: vscode`. **Inspect failure is not root** — do not default to root or hardcode `vscode`/`node` when inspect fails; fail or leave unresolved per resolver policy. Container list/inspect still uses the table above.

- `container create --name <id>` — the name **is** the id used later for inspect/exec/stop/delete.
- **No label filter on `list`** — filter client-side after JSON list (or resolve by deterministic name/inspect).
- Long-lived devcontainers: keep-alive via `--entrypoint /bin/sleep` + `infinity` so the process does not exit immediately.

## Config → runtime

- Resolver owns JSONC + substitution subset: `${localWorkspaceFolder}`, `${localWorkspaceFolderBasename}`, `${localEnv:*}`, `${containerWorkspaceFolder}`, `${devcontainerId}` (see below). Unknown tokens → structured error.
- Resolver emits a runtime request DTO; runtime maps DTO → argv + env for `container`.
- Unsupported props/flags fail in resolver or runtime admission — **fail closed**, no drop-on-floor.

### `${devcontainerId}` (deferred expand)

Managed create name (`adev-{base}-{hash12}` / `create --name`). Features (e.g. shell-history) and config may embed it in **volume mount `source`** (`${devcontainerId}-shellhistory`) and **`containerEnv`** values.

| Phase | Behavior |
|-------|----------|
| Resolve (`VariableSubstitutor`) | Admit token. Expand only when `SubstitutionContext.devcontainerId` is set; otherwise **leave literal** `${devcontainerId}` (identity often unknown until after Features merge / mode-specific name). |
| After Features merge, before volume ensure + create | `expandDevcontainerId` with create name: **`up`** → `resolved.containerName`; **`clone`** → volume identity `containerName`; **`rebuild`** → selected managed name. |
| Safety net | `CreateRequest.from` / `fromVolumeMode` expand mounts + stamp `devcontainer.config_volumes` from post-expansion sources (idempotent if already expanded). |

**Config hash:** bind-mode hash may keep the deferred token in mount material; **volume-mode** hash / `config_volumes` label use **post-expansion** sources so identity and prune see real volume names. Expand **before** `ensureVolume` so Apple names match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`. Contract: [`specs/core.md`](../../specs/core.md) (Variable substitution subset).

## MountNormalizer (file → directory bind promotion)

Apple container accepts **directory** bind sources only ([gaps](../domain/devcontainer-apple-gaps.md)). Before pull/create on `up`, **MountNormalizer** rewrites file binds:

- **Detect** a file bind when: host source is an existing regular file; **or** source path is missing but its parent directory exists and source/target basenames match.
- **Promote** both source and target to their parent directories; preserve `readonly`.
- **Warn** on stderr (once per promotion) before pull/create so the user sees the rewrite.

Fixtures may use directory binds already (`~/.kube`); configs that still use file paths (e.g. kubeconfig) depend on this path.

## runArgs allowlist

- No blind passthrough of `runArgs` from `devcontainer.json`.
- Empty `runArgs` (`[]`) or omitted → OK (no-op).
- Valued flags accept `=VALUE` or two-token form unless noted.
- **Allowlist** (mapped onto `container create` via AppleContainerRuntime / `CreateRequest` only):
  - `--init`
  - `--cap-add=NAME` or `--cap-add` + `NAME`
  - `--cap-drop=NAME` or `--cap-drop` + `NAME`
  - `--shm-size=SIZE`
  - `--dns=IP`, `--dns-search`, `--dns-option`, `--dns-domain`, `--no-dns`
  - `--ulimit=type=soft[:hard]`
  - `--tmpfs=PATH` (if value contains `:`, path before first `:` only)
  - `--cpus`/`-c`, `--memory`/`-m` — **merge into** create `-c`/`-m` (no duplicate tokens); hostRequirements wins when set for that dimension
  - `--network=NAME` — **named networks only** (host/bridge/none/container:* warn-skipped)
  - `--rosetta`, `--ssh`, `--read-only`
- **Not via runArgs** (first-class props; hard-error if smuggled): `-e`/`-u`/`-w`/`-p`/`-v`/`--mount`/`--name`/`--label`/`-i`/`-t`/`-d`/`--rm`/`--entrypoint`.
- **Warn-skip** (not applied): `--privileged`, `--device=…` (incl. `/dev/net/tun`), `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`, Docker-only network modes. See [0003](../decisions/0003-warn-skip-apple-incompatibles.md).
- Unknown or incomplete entries (e.g. bare `--cap-add` with no name) → structured error naming the entry.

### Warn-skip emit once (Features + runArgs)

Do **not** reintroduce triple skip-warnings on resolve. Admission parsers gate user-facing warns:

- `FeatureAdmission.parse` / `RunArgsAdmission.parse` take `emitWarnings: Bool` (default `true`).
- `ConfigAdmissions.admit` calls both with `emitWarnings: false` (skip/hard-error only; no stderr).
- User-facing warn-skip emits **once** from `ConfigResolver.buildResolved` (default `true` on parse).

**Goal:** exactly one warning per skipped item per resolve ([0003](../decisions/0003-warn-skip-apple-incompatibles.md) “warns at least once” → product emits once).

## hostRequirements preflight

- Evaluate on every `up` / `clone` before create/start/reuse — never silent ignore.
- Supported keys: `memory` (e.g. `8gb` / `8192mb`), `cpus` (number).
- **Fail `up` / `clone`** on capacity shortfall or when host memory/cpus cannot be read while required.
- When host has capacity: map **requested** values onto `container create` as `-m` / `-c` (Apple size suffixes); absent/empty → no limit flags.
- **Warn** that `gpu` is unsupported when present (does not fail alone; no create flags).
- **Fail** if `hostRequirements` is present but not an object, a supported key is unparseable, or an unknown key appears inside the object.
- Config hash includes memory/cpus when set (limits affect create identity).

## Connection user (remoteUser / containerUser)

Precedence for the **effective connection user** (exec, lifecycle, VS Code attach defaults) — first non-empty wins, then fall through:

1. Local config `remoteUser`
2. Local config `containerUser`
3. Image `devcontainer.metadata` — last non-empty `remoteUser` / `containerUser` across metadata entries
4. Final image OCI `USER` (`variants[].config.config.User`)
5. `root` only when all of the above are empty **and** inspect succeeded with empty USER

**Create `-u`** (first match wins):

1. Explicit local config `containerUser` (non-empty) → `-u <containerUser>`
2. Else resolved connection user non-empty and **not** `root` → `-u <connectionUser>` (covers local `remoteUser`, metadata, OCI USER)
3. Else **omit** `-u` (connection user is `root` or empty; image default applies)

**Why:** Apple Remote Containers attach does **not** pass exec `-u` and does **not** honor nameConfig `remoteUser` for the integrated terminal — the terminal uses the container default (create) user. Applying non-root connection user at create keeps VS Code terminal aligned with `remoteUser` / metadata `vscode` without requiring local `containerUser`. When both keys are set, create is still `containerUser` and connection remains `remoteUser`.

**Stamp:** every successful create stamps non-empty `devcontainer.remote_user` to the resolved connection user (including literal `root`). Empty stamp is **legacy only** (pre-change containers); new creates never stamp empty. `exec` and `--vscode` (settings path, nameConfig `remoteUser`) read this stamp — non-empty → use it; empty legacy → omit exec `-u` / runtime default (no fabricated `vscode`/`node`).

**nameConfig:** write `…/nameConfigs/<containerName>.json` (`workspaceFolder` + `remoteUser`) **before** launching `code`. Still write it for attach defaults, but **do not rely on it for terminal user** — Apple attach ignores nameConfig `remoteUser` for the shell; create `-u` is the compensation.

Contract: union of `specs/<domain>.md` (core/features/vscode/managed-lifecycle); archive: [`specs/changes/archive/20260811-align-remote-user-resolution/`](../../specs/changes/archive/20260811-align-remote-user-resolution/).

## Deterministic names and labels

Set on create and use for reuse/inspect/`list`:

| Mechanism | Purpose |
|-----------|---------|
| Deterministic container name (`create --name` = id) | Stable identity without label-filter list APIs |
| Label `devcontainer.managed=adevcontainer` | Managed filter for `list` / picker / lifecycle commands |
| Label `devcontainer.local_folder` | Bind: host path; volume-mode: `volume://…` |
| Label `devcontainer.config_file` | Config file identity |
| App config hash label | Stamped at create; `up` reuse requires match — mismatch → `config_hash_mismatch`; use `rebuild` for a forced rebuild |
| Label `devcontainer.workspace_mode` | `bind` on `up` create; `volume` on `clone` create |
| Label `devcontainer.workspace_volume` | Workspace volume name (`adev-*-ws`; volume-mode) |
| Label `devcontainer.git_url` | Normalized remote (userinfo stripped; volume-mode) |
| Label `devcontainer.config_volumes` | Config `type=volume` source names — **prune candidate set only** (delete gated on real mounts; see [prune](#prune-resource-set)) |
| Label `devcontainer.workspace_folder` | Create-time container workdir for exec (both modes) |
| Label `devcontainer.remote_user` | Resolved connection user at create (both modes); **always non-empty on new creates** (incl. `root`); empty = legacy only; consumed by `exec` / `--vscode` |

Bind-mode `up` stamps the full managed label set including `workspace_mode=bind` (not volume-only).

**Naming rules**

- **Human base:** `sanitize(devcontainer.json name)` if present and non-empty after trim; else mode-specific fallback:
  - **Bind (`up`):** `sanitize(workspace folder basename)`
  - **Volume (`clone`):** `sanitize(git URL repo basename)` (not the host temp checkout directory name)
  - DNS-safe sanitize (`ContainerIdentity.sanitizeBase`): lowercase; non-`[a-z0-9-]` → `-`; **collapse consecutive hyphens** (`-{2,}` → `-`); trim leading/trailing hyphens; clip base ~20 chars. `name` drives identity when set (not metadata-only). Example: `C# (.NET)` → `c-net` (not `c----net`) so Features tags stay valid Apple references (`adev-c-net:{hash12}`); Apple rejects consecutive hyphens in refs.
- **Container name:** `adev-{base}-{hash12}`; empty base → `adev-{hash12}`; full name ≤63 chars.
  - Bind: `hash12` = workspace path + config path.
  - Volume: `hash12` = normalized git URL + config relpath (not temp checkout path).
- **Workspace volume (volume-mode):** `adev-{base}-{hash12}-ws`.
- **Features derived image tag:** `adev-{base}:{hash12}` where `hash12` is the content hash of base image + features + **`recipeVersion`** (epoch string in `DerivedImageTag`); empty base → `adevcontainer:{hash12}`. No `adevcontainer/features:` prefix and no `/features` path segment. Config `image` without a Features build is left as written. Tag validity depends on sanitize collapse (above). **Bump `recipeVersion` whenever install-Dockerfile semantics change** so cached local derived images are not reused forever; current epoch **`"6"`** = derived LABEL unions base-image + feature lifecycle metadata. Was `"5"` = features-only LABEL + chmod-before-install + install-as-root then restore base USER + metadata `containerEnv` as Dockerfile `ENV` before install RUN (options + user keys on RUN prefix). Was `"4"` = same install layers but `containerEnv` on RUN prefix (single-quoted `PATH` could wipe system PATH).

Do not depend on Docker-style `ps --filter label=` as the primary discovery mechanism ([gaps](../domain/devcontainer-apple-gaps.md)).

## Named volumes (ensure / reuse / ownership)

- Before create, **ensureVolume** for each config named volume: **list first**. Sources must already have `${devcontainerId}` expanded (see above) — e.g. `adev-proj-abc123def456-shellhistory`, not a literal `${…}` token.
- If the volume already exists → status “already exists — reusing” and mount it; **never fail `up`/`clone` only because a config volume exists**.
- If missing → create, then mount.
- **Clone workspace volume:** if `adev-*-ws` already exists → **delete + create** (fresh tree), then mount as the workspace root (not a host bind).

### Ownership (`WorkspaceOwnership`)

Apple named volumes mount **root:root** ([gaps](../domain/devcontainer-apple-gaps.md#named-volume-ownership-rootroot)). Helper: `WorkspaceOwnership` — shared container-side chown as root after start, **before create-path hooks**.

| Path | Behavior |
|------|----------|
| Config `type=volume` mounts | `ensureNamedVolumeMountsWritableByRemoteUser` on `up` / `clone` / `rebuild` (bind and volume mode). Targets only; skips binds, readonly volumes, empty targets, root/unset user |
| Workspace volume (`adev-*-ws`) | Separate `ensureWorkspaceWritableByRemoteUser` on `clone` (always after start); on `rebuild` volume-mode only when effective connection user **differs** from stamped `remote_user` (data already owned otherwise) |
| Timing | After successful start; before populate (`clone`) and before create-path hooks |
| Failure | **`up`/`clone`:** hard-fail + delete container (clone also deletes `*-ws`). **`rebuild`:** soft-fail — warn stderr, continue |

**Chown script (per target):** `mkdir -p` target → `chown -R user[:user]` target → walk `dirname` parents with **non-recursive** `chown` until a system-top denylist stop (`/`, `/home`, `/Users`, `/var`, `/usr`, `/opt`, `/tmp`, `/root`, `/etc`, `/mnt`, `/media`, `/dev`, `/proc`, `/sys`, `/run`, `/boot`, `/lib`, `/lib64`, `/bin`, `/sbin`). Makes nested home mounts writable for siblings (e.g. `/home/vscode/.local` for `devcontainer-features`) without chowning `/home`. **Never** chown bind-mount host paths.

**Symptom without fix:** remoteUser EACCES writing home-dir named volumes; lifecycle `mkdir` fails under root-owned intermediate parents.

## `clone` flow (volume-mode)

1. Require host `git` on `PATH` (config-only fetch + HTTPS credential fill). No bundled git; no PAT CLI flags (optional env `ADEVCONTAINER_GIT_TOKEN` escape hatch OK).
2. Host git: sparse/shallow **config-only** fetch into a temp dir (auth = host helpers/SSH agent; git argv puts `--` before the URL). Identity/labels use **normalized** URL (`scheme://` userinfo stripped); host git still gets the **original** URL.
3. Resolve `devcontainer.json` from that temp tree. **workspaceFolder** default and `${localWorkspaceFolderBasename}` use the **git URL repo basename**, not the host temp checkout directory name.
4. **Author identity (before Features/create):** host `git -C <sparse-temp> config --get user.name` / `user.email` (includeIf-aware). Env overrides: `ADEVCONTAINER_GIT_AUTHOR_NAME` / `ADEVCONTAINER_GIT_AUTHOR_EMAIL`. **Both env set** → use env, skip prompt (even on TTY). **TTY** and env incomplete: if both resolved → confirm `Use this identity? [Y/n]` (decline → collect name+email); if either missing → prompt for both (empty → fail structured, no Features/create). **Non-TTY:** no prompt; resolved/env silently when complete; incomplete → continue (warn at apply, no hang). Chosen values applied after populate (step 8).
5. **Ensure in-container git (Features path, not apt):** after resolve + identity, before the Features gate, if no admitted feature id is `git` or `common-utils` (any registry/tag or local path), append `ghcr.io/devcontainers/features/git:1` (empty options). Status: `==> Ensuring git feature for volume-mode dev container`. Empty features → inject then enter FeaturesRunner. Already covered → no double-add. Config hash / effective features include the inject when added. **`up` does not inject.**
6. Ensure workspace volume (`adev-{base}-{hash12}-ws`); delete+create if present. Existing managed container name → fail closed (no silent reuse).
7. Create volume-mode container (workspace = named volume; labels as above) and start. Features runner runs when features non-empty after step 5.
    - **SSH URL:** require host `SSH_AUTH_SOCK` non-empty; inject `AllowlistedRunArg.ssh` (`container create --ssh`) if not already in runArgs. Missing agent → fail structured (hint ssh-agent / HTTPS). Later push uses the same forward.
    - **HTTPS:** no create-time auth flag; credentials applied at populate (step 8).
8. **Ownership:** chown workspace folder + config `type=volume` targets to connection user (`WorkspaceOwnership`; hard-fail + delete container/`*-ws` on failure) — see [Named volumes / ownership](#named-volumes-ensure--reuse--ownership).
9. **Populate (in-container full clone)** — happy path is **not** host full clone + tar-pipe (`copyTreeIntoContainer` may remain as unused utility). After Features ensure git:
    - Exec in-container `git clone` of the URL into `workspaceFolder` (as `remoteUser` when set); verify `workspaceFolder/.git`.
    - **HTTPS auth:** host `git credential fill` (protocol/host/path; GCM/osxkeychain transparent — **no product GCM-in-guest**, no mount of host `~/.git-credentials`). Optional fallbacks: `ADEVCONTAINER_GIT_TOKEN`; `gh auth token` for github.com when `gh` available. When creds exist → one-shot into guest clone via GIT_ASKPASS/env (never log secrets; redact errors) → guest `credential.helper store` + `git credential approve` once. When fill empty → anonymous in-container clone (public); auth failure → structured hint to configure host credentials or use SSH.
    - **SSH auth:** agent already forwarded via `--ssh` from create.
    - **Author apply:** when **both** name+email from step 4 → guest `git config --local` both; if either missing → warn once, no partial write; no synthetic defaults.
  10. Create-path lifecycle hooks (same order as fresh `up`). On start/populate/hook/ownership failure after create: delete container **and** workspace `*-ws` volume.
  11. **Temps:** success or ineligible failure → clean config-fetch temps. Eligible bring-up recovery → retain the checkout (do not delete). Successful recovery/`--resume` overlays the edited `devcontainer.json` into the guest workspace **after populate** (replaces the git-populated original), then removes only a validated managed checkout. No overlay without an editable config. No host full-clone staging temp on the happy path.

`up` remains bind-mode host workspace only (no auto git Feature). Detail: [architecture.md](../architecture.md); contract [`specs/clone.md`](../../specs/clone.md). Eligible clone recovery: [Bring-up recovery](#bring-up-recovery-bringuprecovery).

## Managed selection (`list` / lifecycle commands)

**Only `up` uses `-w`/cwd** (bind workspace path). All other lifecycle commands resolve a managed container via `--name` or interactive picker — never `-w`.

- `list [--json]`: client-side filter to `devcontainer.managed=adevcontainer` only.
- `start` / `exec` / `stop` / `delete` / `prune` / `rebuild` / `inspect`: `--name` or picker among managed; no host workspace path required.
- `start`: runtime start of a managed container. **Real start** (bind+volume): host `initializeCommand` when a host workspace exists (volume start without host path skips+warns) → `postStartCommand` + feature remelt → CLI-attach postAttach. **Already-running:** no initialize/postStart; postAttach only after successful `--vscode` open. **Never applies** settings/extensions. Start failure: TTY recovery delegates to `rebuild --name` (does **not** re-run start or open an editor); non-TTY/`--json`/decline → original error + hint `adevcontainer rebuild --name <name>`.
- `exec`: user/workdir from labels `devcontainer.remote_user` / `devcontainer.workspace_folder` when set (both modes stamp workdir; new creates always stamp non-empty `remote_user` incl. `root`; empty label = legacy omit `-u` — see [Connection user](#connection-user-remoteuser--containeruser)).

### InteractivePicker (multi-container)

`ManagedContainers.resolveSelection` → **`InteractivePicker`** when `--name` omitted and more than one managed container. Code: `ManagedContainers.swift`, `TerminalRawInput.swift`. Rows/header via shared **`ManagedContainerTable`** (NAME STATE MODE GIT_URL; lead `>` / `N)` — [terminal-output](terminal-output.md#managed-container-table-list--interactivepicker)).

| Mode | When | Behavior |
|------|------|----------|
| Live navigable | `.default` only (`prefersLiveRawInput == true`), stdin TTY, raw enter succeeds | ↑/↓ or j/k move, Enter confirm, Esc/Ctrl-C cancel, digits **1–9** jump; UI on **stderr**; selected lead `>` `styleCommand` |
| Numbered `readLine` | Non-TTY, raw setup fail, or no live raw path | Numbered lead `N)` table + `Enter number:` on stderr |
| Fail closed | `!picker.isInteractive` and multi | `selection_required` — still need `--name` (non-interactive never auto-picks among many) |

**`prefersLiveRawInput`:** only `InteractivePicker.default` sets `true`. Custom inits default `false` so injected `readLine` / `readInput` skip live termios (tests). Explicit `readInput` always takes the navigable path without opening raw stdin.

**`TerminalRawInput`:** termios raw clears `ICANON | ECHO | ISIG`; Ctrl-C arrives as `0x03` → cancel so `defer` always restores prior termios (never leave host shell without ICANON/ECHO). Non-TTY or `tcsetattr` fail → `nil` → numbered fallback.

Presentation / QUIET: [terminal-output.md](terminal-output.md) (picker stays raw stderr, not QUIET-gated).

## `up` reuse vs `rebuild` (forced rebuild)

| Path | Behavior |
|------|----------|
| `up` create | Fresh bind-mode create when no managed container for identity |
| `up` reuse / start-stopped | Only when existing container's stamped config hash **equals** current resolve. Running → reuse (no Features re-run; host `initializeCommand` still runs); stopped → start + `postStartCommand` + feature remelt |
| `up` config hash mismatch | Fail closed: `config_hash_mismatch`; **does not** delete or replace. Hint: `adevcontainer rebuild` (managed selection: `--name` or auto) |
| `rebuild` | **Forced rebuild** (landed; archive [`20260810-rebuild`](../../specs/changes/archive/20260810-rebuild/)): read current stamped config **before** any delete; hostRequirements + Features; then container-only delete old → create same name (bind) or reuse same `adev-*-ws` (volume; ensureVolume, never delete/replace workspace volume; no re-clone). Volume/clone-origin with no host workspace still runs host `initializeCommand` from a temp guest-config root (not skip; see [Lifecycle](#lifecycle-execution-hook-matrix)). Pre-delete failure leaves old container untouched. Optional `--skip-pull` / `--vscode` / `--json`. Volume-mode rebuild: OCI features only (local-path / host DefaultFeatureFetcher unsupported — fail clean pre-delete). After start: config volume ownership always (soft-fail warn); workspace chown only if connection user ≠ stamped `remote_user` (soft-fail) — see [ownership](#named-volumes-ensure--reuse--ownership). Hard post-delete recovery mode-split (TTY `Open the recovery editor now? [Y/n]` default Y; decline/EOF retain; named retry skips prompt; README + CLI help document UX): [gaps — Failed rebuild recovery](../domain/devcontainer-apple-gaps.md#failed-rebuild-recovery-mode-split). Bring-up (`up`/`clone`/`start`) is a separate primitive — [below](#bring-up-recovery-bringuprecovery) |

## Bring-up recovery (`BringUpRecovery`)

Shared primitive for `up`/`clone` (edit-and-retry) and `start` (rebuild handoff). Rebuild hard post-delete recovery is unchanged. Contract: [`specs/clone.md`](../../specs/clone.md) + [`specs/managed-lifecycle.md`](../../specs/managed-lifecycle.md); archive [`20260814-bring-up-recovery`](../../specs/changes/archive/20260814-bring-up-recovery/). Detail: [architecture](../architecture.md#bring-up-recovery), [gaps](../domain/devcontainer-apple-gaps.md#bring-up-recovery-up--clone--start).

- **Eligible:** existing editable `devcontainer.json`. Triggers: parse/resolve, create, start, ownership, clone populate, create-path hooks.
- **Not eligible:** config missing; clone fetch fails before config exists; postAttach/settings/open.
- **TTY:** `Open the recovery editor now? [Y/n]` default **Y**. Non-TTY/`--json`: never prompt; hint only. Decline/EOF → original error.
- **`up`:** host config editor; retry from scratch (re-resolve + create path); delete leftover containers including after a later retry or `name` change. No helper/checkout. Bind stays host-edit — no guest overlay.
- **`clone`:** retain product-managed checkout (`~/Library/Application Support/adevcontainer/clone-recovery`, marker `.adevcontainer-retained-checkout`); retry without re-fetch; non-TTY exact `clone --resume <config-dir>`. Resume/remove: managed root + marker only; never delete an external path. Successful TTY retry/`--resume` overlays edited `devcontainer.json` into the guest workspace after populate (replaces git-populated original; in-container write `adevcontainer-clone-persist`). Overlay is clone-recovery only; none when there is no editable config. Rebuild helper write-back unchanged.
- **`start`:** TTY → `rebuild --name`; never re-run start, open an editor, or write config.

## `prune` resource set

`prune` removes container + config `image` + **unreferenced** candidate volumes. Labels define candidates only — **not** unconditional volume delete.

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes (first; fail → no volume deletes) |
| Named volumes from config `mounts` (`type=volume`, via `config_volumes` label) | Candidate only — delete **iff unreferenced** after target gone |
| Workspace volume `adev-*-ws` (volume-mode, `workspace_volume` label) | Candidate only — same attachment gate |
| Config `image` reference | Yes |
| Derived Features tags (`adev-{base}:{hash12}` / `adevcontainer:{hash12}`) | **No** — not removed unless the tag equals config `image` |
| Bind-mount host paths | **No** |
| Global `volume prune` / `image prune` | **No** |

**Attachment gate (after target container deleted or already absent):** for each distinct candidate name, inspect real volume mounts on **all** remaining containers (managed or not, **running or stopped**) via `containersAttached` / `list --all` style inspection. Target does not count. **Unreferenced** + exists → delete. **Referenced (shared)** → preserve + stderr StatusPrinter warning listing referencers (prefer name+id); share-only is **not** a hard failure (exit 0 when no other hard fails). **Attach inspect fail** → preserve that volume + non-zero. Runtime rejection on volume delete remains hard-fail. Missing resources skipped.

**Model:** labels live on containers, not volumes; same volume name = shared resource (Docker-like). No Compose `external` / shared-private naming schema. `delete` stays container-only. Recovery-helper prune skip unchanged. Contract: [`specs/managed-lifecycle.md`](../../specs/managed-lifecycle.md); archive [`20260812-prune-shared-volume-safety`](../../specs/changes/archive/20260812-prune-shared-volume-safety/).

## Features runner

On `up`/`clone`/`rebuild` when `features` is non-empty after resolve (and after clone git-ensure; volume-mode rebuild admits OCI only). Code: `Sources/ADevContainerLib/Features/`.

| Step | Behavior |
|------|----------|
| Admit | Feature ref → options map; **OCI** (`ghcr.io/…/node:1`) and **local path** (`./…`, `../…`, absolute `/…`, `file://…` relative to workspace root); declaration key-sorted for stable ties |
| Warn-skip | Any ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (OCI or local) — drop from admitted list with warning; metadata `privileged` / `securityOpt` warn-stripped (not applied; feature may still install) ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)). Emit once per resolve — see [Warn-skip emit once](#warn-skip-emit-once-features--runargs) |
| build.rosetta | Before fetch/build: ensure Apple BuildKit `build.rosetta=false`. Already false → silent. True/missing → one-time TTY consent (or fail); CI auto-accept via `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`. Never install Rosetta; never restore `true` after consent. Config pickup uses `restartBuilderForConfig` (stop+delete only) — **not** the restore-after-build path below |
| Fetch / load | **Local path:** validate package (`devcontainer-feature.json` + `install.sh`) and copy into feature cache. **OCI:** embedded HTTPS client (`OCIFeatureClient`) — **not** `container image pull`, ORAS, or Node |
| Order | `dependsOn` / `installsAfter` topo-sort (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`); cycle → structured error |
| Build | Generate Dockerfile (`FeatureDockerfileGenerator`): per feature `COPY` package; emit metadata **`containerEnv` as Dockerfile `ENV`** (so `$PATH`/`$VAR` expand — not single-quoted RUN env); then **`RUN chmod -R 0755 /tmp/adev-feature-N && … ./install.sh` as root** with **options + `_REMOTE_USER` / `_CONTAINER_USER` on the RUN prefix only** (base-image USER when config remote/container user empty — not hardcoded `vscode`/`node`; RUN prefix overwrites ENV on key collision). After all features, **restore base image OCI `USER`**. Recursive +x avoids exit **126** on bare-path lifecycle hooks copied 0644 from OCI. `container build --platform` host-native (`linux/arm64` on Apple Silicon) via `AppleContainerRuntime.build`; **no** `--rosetta` unless user opted in via `runArgs`; deterministic derived tag `adev-{base}:{hash12}` (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix); hash includes **`recipeVersion`** epoch — current **`"6"`** (derived LABEL unions base-image + feature lifecycle; chmod + root-install/restore USER + `containerEnv` as `ENV` before install RUN); reuse when tag exists. See BuildKit builder lifecycle; install-time env: [gaps — Features install containerEnv](../domain/devcontainer-apple-gaps.md#features-install-containerenv) |
| Merge | Feature contributions into effective config before create (`init`, `capAdd`, mounts, lifecycle hooks; runtime `containerEnv` **config wins** on create/exec — separate from install-layer merge above). PATH refs in env expanded on create **and** exec — see PATH expansion |
| Create | Workspace container from **derived image** with same `--platform`. Create `-u`: explicit `containerUser`, else non-root connection user, else omit when root — see [Connection user](#connection-user-remoteuser--containeruser) |
| Skip | Reuse-running path: no feature fetch/build |

### BuildKit builder lifecycle (Features image build)

adevcontainer does **not** pin the BuildKit image tag; Apple `container` owns builder image/version. We never `builder start` — `container build` may auto-start BuildKit.

On `AppleContainerRuntime.build` (Features derived image):

1. **Probe** `container builder status --format json` first.
2. **If builder was not running** (empty list or non-running state): after build finishes — success **or** failure (`defer`) — best-effort `builder stop` so we do not leave BuildKit up when the user had it stopped.
3. **If builder was already running**, or status is **undetermined** (probe/parse fail): do **not** stop after build.

`restartBuilderForConfig` (stop+delete for rosetta config pickup) is separate from this restore-after-build behavior.

**Fixtures:** `features-node`, `features-triple`, `features-local`, `features-docker-ood`, `features-sample/*`.

**Tests:** suite of record is `swift run adevcontainerTests`. Local E2E when Apple `container` available (runtime-unavailable skip unchanged); fixture E2E inspects the remapped test image (`ADEVCONTAINER_TEST_IMAGE`; `ensureTestImageOrSkip`), pulls only if missing, MiniTest.skips on pull fail (default suite green without network; cached images do not pull); `UpCommand` still `skipPull: true` after harness ensure. OCI E2E opt-in `ADEVCONTAINER_FEATURES_E2E=1`. Recovery E2E gate: `ADEVCONTAINER_RECOVERY_E2E=1` (non-TTY) / `ADEVCONTAINER_RECOVERY_E2E_TTY=1` (TTY). Rebuild non-TTY live exists when gated (bootstraps clone-origin stamps when live `CloneCommand` populate is unreachable). Automated TTY recovery E2E absent (TTY env surfaces skip guidance). Bring-up gated case `recoveryE2E_bringUpCommands_gated` still skip-cascades and then always skips — it does not execute live bring-up commands. Feature material for rebuild/recovery git inject must use a durable host path such as `~/Library/Caches` — Apple `container build` drops/breaks `/var/folders` temp contexts.

Progress lines: `==> Resolving features`, `==> Fetching features`, `==> Building features` (or Reusing); `==> Configuring native arm64 builds (build.rosetta=false)` only when changing config.

## PATH expansion (`containerEnv`)

Apple `container` does **not** expand `${PATH}` / `$PATH` in env values. Product expands them on **both** create and exec via the same helper (`expandEnvPathRefs`):

| Path | Where |
|------|--------|
| Create | `CreateRequest` / create argv env |
| Exec | `AppleContainerRuntime.exec` (lifecycle hooks + `adevcontainer exec`) |

**Why exec matters:** Features often set e.g. `PATH=/usr/local/share/nvm/current/bin:${PATH}`. If only create expands, `container exec` passes a literal `${PATH}` → no `/bin`/`/usr/bin`. Lifecycle uses `sh -lc` (login shell); profile tools need `id`/`bash` on PATH → failures like `id: not found`, `[: Illegal number:`, `bash: not found` (exit 127) on `postCreateCommand`.

**Test:** `execEnvExpandsPathRefs` (unit).

## Progress / tee

Presentation stack (StatusPrinter + TerminalStyle, tool `| ` framing, QUIET/color matrix, connectionHint info weight, clone populate `streamOutput`): **[terminal-output.md](terminal-output.md)**. Runtime-boundary facts that stay here:

- Long ops emit product phases on stderr (pull/create/start/stop/delete/volume create; Features Resolving/Fetching/Building/Reusing; build.rosetta when changing; lifecycle `==> Running <property>`; related steps). StatusPrinter only — not hook/tool body I/O.
- After successful `up`/`clone`/`start`/`rebuild` without originating `--vscode`, connection hints (info, not `==> `) on stderr; `--vscode` suppresses both; never on stdout/`--json`.
- Tee Apple `container` / internal tool body to host stderr with display framing; capture raw. Lifecycle hooks and Features build already stream; **clone populate** uses `streamOutput: true`. Non-lifecycle user `exec` stays capture-then-print / unframed passthrough; interactive TTY inherit unchanged.
- `--json` keeps **stdout** pure JSON — tool/hook body teed to host **stderr** only. QUIET silences phase/info (incl. connection hints); warnings, errors, framed tool body, prompts still emit.
- Under heavy dual-stream load, dual drain threads may interleave stdout/stderr bytes on host stderr.
- **Test tip:** assert stream flags on the lifecycle `exec` call itself — delete-on-fail invoke also streams and can overwrite mock “last flag” fields.

## Lifecycle execution (hook matrix)

In-container hooks run via runtime **exec** (effective user + workspace folder when set). Host `initializeCommand` is host-process, not exec. Usable host workspace (bind / clone checkout) is cwd when present. Volume/clone-origin `rebuild` with no host workspace still runs: cwd a temp root that contains the live guest `.devcontainer/` (and root `.devcontainer.json` if that is the config); temp removed after the hook; `./scripts/…` not required. Volume `start` with no host path still skip+warn. Omitted properties and empty `{}` maps are no-ops. Nested objects rejected. `waitFor` default `updateContentCommand`. `userEnvProbe` admitted (default `loginInteractiveShell`; `none` skips). `shutdownAction` admitted (`stopCompose` fail-closed; explicit `stop` always stops). Exec env PATH expansion applies (see PATH expansion). **Live I/O:** lifecycle exec enables streamOutput — child stdout+stderr teed live to host stderr framed as internal tool lines (`    | ` display; raw capture); status `==> Running …` is separate StatusPrinter output. Presentation: [terminal-output.md](terminal-output.md). Contract: [`specs/lifecycle-hooks.md`](../../specs/lifecycle-hooks.md) + active [`align-official-lifecycle`](../../specs/changes/align-official-lifecycle/).

### Command forms (`LifecycleCommand`)

Each hook property admits **string** | **argv `string[]`** | **object map** `name → string|argv` (Dev Containers named/parallel JSON shape).

| Form | Parse / run |
|------|-------------|
| string | shell via `sh -lc` (same as historical `postCreateCommand`) |
| argv array | exec argv directly |
| object map | `LifecycleCommand.parallel([NamedLifecycleCommand…])`; empty `{}` → nil; values must be string or argv (not nested objects) |

**Object-map execution:** named entries run **in parallel** — stage succeeds only if every entry exits 0. Status labels use `property (name)` (e.g. `onCreateCommand (shell-history)`).

**Why it matters:** third-party Features often emit map-form hooks (e.g. `ghcr.io/stuartleeks/dev-container-features/shell-history:0` → `onCreateCommand: { "shell-history": "…" }`). Admitting only string/argv rejected those Features at resolve.

| Path | Hooks / apply |
|------|----------------|
| Fresh create (`up` bind, `clone` volume, or `rebuild` replacement) | host `initializeCommand` (host path when present; volume/clone-origin `rebuild` with no host workspace: temp guest-config root as above) before create; **Named-volume ownership** (`WorkspaceOwnership`) after start, before hooks — see [ownership](#named-volumes-ensure--reuse--ownership); then `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand` → **settings+extensions apply** (soft-fail; not gated on `--vscode`); `waitFor` default `updateContentCommand` |
| Reuse running (`up`, config hash match) | host `initializeCommand` when host workspace exists; no create-path hooks; settings+extensions apply on marker drift (**not** `--vscode`-gated); CLI-attach postAttach (feature hooks mergeable from image metadata) |
| Config hash mismatch (`up`) | fail `config_hash_mismatch`; no hooks/delete; remediate with `rebuild` |
| Bind start-stopped (`up`, hash match) | host `initializeCommand` → `postStartCommand` + feature remelt; then settings+extensions apply if pending (**not** `--vscode`-gated); CLI-attach postAttach |
| Bare `start` | **Real start:** host `initializeCommand` (skip+warn if no host path) → `postStartCommand` + feature remelt → CLI-attach postAttach. **Already-running:** no initialize/postStart; postAttach only after successful `--vscode` open. **Never applies** settings/extensions |
| `customizations.vscode` | **CLI apply** config-file v1 (`VSCodeCustomizationsApply`): settings+extensions by default on `up`/`clone`/`rebuild` (create-path + `up` reuse / `up` start-stopped; **not** gated on `--vscode` or open; **not** on `start`; marketplace VSIX for **guest** `targetPlatform` linux/alpine × arm64/x64 via `uname -m`+os-release; platform-specific asset URL `?targetPlatform=` (universal omits — 404 with query); unknown arch soft-fail no host VSIX → tar-pipe → unzip → **`extensions.json` registry upsert** + cache invalidate; `metadata.pinned` false bare / true `@version`; BFS **`extensionDependencies` ∪ `extensionPack`** shared cycle guard; soft-fail per ID; seed ≠ EH/activation/`runtimeDependencies`). Order with flag on apply-commands: apply → open → postAttach (postAttach still runs if open soft-fails). Soft-fail apply ≠ postAttach fail-keep. Marker `$HOME/.adevcontainer/vscode-customizations.applied` (config payload hash only; finalize does not require `--vscode`/open; `start` never writes). Not image build; not feature/metadata merge; Apple attach does not auto-install. Detail: [architecture.md — VS Code flow](../architecture.md#vs-code-flow); [gaps — CLI extension seed](../domain/devcontainer-apple-gaps.md#cli-extension-seed-vs-full-marketplace-install) |
| `postAttachCommand` | **CLI attach** on `up`/`clone`/`rebuild`/real `start` after waitFor (not `--vscode`-gated; open success/soft-fail MUST NOT skip). Already-running `start`: **RUNS** only after successful `--vscode` open; **SKIP** + status if no flag or open soft-fails (no status line if absent). Order on apply-commands: apply → open → postAttach. Contract: [`specs/vscode.md`](../../specs/vscode.md) + active [`align-official-lifecycle`](../../specs/changes/align-official-lifecycle/) + active [`vscode-customizations-up-clone-rebuild`](../../specs/changes/vscode-customizations-up-clone-rebuild/); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../../specs/changes/archive/20260808-vscode-customizations-apply/) |

- Capture exit codes; failed hook fails the command — do not pretend success.
- **Create-path failure** (any of onCreate / updateContent / postCreate / postStart on fresh create): delete the container **before** returning failure, so reuse cannot treat a half-bootstrapped container as healthy. Customizations apply is **not** part of create-path delete-on-fail. After delete-on-fail, `up`/`clone` may enter [bring-up recovery](#bring-up-recovery-bringuprecovery) when an editable config exists.
- **Restart-class `postStartCommand` failure** (`up` start-stopped or real `start`): fail the command but **do not** delete.
- **postAttach failure** (when it runs): fail the command; **do not** delete/stop the container (fail-keep; contrast create-path delete-on-fail). Open soft-fail alone does not fail the command. On `up`/`clone`/`rebuild`/real start, postAttach still runs; already-running `start` must not run postAttach after open soft-fail. On `up`/`clone`/`rebuild`, apply still runs (not `--vscode`-gated). `start` never applies.
- **customizations apply soft-fail:** warn stderr; never fail lifecycle exit; never delete/stop solely due to settings/extensions apply. Contrasts postAttach fail-keep.
- **postAttach / apply config load:**
  - `up`/`clone`/`rebuild`: use resolved (or stamped) config for apply; on reuse/restart merge feature postAttach from image `devcontainer.metadata` (no Features re-run); vscode extensions/settings from resolved config.
  - bare `start`: load from labels **for postAttach only** — bind: host `local_folder` + `config_file`; volume: cat stamped config path in-container; merge feature postAttach from image/container metadata. Load errors → treat absent (preserve start success). Load MUST NOT drive settings/extensions apply.

## `exec`: selection, interactive vs non-interactive

- **Selection:** `--name` or interactive picker among managed only — **no `-w`/cwd** (that flag is `up`-only). Workdir/user from labels `devcontainer.workspace_folder` / `devcontainer.remote_user` when stamped at create (bind or volume; new creates always stamp non-empty `remote_user`; empty = legacy).
- **Interactive** (no command, or `-i` / `-t` / `-it`): **InteractiveProcessRunner** (inherit stdio **plus** child TTY foreground via `tcsetpgrp` + `SIGCONT` after launch — see Subprocess rules) + `container exec -i -t`; default command is `bash`.
- **Non-interactive** (command exec without those flags): capture stdout/stderr pipes; do **not** pass `-i`/`-t`.
- Feature/config `containerEnv` on exec expands `${PATH}` / `$PATH` the same as create.

## Ports

- `forwardPorts` → publish/port-mapping flags supported by Apple container.
- Do not implement or promise Docker Desktop / VS Code auto-forward side channels.

## Non-goals at this boundary

- Embedding a container engine / talking gRPC-private APIs unless product later re-decides.
- Spawning Docker or Node to “help” Apple container.
- Emulating privileged or device nodes.
- Installing Rosetta for Features builds (native arm64 BuildKit only).

## README terminology

User-facing docs (README) use **"dev container"** for the thing `up`/`clone`/`start`/… create and run, and **"workspace"** only for the folder/volume that holds the code (e.g. "workspace root", "remote workspace folder"). Internal names are unaffected — labels `devcontainer.workspace_*`, the `adev-*-ws` volume, and the config key `workspaceFolder` keep their names. Keep README wording consistent with this split.
