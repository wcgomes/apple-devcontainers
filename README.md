# Apple Dev Container CLI (adevcontainer)

[![CI](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml/badge.svg)](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-345%2B-brightgreen)](https://github.com/wcgomes/apple-devcontainers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Native Swift CLI that reads `devcontainer.json` and runs dev containers on **Apple `container`**.

Start a dev container with `up` on an existing local folder, or `clone <git-url>` for a named volume with faster I/O. Use the terminal or AI agents as-is, or pass `--vscode` to open VS Code with extensions and settings applied. Lifecycle hooks and Features included.

## Context

A dev container is a full-featured development environment isolated in a container — the tools, runtimes, and libraries your codebase needs, all reproducible. Use it to run an application, separate toolchains, or drive CI builds. `adevcontainer` brings that workflow to Apple `container` on macOS.

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

See [CONTRIBUTING.md](CONTRIBUTING.md). After a release build: `cp .build/release/adevcontainer /usr/local/bin/`.

After install:

```bash
adevcontainer doctor
```

## Features

### Commands

| Command | Purpose |
|---------|---------|
| `adevcontainer doctor` | Check Apple `container` readiness |
| `adevcontainer up [-w path] [--vscode]` | Create/start a dev container from a **host** folder (only command that uses `-w`; default cwd) |
| `adevcontainer clone <git-url> [--vscode]` | Clone a git repo into a **named volume** and start the dev container (HTTPS or SSH) |
| `adevcontainer list [--json]` | List managed dev containers |
| `adevcontainer start [--vscode] \| stop \| delete \| prune \| inspect [--name]` | Lifecycle by dev container name (or interactive picker) |
| `adevcontainer exec [-it] [--name] [--] [cmd…]` | Shell or command in a running managed dev container |

### Quick start

**Local checkout** (`up`) — uses the current directory by default; pass `-w <path>` for another folder:

```bash
adevcontainer up --vscode
adevcontainer exec -it
adevcontainer stop
```

**Clone a repository** (no local checkout required — source lives in a volume for better I/O on Apple `container`):

```bash
adevcontainer clone https://github.com/org/repo.git --vscode   # or git@github.com:org/repo.git
adevcontainer list
adevcontainer exec --name <name> -it
adevcontainer prune --name <name>
```

`--vscode` opens VS Code on the remote workspace and runs `postAttachCommand`. Omit it if you only need the container (manual attach or `exec`).

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
| `postAttachCommand` | runs only after successful `--vscode` open; otherwise skipped (status when present); failure fails command, keeps container |

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

Top-level `features` map (ref → options) on **`up` / `clone`**. Builds a derived image on **native arm64**.

- **OCI** — e.g. `ghcr.io/devcontainers/features/node:1`
- **Local path** — `./…`, `../…`, absolute, or `file://…` (relative to **workspace root**; needs `devcontainer-feature.json` + `install.sh`)
- **Forever-reject:** refs containing `docker-in-docker` / `docker-outside-of-docker` / `docker-from-docker`, or feature metadata with `privileged` / `securityOpt`
- **Rosetta / BuildKit:** if prompted once to set `build.rosetta=false`, accept — or set `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` for CI

### VS Code (`--vscode` + config customizations)

Recommended: pass **`--vscode`** on `up`, `start`, or `clone` to open a new VS Code window on the remote workspace folder.

- Runs config + feature **`postAttachCommand`** only after a successful open. Without `--vscode`, or if open soft-fails, postAttach is skipped.
- Soft-fail: missing VS Code/`code` → warn on stderr; container still succeeds.
- Prereqs: VS Code + Remote - Containers + `dev.containers.experimentalAppleContainerSupport: true` (and a discoverable `code` CLI).
- Manual attach (experimental **Attach to Running Apple Container**) works without the flag.
- Not full Dev Containers extension parity — convenience open only.

**Config-file `customizations.vscode`:**

- **`settings`** — applied into the container on create (`up`/`clone`); not gated on `--vscode`
- **`extensions`** — installed only after a successful `--vscode` open; dependency extensions installed automatically. Without `--vscode`, the CLI does not auto-install extensions
- Apply failures warn on stderr but do not fail the command
- After first extension install you may need **Developer: Reload Window** once

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites, building from source, running tests, fixtures, and working inside the repo's devcontainer.
