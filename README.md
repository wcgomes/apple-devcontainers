# apple-dev-containers (adevcontainer)

[![CI](https://github.com/wcgomes/apple-dev-containers/actions/workflows/ci.yml/badge.svg)](https://github.com/wcgomes/apple-dev-containers/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-156%2B-brightgreen)](https://github.com/wcgomes/apple-dev-containers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Native Swift CLI that reads `devcontainer.json` and runs workspaces on **Apple `container`** (only host runtime dependency). Upstream `@devcontainers/cli` is Node/Docker-oriented; this is greenfield Swift.

## Install

**Requirements:**

- macOS 26+ on Apple Silicon
- Apple [`container`](https://github.com/apple/container) installed separately

### Homebrew (recommended)

```bash
brew install wcgomes/tap/adevcontainer
```

Tap: [`github.com/wcgomes/homebrew-tap`](https://github.com/wcgomes/homebrew-tap).

### GitHub Release binary

From [Releases](https://github.com/wcgomes/apple-dev-containers/releases), download `adevcontainer-macos-arm64.tar.gz` and `adevcontainer-macos-arm64.tar.gz.sha256`, then:

```bash
shasum -a 256 -c adevcontainer-macos-arm64.tar.gz.sha256
tar xzf adevcontainer-macos-arm64.tar.gz
sudo mv adevcontainer /usr/local/bin/   # or ~/bin on PATH
```

### From source

See [Contributing](#contributing). After a release build: `cp .build/release/adevcontainer /usr/local/bin/`.

After install:

```bash
adevcontainer doctor
```

## Features

### Commands

| Command | Purpose |
|---------|---------|
| `adevcontainer doctor` | Verify Apple `container` binary, version, system status |
| `adevcontainer up [--json] [--recreate] [--skip-pull]` | Create / start / reuse workspace container |
| `adevcontainer exec [-it] [--] [cmd...]` | Run a command, or interactive shell (`exec` / `exec -it`) |
| `adevcontainer stop` | Stop the workspace container |
| `adevcontainer delete` | Remove the workspace container only |
| `adevcontainer prune` | Remove container, named volumes from config, and config image |
| `adevcontainer inspect` | Identity, state, labels, `portsAttributes` metadata |

Global: `-w, --workspace <path>` (default: current directory).

### Quick start

```bash
adevcontainer up
adevcontainer exec -- echo hello
adevcontainer exec            # interactive TTY shell (bash)
adevcontainer inspect
adevcontainer stop
adevcontainer delete
adevcontainer prune
```

### Config and workspace behavior

Config discovery order: `.devcontainer/devcontainer.json`, then `.devcontainer.json`.

- **Config hash mismatch** with an existing container → `up` errors. Use `up --recreate` to delete and recreate.
- **Named volumes** from config: `up` lists first and **reuses** an existing volume (status “already exists — reusing”); it never fails solely because the volume already exists.
- **`delete` vs `prune`:** `delete` removes only the workspace container. `prune` also deletes named volumes listed in config `mounts` (`type=volume`) and the config `image` reference. Neither deletes bind-mount host paths nor runs global `volume prune` / `image prune`. Missing resources are skipped; exit non-zero only if deleting an existing resource fails.
- **Progress** on long operations (`up`, and runtime steps under stop/delete/prune) prints on **stderr** (`==> …`) and tees Apple `container` stderr there. `--json` keeps stdout pure JSON. `ADEVCONTAINER_QUIET=1` silences progress.

### Lifecycle hooks

On **fresh create**, hooks run via `container exec` in order:

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

| `up` path | Hooks |
|-----------|--------|
| Fresh create | full order above; container is **deleted** if any create-path hook fails |
| Reuse running | none |
| Start stopped | `postStartCommand` only; failure fails `up` but does **not** delete the container |
| `postAttachCommand` | admitted; **not** run on `up`; status: `postAttach skipped (no attach hook)` |

### runArgs allowlist

Mapped onto `container create` (empty/`[]` OK; `=VALUE` or two-token):

| Allowed | Notes |
|---------|--------|
| `--init`, `--cap-add`, `--cap-drop` | |
| `--shm-size`, `--dns`, `--dns-search`, `--dns-option`, `--dns-domain`, `--no-dns` | |
| `--ulimit`, `--tmpfs` | path before `:` if Docker opts present |
| `--cpus`/`-c`, `--memory`/`-m` | merge into create `-c`/`-m`; hostRequirements wins per dimension when set |
| `--network=NAME` | named only; not host/bridge/none/container:\* |
| `--rosetta`, `--ssh`, `--read-only` | |

**Forever-reject:** `--privileged`, `--device…`, `--security-opt`, `--gpus`, Docker-only network modes, first-class flags (`-e`/`-p`/`-v`/…), and any other non-allowlisted flag.

### hostRequirements

Preflight parses `memory` (`8gb` / `8192mb`) and `cpus`:

- **Fail `up`** on capacity shortfall or unreadable host
- When host OK, pass requested limits to `container create` (`-m`/`-c`); absent → no limit flags
- **Warn** that `gpu` is unsupported (does not fail alone)
- **Fail** on unparseable values or unknown keys

### Features (OCI + local path)

`up` admits a top-level `features` object map of **feature ref → options**. Refs may be:

- **OCI** — e.g. `ghcr.io/devcontainers/features/node:1`
- **Local path** — `./…`, `../…`, absolute `/…`, or `file://…` (resolved relative to the **workspace root**; directory must contain `devcontainer-feature.json` + `install.sh`)

The Features path mirrors official Dev Containers (Dockerfile + `container build`) on **native arm64** — never `--rosetta` by default:

1. **One-time consent** (only if needed): when Apple BuildKit still has `build.rosetta=true` (or the key is missing), `up` explains and asks once to set `build.rosetta=false` so feature image builds do not require Rosetta. Already `false` → silent. Decline → fail. Non-interactive: set `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` to auto-accept, or set the config yourself.
2. Loads local path packages from disk into the feature cache, or fetches OCI artifacts over HTTPS (embedded registry client — **not** `container image pull`, ORAS, or Node).
3. Orders installs via `dependsOn` / `installsAfter` (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`) and merges runtime contributions (`init`, `capAdd`, `containerEnv` with **config wins**, mounts, lifecycle hooks). On create, `${PATH}` / `$PATH` in env values are expanded (Apple `container` does not expand them).
4. Generates a Dockerfile and runs `container build --platform linux/arm64` to a deterministic `adev-{base}:{hash12}` tag (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix; reuse when the tag already exists).
5. Creates from the **derived image** with the same platform flag, then runs lifecycle hooks.

**Forever-reject:** any feature ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (OCI or local path); feature metadata with `privileged: true` or `securityOpt`.

**Hash note (v1):** local path identity uses the path string + options; editing files under the same path may not invalidate the derived tag until the path or options change.

### VS Code attach

After `up`, the container is running and listable. Attach manually with experimental **Attach to Running Apple Container**. This CLI does not auto-attach.

### Non-goals (current)

- No Docker Compose driver
- No full Dev Containers extension / IDE attach parity
- No Node / `@devcontainers/cli` / ORAS dependency

### Architecture

```
devcontainer.json → Config resolver → [Features runner] → AppleContainerRuntime → container CLI
```

Only `AppleContainerRuntime` invokes `container`. Labels: `devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.config_hash`.

## Contributing

### Prerequisites

- [Install requirements](#install) (macOS 26+ Apple Silicon, Apple `container`)
- Swift 6.x toolchain
- Integration tests expect `container` system status `running` (typical path `/usr/local/bin/container`; tested **1.2.x**)

### Build from source

```bash
swift build
# binary: .build/debug/adevcontainer

swift build -c release
# binary: .build/release/adevcontainer
```

### Tests

Command Line Tools hosts do not ship `XCTest.framework`, so the suite of record is the Foundation MiniTest executable `adevcontainerTests` (plain `swift test` may report “no tests found” without full Xcode):

```bash
swift run adevcontainerTests
```

~156+ offline tests (discovery, JSONC, substitution, admission, lifecycle, runArgs, hostRequirements, Features runner mocks + local path fixtures, runtime argv mocks, commands, optional real-container integration).

- Integration skips cleanly if Apple `container` is unavailable.
- Local features E2E runs when Apple `container` is up (no ghcr gate).
- Override image: `ADEVCONTAINER_TEST_IMAGE`.
- Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`.

### Fixtures

Pure JSON samples under [`Tests/Fixtures/`](Tests/Fixtures/), including smoke, env/user, mounts/ports, lifecycle hooks, runArgs/hostRequirements, OCI and local Features, and forever-reject cases (e.g. docker-ood). On-disk sample feature packages live under `Tests/Fixtures/features-sample/`.
