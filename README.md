# adevcontainer

Native Swift CLI that reads `devcontainer.json` and runs workspaces on **Apple `container`** (macOS 26+ Apple Silicon). Phases 0–3 only.

## Why

Upstream `@devcontainers/cli` is Node/Docker-oriented. This tool is greenfield Swift with a single host dependency: Apple `container`.

## Prerequisites

- macOS 26+ on Apple Silicon
- Swift 6.x toolchain (`swift build` / `swift test`)
- Apple `container` CLI (typically `/usr/local/bin/container`) with system status `running`

## Build

```bash
swift build
# binary:
.build/debug/adevcontainer
```

Release:

```bash
swift build -c release
```

## Commands

| Command | Purpose |
|---------|---------|
| `adevcontainer doctor` | Verify Apple `container` binary, version, system status |
| `adevcontainer up [--json] [--recreate] [--skip-pull]` | Create / start / reuse workspace container |
| `adevcontainer exec [-it] [--] [cmd...]` | Run a command, or interactive shell (`exec` / `exec -it`) |
| `adevcontainer stop` | Stop the workspace container |
| `adevcontainer delete` | Remove the workspace container only |
| `adevcontainer prune` | Remove container **and** named volumes from config **and** config image |
| `adevcontainer inspect` | Identity, state, labels, `portsAttributes` metadata |

Global: `-w, --workspace <path>` (default: current directory).

### Quick start

```bash
adevcontainer doctor
adevcontainer up --json
adevcontainer exec -- echo hello
adevcontainer exec            # interactive TTY shell (bash)
adevcontainer inspect
adevcontainer stop
adevcontainer delete
# or stronger cleanup (container + named volumes + image from this config):
adevcontainer prune
```

Config discovery order: `.devcontainer/devcontainer.json`, then `.devcontainer.json`.

On config hash mismatch with an existing container, `up` errors. Use `up --recreate` to delete and recreate.

Named volumes from config: `up` lists first and **reuses** an existing volume (status “already exists — reusing”); it never fails solely because the volume already exists.

`delete` removes only the workspace container. `prune` also deletes named volumes listed in config `mounts` (`type=volume`) and the config `image` reference. It does **not** delete bind-mount host paths or run global `volume prune` / `image prune`. Missing resources are skipped; exit non-zero only if deleting an existing resource fails.

Long operations (`up`, and runtime steps under stop/delete/prune) print phase lines on **stderr** (`==> …`) and tee Apple `container` stderr there as well. `--json` still keeps stdout pure JSON. Set `ADEVCONTAINER_QUIET=1` to silence phase status.

## Phase fixtures

Pure JSON samples under `Tests/Fixtures/`:

- `smoke.json` — image + workspace bind
- `env-user.json` — env, user, workspaceFolder
- `mounts-ports.json` — mounts, forwardPorts, portsAttributes
- `lifecycle.json` — postCreateCommand

## VS Code attach

After `up`, the container is running and listable. Attach manually with experimental **Attach to Running Apple Container**. This CLI does **not** implement full Dev Containers extension parity or auto-attach.

## Non-goals (MVP)

- No Docker Compose driver
- No `docker-outside-of-docker` / features runner
- No `--privileged` or `--device` (including tun)
- No blind `runArgs` passthrough (allowlist empty)
- No Node / `@devcontainers/cli` dependency

## Tests

Command Line Tools hosts do not ship `XCTest.framework`, so the suite of record is the Foundation MiniTest executable `adevcontainerTests` (plain `swift test` reports “no tests found” without full Xcode):

```bash
swift run adevcontainerTests
```

Unit + integration coverage via `swift run adevcontainerTests` (discovery, JSONC, substitution, admission, runtime argv mocks, commands, optional real-container integration). Integration skips cleanly if Apple `container` is unavailable. Override image with `ADEVCONTAINER_TEST_IMAGE`.

## Architecture

```
devcontainer.json → Config resolver → AppleContainerRuntime → container CLI
```

Only `AppleContainerRuntime` invokes `container`. Labels: `devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.config_hash`.

**Spec:** realized contract `specs/adevcontainer/spec.md` (Phases 0–3). Archived change: `specs/changes/archive/20260807-adevcontainer-core/`.
