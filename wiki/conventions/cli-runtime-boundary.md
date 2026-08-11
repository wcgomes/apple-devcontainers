# Convention: CLI ↔ Apple container runtime boundary

All host runtime interaction goes through **AppleContainerRuntime**. No other module shells out to `container`.

## Subprocess rules

- Invoke Apple `container` as a subprocess (typical binary: `/usr/local/bin/container`).
- Prefer/require **machine-readable JSON** output for anything parsed.
- **Parse only machine JSON** — never scrape human tables/TTY text for control flow.
- Non-zero exit + stderr → map to structured CLI errors (command, args class, message).
- `doctor` validates binary presence/version/runnability before `up` paths rely on it.
- **ProcessRunner:** async-drain stdout/stderr pipes before and during `wait`, or a full pipe can deadlock the child.
- **InteractiveProcessRunner:** after Foundation `Process` launch, put the child in the TTY foreground process group (`tcsetpgrp`) and `SIGCONT` if needed. Inherited stdio alone is insufficient — without foreground, full-screen editors (`nano`/`vi`) stop (`STAT=T`) and the parent hangs at `waitUntilExit`. Used by interactive `exec` and recovery TTY editor.

## Apple container machine JSON (list/inspect; tested 1.2.x)

Parse these paths from machine JSON (not human tables). Shape documented against Apple container **1.2.x**:

| Path | Meaning |
|------|---------|
| `configuration.id` | Container id (same value as `create --name` when name is set) |
| `status.state` | Lifecycle state |
| `configuration.labels` | Labels map |

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
| Label `devcontainer.config_volumes` | Config `type=volume` names for prune |
| Label `devcontainer.workspace_folder` | Create-time container workdir for exec (both modes) |
| Label `devcontainer.remote_user` | Create-time effective user for exec (both modes; may be empty) |

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
- **Features derived image tag:** `adev-{base}:{hash12}` where `hash12` is the content hash of base image + features + **`recipeVersion`** (epoch string in `DerivedImageTag`); empty base → `adevcontainer:{hash12}`. No `adevcontainer/features:` prefix and no `/features` path segment. Config `image` without a Features build is left as written. Tag validity depends on sanitize collapse (above). **Bump `recipeVersion` whenever install-Dockerfile semantics change** so cached local derived images are not reused forever; current epoch **`"2"`** pairs with `chmod -R 0755` package before `install.sh` (generic install-layer change, not feature-specific).

Do not depend on Docker-style `ps --filter label=` as the primary discovery mechanism ([gaps](../domain/devcontainer-apple-gaps.md)).

## Named volumes (ensure / reuse)

- Before create, **ensureVolume** for each config named volume: **list first**. Sources must already have `${devcontainerId}` expanded (see above) — e.g. `adev-proj-abc123def456-shellhistory`, not a literal `${…}` token.
- If the volume already exists → status “already exists — reusing” and mount it; **never fail `up`/`clone` only because a config volume exists**.
- If missing → create, then mount.
- **Clone workspace volume:** if `adev-*-ws` already exists → **delete + create** (fresh tree), then mount as the workspace root (not a host bind).

## `clone` flow (volume-mode)

