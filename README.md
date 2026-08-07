# adevcontainer

Native Swift CLI that reads `devcontainer.json` and runs workspaces on **Apple `container`** (macOS 26+ Apple Silicon).

## Why

Upstream `@devcontainers/cli` is Node/Docker-oriented. This tool is greenfield Swift with a single host dependency: Apple `container`.

## Prerequisites

Install these on the host before building or running (not bundled with this project):

- macOS 26+ on Apple Silicon
- Swift 6.x toolchain (`swift build` / `swift test`)
- Apple [`container`](https://github.com/apple/container) CLI (typical path `/usr/local/bin/container`) with system status `running`

Compatibility note: integration is tested against Apple container **1.2.x** machine JSON. `adevcontainer doctor` checks that the binary is present, reports version, and that the system is running.

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

Long operations (`up`, and runtime steps under stop/delete/prune) print progress lines on **stderr** (`==> …`) and tee Apple `container` stderr there as well. `--json` still keeps stdout pure JSON. Set `ADEVCONTAINER_QUIET=1` to silence progress status.

### Lifecycle hooks / runArgs / hostRequirements

On **fresh create**, lifecycle hooks run via `container exec` in order:

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

| `up` path | Hooks |
|-----------|--------|
| Fresh create | full order above; container is **deleted** if any create-path hook fails |
| Reuse running | no lifecycle hooks |
| Start stopped | `postStartCommand` only; failure fails `up` but does **not** delete |
| `postAttachCommand` present | admitted; **not** run on `up`; one status: `postAttach skipped (no attach hook)` |

**runArgs allowlist** (mapped onto `container create`; empty/`[]` OK; `=VALUE` or two-token):

- `--init`, `--cap-add`, `--cap-drop`
- `--shm-size`, `--dns`, `--dns-search`, `--dns-option`, `--dns-domain`, `--no-dns`
- `--ulimit`, `--tmpfs` (path before `:` if Docker opts present)
- `--cpus`/`-c`, `--memory`/`-m` — merge into create `-c`/`-m` (hostRequirements wins per dimension when set)
- `--network=NAME` (named only; not host/bridge/none/container:*)
- `--rosetta`, `--ssh`, `--read-only`

Forever-reject: `--privileged`, `--device…`, `--security-opt`, `--gpus`, Docker-only network modes, first-class flags (`-e`/`-p`/`-v`/…), and any other non-allowlisted flag.

**hostRequirements** preflight: parse `memory` (`8gb` / `8192mb`) and `cpus`; **fail `up`** on capacity shortfall or unreadable host; when host OK, pass requested limits to `container create` (`-m`/`-c`); absent → no limit flags; **warn** that `gpu` is unsupported (does not fail alone); **fail** on unparseable values or unknown keys.

## Fixtures

Pure JSON samples under `Tests/Fixtures/`:

- `smoke.json` — image + workspace bind
- `env-user.json` — env, user, workspaceFolder
- `mounts-ports.json` — mounts, forwardPorts, portsAttributes
- `lifecycle.json` — postCreateCommand
- `lifecycle-hooks.json` — lifecycle hooks (+ admitted postAttach)
- `runargs-host.json` — allowlisted runArgs + hostRequirements

## VS Code attach

After `up`, the container is running and listable. Attach manually with experimental **Attach to Running Apple Container**. This CLI does **not** implement full Dev Containers extension parity or auto-attach. `postAttachCommand` is admitted but not executed on `up`.

## Non-goals (current)

- No Docker Compose driver
- No `docker-outside-of-docker` / features runner
- No `--privileged` or `--device` (including tun)
- No blind `runArgs` passthrough (runArgs allowlist only)
- No full `postAttachCommand` execution / IDE attach hook
- No Node / `@devcontainers/cli` dependency

## Tests

Command Line Tools hosts do not ship `XCTest.framework`, so the suite of record is the Foundation MiniTest executable `adevcontainerTests` (plain `swift test` reports “no tests found” without full Xcode):

```bash
swift run adevcontainerTests
```

Unit + integration coverage via `swift run adevcontainerTests` (discovery, JSONC, substitution, admission, lifecycle, runArgs, hostRequirements, runtime argv mocks, commands, optional real-container integration). **~105 passed** (runArgs allowlist + hostRequirements enforce+apply). Integration skips cleanly if Apple `container` is unavailable. Override image with `ADEVCONTAINER_TEST_IMAGE`.

## Architecture

```
devcontainer.json → Config resolver → AppleContainerRuntime → container CLI
```

Only `AppleContainerRuntime` invokes `container`. Labels: `devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.config_hash`.

Delivery planning: see `wiki/domain/phase-ladder.md`. Next: Features.

**Spec:** realized contract `specs/adevcontainer/spec.md` (core + lifecycle + runArgs allowlist + hostRequirements). No active change open. Archived: `specs/changes/archive/20260807-adevcontainer-core/`, `specs/changes/archive/20260807-lifecycle-runargs-host/`.
