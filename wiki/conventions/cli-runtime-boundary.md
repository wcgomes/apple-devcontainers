# Convention: CLI ↔ Apple container runtime boundary

All host runtime interaction goes through **AppleContainerRuntime**. No other module shells out to `container`.

## Subprocess rules

- Invoke Apple `container` as a subprocess (typical binary: `/usr/local/bin/container`).
- Prefer/require **machine-readable JSON** output for anything parsed.
- **Parse only machine JSON** — never scrape human tables/TTY text for control flow.
- Non-zero exit + stderr → map to structured CLI errors (command, args class, message).
- `doctor` validates binary presence/version/runnability before `up` paths rely on it.
- **ProcessRunner:** async-drain stdout/stderr pipes before and during `wait`, or a full pipe can deadlock the child.

## Apple container 1.2.1 JSON (list/inspect)

Parse these paths from machine JSON (not human tables):

| Path | Meaning |
|------|---------|
| `configuration.id` | Container id (same value as `create --name` when name is set) |
| `status.state` | Lifecycle state |
| `configuration.labels` | Labels map |

- `container create --name <id>` — the name **is** the id used later for inspect/exec/stop/delete.
- **No label filter on `list`** — filter client-side after JSON list (or resolve by deterministic name/inspect).
- Long-lived devcontainers: keep-alive via `--entrypoint` + `sleep … infinity` (or equivalent) so the process does not exit immediately.

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
- Only explicitly allowlisted flags/shapes may reach argv.
- Always reject (v1): `--privileged`, `--device=…` (incl. `/dev/net/tun`), and any flag not on the allowlist.
- Unknown `runArgs` entries → structured error naming the entry.

## Deterministic names and labels

Set on create and use for reuse/inspect:

| Mechanism | Purpose |
|-----------|---------|
| Deterministic container name (`create --name` = id) | Stable identity without label-filter list APIs |
| Label `devcontainer.local_folder` | Workspace path binding |
| Label `devcontainer.config_file` | Config file identity |
| App config hash label | Detect config drift / recreate need |

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
| Bind-mount host paths | **No** |
| Global `volume prune` / `image prune` | **No** |

Missing resources are skipped. Exit non-zero only if deleting an **existing** resource fails. Contrast with `delete` (container only).

## Progress / tee

- Phase status lines on **stderr**: `==> …` (pull, create, start, stop, delete, volume create, and related long steps).
- Tee Apple `container` stderr onto the same stream for those operations.
- `--json` keeps **stdout** pure JSON. `ADEVCONTAINER_QUIET=1` silences phase status lines.

## Lifecycle execution

- Lifecycle hooks in MVP (`postCreateCommand`) run via runtime **exec** into the running container.
- Capture exit codes; failed lifecycle fails `up` — do not pretend success.
- **On postCreate failure:** delete the container **before** returning failure from `up`, so reuse cannot treat a half-bootstrapped container as healthy.

## `exec`: interactive vs non-interactive

- **Interactive** (`adevcontainer exec` with no command, or with `-i` / `-t` / `-it`): **InteractiveProcessRunner** (inherit stdio) + `container exec -i -t`; default command is `bash`.
- **Non-interactive** (command exec without those flags): capture stdout/stderr pipes; do **not** pass `-i`/`-t`.

## Ports

- `forwardPorts` → publish/port-mapping flags supported by Apple container.
- Do not implement or promise Docker Desktop / VS Code auto-forward side channels.

## Non-goals at this boundary

- Embedding a container engine / talking gRPC-private APIs unless product later re-decides.
- Spawning Docker or Node to “help” Apple container.
- Emulating privileged or device nodes.