1. Require host `git` on `PATH` (config-only fetch + HTTPS credential fill). No bundled git; no PAT CLI flags (optional env `ADEVCONTAINER_GIT_TOKEN` escape hatch OK).
2. Host git: sparse/shallow **config-only** fetch into a temp dir (auth = host helpers/SSH agent; git argv puts `--` before the URL). Identity/labels use **normalized** URL (`scheme://` userinfo stripped); host git still gets the **original** URL.
3. Resolve `devcontainer.json` from that temp tree. **workspaceFolder** default and `${localWorkspaceFolderBasename}` use the **git URL repo basename**, not the host temp checkout directory name.
4. **Author identity (before Features/create):** host `git -C <sparse-temp> config --get user.name` / `user.email` (includeIf-aware). Env overrides: `ADEVCONTAINER_GIT_AUTHOR_NAME` / `ADEVCONTAINER_GIT_AUTHOR_EMAIL`. **Both env set** → use env, skip prompt (even on TTY). **TTY** and env incomplete: if both resolved → confirm `Use this identity? [Y/n]` (decline → collect name+email); if either missing → prompt for both (empty → fail structured, no Features/create). **Non-TTY:** no prompt; resolved/env silently when complete; incomplete → continue (warn at apply, no hang). Chosen values applied after populate (step 8).
5. **Ensure in-container git (Features path, not apt):** after resolve + identity, before the Features gate, if no admitted feature id is `git` or `common-utils` (any registry/tag or local path), append `ghcr.io/devcontainers/features/git:1` (empty options). Status: `==> Ensuring git feature for volume workspace`. Empty features → inject then enter FeaturesRunner. Already covered → no double-add. Config hash / effective features include the inject when added. **`up` does not inject.**
6. Ensure workspace volume (`adev-{base}-{hash12}-ws`); delete+create if present. Existing managed container name → fail closed (no silent reuse).
7. Create volume-mode container (workspace = named volume; labels as above) and start. Features runner runs when features non-empty after step 5.
   - **SSH URL:** require host `SSH_AUTH_SOCK` non-empty; inject `AllowlistedRunArg.ssh` (`container create --ssh`) if not already in runArgs. Missing agent → fail structured (hint ssh-agent / HTTPS). Later push uses the same forward.
   - **HTTPS:** no create-time auth flag; credentials applied at populate (step 8).
8. **Populate (in-container full clone)** — happy path is **not** host full clone + tar-pipe (`copyTreeIntoContainer` may remain as unused utility). After Features ensure git:
   - Exec in-container `git clone` of the URL into `workspaceFolder` (as `remoteUser` when set); verify `workspaceFolder/.git`.
   - **HTTPS auth:** host `git credential fill` (protocol/host/path; GCM/osxkeychain transparent — **no product GCM-in-guest**, no mount of host `~/.git-credentials`). Optional fallbacks: `ADEVCONTAINER_GIT_TOKEN`; `gh auth token` for github.com when `gh` available. When creds exist → one-shot into guest clone via GIT_ASKPASS/env (never log secrets; redact errors) → guest `credential.helper store` + `git credential approve` once. When fill empty → anonymous in-container clone (public); auth failure → structured hint to configure host credentials or use SSH.
   - **SSH auth:** agent already forwarded via `--ssh` from create.
   - **Author apply:** when **both** name+email from step 4 → guest `git config --local` both; if either missing → warn once, no partial write; no synthetic defaults.
9. Create-path lifecycle hooks (same order as fresh `up`). On start/populate/hook failure after create: delete container **and** workspace `*-ws` volume.
10. **Always** clean config-fetch temps (success or failure). No host full-clone staging temp on the happy path.

`up` remains bind-mode host workspace only (no auto git Feature). Detail: [architecture.md](../architecture.md); contract [`specs/clone.md`](../../specs/clone.md).

## Managed selection (`list` / lifecycle commands)

**Only `up` uses `-w`/cwd** (bind workspace path). All other lifecycle commands resolve a managed container via `--name` or interactive picker — never `-w`.

- `list [--json]`: client-side filter to `devcontainer.managed=adevcontainer` only.
- `start` / `exec` / `stop` / `delete` / `prune` / `rebuild` / `inspect`: `--name` or picker among managed; no host workspace path required.
- `start`: runtime start of a managed container; **volume-mode runs no hooks** (bind start-stopped `postStart` stays on `up` path).
- `exec`: user/workdir from labels `devcontainer.remote_user` / `devcontainer.workspace_folder` when set (both bind and volume create stamp these).

## `up` reuse vs `rebuild` (forced rebuild)

