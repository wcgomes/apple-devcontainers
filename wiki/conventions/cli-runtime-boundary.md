# Convention: CLI ↔ Apple container runtime boundary

All host runtime interaction goes through **AppleContainerRuntime**. No other module shells out to `container`.

## Subprocess rules

- Invoke Apple `container` as a subprocess (typical binary: `/usr/local/bin/container`).
- Prefer/require **machine-readable JSON** output for anything parsed.
- **Parse only machine JSON** — never scrape human tables/TTY text for control flow.
- Non-zero exit + stderr → map to structured CLI errors (command, args class, message).
- `doctor` validates binary presence/version/runnability before `up` paths rely on it.
- **ProcessRunner:** async-drain stdout/stderr pipes before and during `wait`, or a full pipe can deadlock the child.

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

- Resolver owns JSONC + substitution (`${localEnv:*}`, `${localWorkspaceFolderBasename}`, related supported vars).
- Resolver emits a runtime request DTO; runtime maps DTO → argv + env for `container`.
- Unsupported props/flags fail in resolver or runtime admission — **fail closed**, no drop-on-floor.

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
  - `--network=NAME` — **named networks only** (reject host/bridge/none/container:*)
  - `--rosetta`, `--ssh`, `--read-only`
- **Not via runArgs** (first-class props): `-e`/`-u`/`-w`/`-p`/`-v`/`--mount`/`--name`/`--label`/`-i`/`-t`/`-d`/`--rm`/`--entrypoint`.
- Forever-reject: `--privileged`, `--device=…` (incl. `/dev/net/tun`), `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`, Docker-only network modes, and any flag not on the allowlist. See [0002](../decisions/0002-reject-docker-ood-privileged-tun.md).
- Unknown or incomplete entries (e.g. bare `--cap-add` with no name) → structured error naming the entry.

## hostRequirements preflight

- Evaluate on every `up` before create/start/reuse — never silent ignore.
- Supported keys: `memory` (e.g. `8gb` / `8192mb`), `cpus` (number).
- **Fail `up`** on capacity shortfall or when host memory/cpus cannot be read while required.
- When host has capacity: map **requested** values onto `container create` as `-m` / `-c` (Apple size suffixes); absent/empty → no limit flags.
- **Warn** that `gpu` is unsupported when present (does not fail alone; no create flags).
- **Fail** if `hostRequirements` is present but not an object, a supported key is unparseable, or an unknown key appears inside the object.
- Config hash includes memory/cpus when set (limits affect create identity).

## Deterministic names and labels

Set on create and use for reuse/inspect:

| Mechanism | Purpose |
|-----------|---------|
| Deterministic container name (`create --name` = id) | Stable identity without label-filter list APIs |
| Label `devcontainer.local_folder` | Workspace path binding |
| Label `devcontainer.config_file` | Config file identity |
| App config hash label | Detect config drift / recreate need |

**Naming rules**

- **Human base:** `sanitize(devcontainer.json name)` if present and non-empty after trim; else `sanitize(workspace folder basename)`. DNS-safe: lowercase; non-`[a-z0-9-]` → `-`; trim hyphens; clip base ~20 chars. `name` drives identity when set (not metadata-only).
- **Container name:** `adev-{base}-{hash12}` where `hash12` hashes workspace path + config path; empty base → `adev-{hash12}`; full name ≤63 chars.
- **Features derived image tag:** `adev-{base}:{hash12}` where `hash12` is the content hash of base image + features; empty base → `adevcontainer:{hash12}`. No `adevcontainer/features:` prefix and no `/features` path segment. Config `image` without a Features build is left as written.

Do not depend on Docker-style `ps --filter label=` as the primary discovery mechanism ([gaps](../domain/devcontainer-apple-gaps.md)).

## Named volumes on `up` (ensure / reuse)

- Before create, **ensureVolume** for each config named volume: **list first**.
- If the volume already exists → status “already exists — reusing” and mount it; **never fail `up` only because the volume exists**.
- If missing → create, then mount.

## `prune` resource set

`prune` removes, in product order appropriate to the runtime:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`) | Yes |
| Config `image` reference | Yes |
| Derived Features tags (`adev-{base}:{hash12}` / `adevcontainer:{hash12}`) | **No** — not removed unless the tag equals config `image` |
| Bind-mount host paths | **No** |
| Global `volume prune` / `image prune` | **No** |

Missing resources are skipped. Exit non-zero only if deleting an **existing** resource fails. Contrast with `delete` (container only).

## Features runner

On `up` when `features` is non-empty (code: `Sources/ADevContainerLib/Features/`):

| Step | Behavior |
|------|----------|
| Admit | Feature ref → options map; **OCI** (`ghcr.io/…/node:1`) and **local path** (`./…`, `../…`, absolute `/…`, `file://…` relative to workspace root); declaration key-sorted for stable ties |
| Reject | Any ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (forever, OCI or local); metadata `privileged` / `securityOpt` ([0002](../decisions/0002-reject-docker-ood-privileged-tun.md)) |
| build.rosetta | Before fetch/build: ensure Apple BuildKit `build.rosetta=false`. Already false → silent. True/missing → one-time TTY consent (or fail); CI auto-accept via `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`. Never install Rosetta; never restore `true` after consent. Config pickup uses `restartBuilderForConfig` (stop+delete only) — **not** the restore-after-build path below |
| Fetch / load | **Local path:** validate package (`devcontainer-feature.json` + `install.sh`) and copy into feature cache. **OCI:** embedded HTTPS client (`OCIFeatureClient`) — **not** `container image pull`, ORAS, or Node |
| Order | `dependsOn` / `installsAfter` topo-sort (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`); cycle → structured error |
| Build | Generate Dockerfile (`RUN` each `install.sh` as root); `container build --platform` host-native (`linux/arm64` on Apple Silicon) via `AppleContainerRuntime.build`; **no** `--rosetta` unless user opted in via `runArgs`; deterministic derived tag `adev-{base}:{hash12}` (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix); reuse when tag exists. See BuildKit builder lifecycle |
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

**Tests:** suite of record is `swift run adevcontainerTests`. Local E2E when Apple `container` available; OCI E2E opt-in `ADEVCONTAINER_FEATURES_E2E=1`.

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

- Progress status lines on **stderr**: `==> …` (pull, create, start, stop, delete, volume create, Features Resolving/Fetching/Building/Reusing, build.rosetta config when changing, and related long steps).
- Tee Apple `container` stderr onto the same stream for those operations.
- `--json` keeps **stdout** pure JSON. `ADEVCONTAINER_QUIET=1` silences progress status lines.

## Lifecycle execution (hook matrix)

Hooks run via runtime **exec** into the running container (effective user + workspace folder when set). String or argv-array forms. Omitted properties are no-ops. Exec env PATH expansion applies (see PATH expansion).

| `up` path | Hooks |
|-----------|--------|
| Fresh create | `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand` |
| Reuse running | none |
| Start stopped | `postStartCommand` only |
| `postAttachCommand` | admitted; **skipped on `up`** (one status line; no attach hook yet) |

- Capture exit codes; failed hook fails `up` — do not pretend success.
- **Create-path failure** (any of onCreate / updateContent / postCreate / postStart on fresh create): delete the container **before** returning failure from `up`, so reuse cannot treat a half-bootstrapped container as healthy.
- **Start-stopped `postStartCommand` failure:** fail `up` but **do not** delete.

## `exec`: interactive vs non-interactive

- **Interactive** (`adevcontainer exec` with no command, or with `-i` / `-t` / `-it`): **InteractiveProcessRunner** (inherit stdio) + `container exec -i -t`; default command is `bash`.
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
