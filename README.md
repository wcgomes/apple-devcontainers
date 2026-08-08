# Apple Dev Container CLI (adevcontainer)

[![CI](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml/badge.svg)](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-245%2B-brightgreen)](https://github.com/wcgomes/apple-devcontainers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Native Swift CLI that reads `devcontainer.json` and runs workspaces on **Apple `container`**.

Clone a git repo into a named container volume (faster disk I/O than bind mounts), or `up` an existing checkout. Applies a practical subset—lifecycle hooks and Features included.

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

From [Releases](https://github.com/wcgomes/apple-devcontainers/releases), download `adevcontainer-macos-arm64.tar.gz` and `adevcontainer-macos-arm64.tar.gz.sha256`, then:

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
| `adevcontainer doctor` | Check Apple `container` readiness |
| `adevcontainer up [-w path]` | Create/start workspace from a **host** checkout (only command that uses `-w`; default cwd) |
| `adevcontainer clone <git-url>` | Clone a git repo into a **named volume** and start the devcontainer (HTTPS or SSH) |
| `adevcontainer list [--json]` | List managed containers |
| `adevcontainer start \| stop \| delete \| prune \| inspect [--name]` | Lifecycle by container name (or interactive picker) |
| `adevcontainer exec [-it] [--name] [--] [cmd…]` | Shell or command in a running managed container |

### Quick start

**Local checkout** (`up`):

```bash
adevcontainer up
adevcontainer exec -it
adevcontainer stop
```

**Clone a repository** (no local checkout required — source lives in a volume for better I/O on Apple `container`):

```bash
adevcontainer clone https://github.com/org/repo.git   # or git@github.com:org/repo.git
adevcontainer list
adevcontainer exec --name <name> -it
adevcontainer prune --name <name>
```

Uses your Mac git credentials (HTTPS helpers / SSH agent), confirms author identity on a TTY, and ensures `git` in the image when needed. Work, commit, and push inside the container.

### Config and workspace behavior

Config: `.devcontainer/devcontainer.json`, else `.devcontainer.json`.

- **`up`** bind-mounts the host folder. **`clone`** uses volume `adev-*-ws` (no host checkout to edit).
- Config hash mismatch → `up` errors; use `--recreate`.
- **`delete`** = container only. **`prune`** = container + named volumes (including clone `*-ws`) + config image. Never deletes host bind paths.
- Progress on **stderr** (`==> …`). `ADEVCONTAINER_QUIET=1` silences it. `--json` keeps stdout clean.

### Lifecycle hooks

Fresh create (`up` or `clone`, after the tree exists):

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

| Path | Hooks |
|------|--------|
| Fresh create | full order; container deleted if any fail |
| Reuse running | none |
| `up` start stopped | `postStartCommand` only |
| `start` (managed) | none |
| `postAttachCommand` | admitted, not run by this CLI |

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

Preflight on **`up` and `clone`** parses `memory` (`8gb` / `8192mb`) and `cpus`:

- **Fail `up` / `clone`** on capacity shortfall or unreadable host
- When host OK, pass requested limits to `container create` (`-m`/`-c`); absent → no limit flags
- **Warn** that `gpu` is unsupported (does not fail alone)
- **Fail** on unparseable values or unknown keys

### Features (OCI + local path)

`up` and `clone` admit a top-level `features` object map of **feature ref → options**. Refs may be:

- **OCI** — e.g. `ghcr.io/devcontainers/features/node:1`
- **Local path** — `./…`, `../…`, absolute `/…`, or `file://…` (resolved relative to the **workspace root**; directory must contain `devcontainer-feature.json` + `install.sh`)

The Features path mirrors official Dev Containers (Dockerfile + `container build`) on **native arm64** — never `--rosetta` by default:

1. **One-time consent** (only if needed): when Apple BuildKit still has `build.rosetta=true` (or the key is missing), `up` / `clone` explains and asks once to set `build.rosetta=false` so feature image builds do not require Rosetta. Already `false` → silent. Decline → fail. Non-interactive: set `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` to auto-accept, or set the config yourself.
2. Loads local path packages from disk into the feature cache, or fetches OCI artifacts over HTTPS (embedded registry client — **not** `container image pull`, ORAS, or Node).
3. Orders installs via `dependsOn` / `installsAfter` (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`) and merges runtime contributions (`init`, `capAdd`, `containerEnv` with **config wins**, mounts, lifecycle hooks). On create, `${PATH}` / `$PATH` in env values are expanded (Apple `container` does not expand them).
4. Generates a Dockerfile and runs `container build --platform linux/arm64` to a deterministic `adev-{base}:{hash12}` tag (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix; reuse when the tag already exists).
5. Creates from the **derived image** with the same platform flag, then runs lifecycle hooks.

**Forever-reject:** any feature ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (OCI or local path); feature metadata with `privileged: true` or `securityOpt`.

**Hash note (v1):** local path identity uses the path string + options; editing files under the same path may not invalidate the derived tag until the path or options change.

### VS Code attach

After `up` or `clone`, the container is running and listable (`adevcontainer list`). Attach manually with experimental **Attach to Running Apple Container**. This CLI does not auto-attach.

### Non-goals (current)

- No Docker Compose driver
- No full Dev Containers extension / IDE attach parity
- No Node / `@devcontainers/cli` / ORAS dependency

### Architecture

```
devcontainer.json → Config resolver → [Features runner] → AppleContainerRuntime → container CLI
```

Only `AppleContainerRuntime` shells out to `container`.

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

Covers discovery, JSONC, substitution, admission, lifecycle, runArgs, hostRequirements, Features, runtime mocks, commands, and clone/volume-mode (plus optional real-container integration).

- Integration skips cleanly if Apple `container` is unavailable.
- Local features E2E runs when Apple `container` is up (no ghcr gate).
- Override image: `ADEVCONTAINER_TEST_IMAGE`.
- Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`.

### Fixtures

Pure JSON samples under [`Tests/Fixtures/`](Tests/Fixtures/), including smoke, env/user, mounts/ports, lifecycle hooks, runArgs/hostRequirements, OCI and local Features, and forever-reject cases (e.g. docker-ood). On-disk sample feature packages live under `Tests/Fixtures/features-sample/`.