| Path | Behavior |
|------|----------|
| `up` create | Fresh bind-mode create when no managed container for identity |
| `up` reuse / start-stopped | Only when existing container's stamped config hash **equals** current resolve. Running → reuse (no Features re-run); stopped → start + bind `postStart` only |
| `up` config hash mismatch | Fail closed: `config_hash_mismatch`; **does not** delete or replace. Hint: `adevcontainer rebuild` (managed selection: `--name` or auto) |
| `rebuild` | **Forced rebuild** (landed; archive [`20260810-rebuild`](../../specs/changes/archive/20260810-rebuild/)): read current stamped config **before** any delete; hostRequirements + Features; then container-only delete old → create same name (bind) or reuse same `adev-*-ws` (volume; ensureVolume, never delete/replace workspace volume; no re-clone). Pre-delete failure leaves old container untouched. Optional `--skip-pull` / `--vscode` / `--json`. Volume-mode rebuild: OCI features only (local-path / host DefaultFeatureFetcher unsupported — fail clean pre-delete). Hard post-delete recovery mode-split (TTY `Open the recovery editor now? [Y/n]` default Y; decline/EOF retain; named retry skips prompt; README + CLI help document UX): [gaps — Failed rebuild recovery](../domain/devcontainer-apple-gaps.md#failed-rebuild-recovery-mode-split) |

## `prune` resource set

`prune` removes, in product order appropriate to the runtime:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`, via label) | Yes |
| Workspace volume `adev-*-ws` (volume-mode) | Yes |
| Config `image` reference | Yes |
| Derived Features tags (`adev-{base}:{hash12}` / `adevcontainer:{hash12}`) | **No** — not removed unless the tag equals config `image` |
| Bind-mount host paths | **No** |
| Global `volume prune` / `image prune` | **No** |

Missing resources are skipped. Exit non-zero only if deleting an **existing** resource fails. Contrast with `delete` (container only).

## Features runner

On `up`/`clone`/`rebuild` when `features` is non-empty after resolve (and after clone git-ensure; volume-mode rebuild admits OCI only). Code: `Sources/ADevContainerLib/Features/`.

| Step | Behavior |
|------|----------|
| Admit | Feature ref → options map; **OCI** (`ghcr.io/…/node:1`) and **local path** (`./…`, `../…`, absolute `/…`, `file://…` relative to workspace root); declaration key-sorted for stable ties |
| Warn-skip | Any ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (OCI or local) — drop from admitted list with warning; metadata `privileged` / `securityOpt` warn-stripped (not applied; feature may still install) ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)). Emit once per resolve — see [Warn-skip emit once](#warn-skip-emit-once-features--runargs) |
| build.rosetta | Before fetch/build: ensure Apple BuildKit `build.rosetta=false`. Already false → silent. True/missing → one-time TTY consent (or fail); CI auto-accept via `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`. Never install Rosetta; never restore `true` after consent. Config pickup uses `restartBuilderForConfig` (stop+delete only) — **not** the restore-after-build path below |
| Fetch / load | **Local path:** validate package (`devcontainer-feature.json` + `install.sh`) and copy into feature cache. **OCI:** embedded HTTPS client (`OCIFeatureClient`) — **not** `container image pull`, ORAS, or Node |
| Order | `dependsOn` / `installsAfter` topo-sort (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`); cycle → structured error |
| Build | Generate Dockerfile (`FeatureDockerfileGenerator`): per feature `COPY` package then **`RUN chmod -R 0755 /tmp/adev-feature-N && … ./install.sh`** as root — ref CLI parity (`@devcontainers/cli`); recursive +x so scripts `install.sh` copies to bare-path lifecycle hooks (e.g. shell-history `oncreate.sh`, often 0644 in OCI) stay executable and avoid exit **126** Permission denied; `container build --platform` host-native (`linux/arm64` on Apple Silicon) via `AppleContainerRuntime.build`; **no** `--rosetta` unless user opted in via `runArgs`; deterministic derived tag `adev-{base}:{hash12}` (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix); hash includes **`recipeVersion`** epoch — bump on install-Dockerfile semantic changes (current `"2"` = chmod-before-install); reuse when tag exists. See BuildKit builder lifecycle |
| Merge | Feature contributions into effective config before create (`init`, `capAdd`, mounts, lifecycle hooks; `containerEnv` **config wins**). PATH refs in env expanded on create **and** exec — see PATH expansion |
| Create | Workspace container from **derived image** with same `--platform` |
| Skip | Reuse-running path: no feature fetch/build |

### BuildKit builder lifecycle (Features image build)

adevcontainer does **not** pin the BuildKit image tag; Apple `container` owns builder image/version. We never `builder start` — `container build` may auto-start BuildKit.

On `AppleContainerRuntime.build` (Features derived image):

1. **Probe** `container builder status --format json` first.
2. **If builder was not running** (empty list or non-running state): after build finishes — success **or** failure (`defer`) — best-effort `builder stop` so we do not leave BuildKit up when the user had it stopped.
3. **If builder was already running**, or status is **undetermined** (probe/parse fail): do **not** stop after build.

`restartBuilderForConfig` (stop+delete for rosetta config pickup) is separate from this restore-after-build behavior.

**Fixtures:** `features-node`, `features-triple`, `features-local`, `features-docker-ood`, `features-sample/*`.

**Tests:** suite of record is `swift run adevcontainerTests`. Local E2E when Apple `container` available; OCI E2E opt-in `ADEVCONTAINER_FEATURES_E2E=1`. Recovery remaining gaps only: live non-TTY recovery E2E opt-in `ADEVCONTAINER_RECOVERY_E2E=1` (default suite skips); automated TTY recovery E2E absent (`ADEVCONTAINER_RECOVERY_E2E_TTY=1` surfaces skip guidance only; operator-validated). Recovery E2E bootstraps clone-origin labels/volumes when live `CloneCommand` populate is unreachable (guest DNS / host `file://`). Feature material for rebuild/recovery git inject must use a durable host path such as `~/Library/Caches` — Apple `container build` drops/breaks `/var/folders` temp contexts.

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

- Progress status lines on **stderr**: `==> …` (pull, create, start, stop, delete, volume create, Features Resolving/Fetching/Building/Reusing, build.rosetta config when changing, lifecycle `==> Running <property>`, and related long steps). StatusPrinter only — not hook script I/O.
- After successful `up`, `clone`, `start`, or `rebuild`, StatusPrinter emits two connection hints on stderr when the originating command lacks `--vscode`: terminal `adevcontainer exec -it --name <managed-name>` and VS Code `adevcontainer start --name <managed-name> --vscode`. Originating `--vscode` suppresses both; neither contaminates stdout or `--json` output.
- Tee Apple `container` stderr onto the same stream for those operations.
- **Lifecycle hook live stream (distinct from status):** hook child **stdout and stderr** are teed **live** to **host stderr** while still captured for failure diagnostics. Prevents long hooks looking stuck (previously capture-until-exit). Non-lifecycle `exec` stays capture-then-print (stream off by default).
- `--json` keeps **stdout** pure JSON — hook script stdout is teed to host **stderr**, never host stdout. `ADEVCONTAINER_QUIET=1` silences `==> …` status lines, including both connection hints; policy warn-skips and hook script output still emit.
- Under heavy dual-stream load, dual drain threads may interleave stdout/stderr bytes on host stderr.
- **Test tip:** assert stream flags on the lifecycle `exec` call itself — delete-on-fail invoke also streams and can overwrite mock “last flag” fields.

## Lifecycle execution (hook matrix)

Hooks run via runtime **exec** into the running container (effective user + workspace folder when set). Omitted properties and empty `{}` maps are no-ops. Nested objects rejected. Exec env PATH expansion applies (see PATH expansion). **Live I/O:** lifecycle exec enables streamOutput — child stdout+stderr teed live to host stderr (still captured for error messages); status `==> Running …` is separate StatusPrinter output. Contract: [`specs/lifecycle-hooks.md`](../../specs/lifecycle-hooks.md).

### Command forms (`LifecycleCommand`)

Each hook property admits **string** | **argv `string[]`** | **object map** `name → string|argv` (Dev Containers named/parallel JSON shape).

| Form | Parse / run |
|------|-------------|
| string | shell via `sh -lc` (same as historical `postCreateCommand`) |
| argv array | exec argv directly |
| object map | `LifecycleCommand.parallel([NamedLifecycleCommand…])`; empty `{}` → nil; values must be string or argv (not nested objects) |

**Object-map execution (product choice):** named entries run **sequentially, sorted by name** — fail-fast on first non-zero. Not true parallel (reference `@devcontainers/cli` may run named entries concurrently). Status labels use `property (name)` (e.g. `onCreateCommand (shell-history)`).

**Why it matters:** third-party Features often emit map-form hooks (e.g. `ghcr.io/stuartleeks/dev-container-features/shell-history:0` → `onCreateCommand: { "shell-history": "…" }`). Admitting only string/argv rejected those Features at resolve.

| Path | Hooks / apply |
|------|----------------|
| Fresh create (`up` bind, `clone` volume, or `rebuild` replacement) | `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand` → **settings apply** (soft-fail; not gated on `--vscode`) |
| Reuse running (`up`, config hash match) | no create-path hooks; settings repair on marker drift; feature postAttach mergeable from image metadata when gated open succeeds |
| Config hash mismatch (`up`) | fail `config_hash_mismatch`; no hooks/delete; remediate with `rebuild` |
| Bind start-stopped (`up`, hash match) | `postStartCommand` only |
| Bare `start` | no create-path / postStart; settings repair on marker drift when config loadable; extensions + postAttach only via gate below |
| `customizations.vscode` | **CLI apply** config-file v1 (`VSCodeCustomizationsApply`): settings create-path / drift repair; extensions after successful `--vscode` open only (host VSIX → tar-pipe → unzip → **`extensions.json` registry upsert** + cache invalidate; BFS `extensionDependencies`; soft-fail per ID); then postAttach. Soft-fail apply ≠ postAttach fail-keep. Marker `$HOME/.adevcontainer/vscode-customizations.applied` (config payload hash only). Not image build; not feature/metadata merge; Apple attach does not auto-install. Detail: [architecture.md — VS Code flow](../architecture.md#vs-code-flow) |
| `postAttachCommand` | **implemented** on `up`/`start`/`clone`/`rebuild`: after open success and after extensions apply — **RUNS** config then feature postAttach; **SKIP** + status if no flag or open soft-fails (no status line if absent). Not always-skip-forever. Contract: [`specs/vscode.md`](../../specs/vscode.md); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../../specs/changes/archive/20260808-vscode-customizations-apply/) |

- Capture exit codes; failed hook fails the command — do not pretend success.
- **Create-path failure** (any of onCreate / updateContent / postCreate / postStart on fresh create): delete the container **before** returning failure, so reuse cannot treat a half-bootstrapped container as healthy. Customizations apply is **not** part of create-path delete-on-fail.
- **Bind start-stopped `postStartCommand` failure:** fail `up` but **do not** delete.
- **postAttach failure** (when it runs): fail the command; **do not** delete/stop the container (fail-keep; contrast create-path delete-on-fail). Open soft-fail alone does not fail the command and must not run extensions apply or postAttach.
- **customizations apply soft-fail:** warn stderr; never fail lifecycle exit; never delete/stop solely due to settings/extensions apply. Contrasts postAttach fail-keep.
- **postAttach / apply config load:**
  - `up`/`clone`: use resolved config; on reuse/restart merge feature postAttach from image `devcontainer.metadata` (no Features re-run); vscode extensions/settings from resolved config.
  - bare `start`: load from labels — bind: host `local_folder` + `config_file`; volume: cat stamped config path in-container; merge feature postAttach from image/container metadata. Load errors → treat absent (preserve start success).

## `exec`: selection, interactive vs non-interactive

- **Selection:** `--name` or interactive picker among managed only — **no `-w`/cwd** (that flag is `up`-only). Workdir/user from labels `devcontainer.workspace_folder` / `devcontainer.remote_user` when set at create (bind or volume).
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
