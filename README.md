# Apple Dev Container CLI (adevcontainer)

[![CI](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml/badge.svg)](https://github.com/wcgomes/apple-devcontainers/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-528%2B-brightgreen)](https://github.com/wcgomes/apple-devcontainers)
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
| `adevcontainer rebuild [--name <container>] [--vscode]` | Force-recreate a managed container from its current `devcontainer.json` — bind keeps the name, volume mode keeps the same workspace volume (data preserved) |
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

**Rebuild an existing container** — force-recreate from the container's current `devcontainer.json` (no re-clone). Old container is deleted only after config read, host requirements, and Features succeed; bind keeps the same container name, volume mode keeps the same workspace volume:

```bash
adevcontainer rebuild --name <name>   # or auto-single / interactive picker
adevcontainer rebuild --name <name> --vscode
adevcontainer rebuild --name <name> --json
```

There is **no** `up --recreate` (unknown flag). Config hash mismatch on `up` → `config_hash_mismatch`; remediate with `rebuild`.

**Rebuild recovery** (hard post-delete failures only — create/start/`onCreate`…`postStart`; not pre-delete, not settings/open/`postAttach` soft-fail):

| Mode | Edit target |
|------|-------------|
| Bind (`up`) | Host stamped `devcontainer.json` (no helper, no Alpine, no volume write) |
| Clone-origin volume | Alpine helper + secure temp + atomic write into `*-ws` |

- **TTY** (no `--json`): print structured error → `Open the recovery editor now? [Y/n]` (default **Y**). Decline/EOF retains recovery state and prints `rebuild --name` retry. Named `rebuild --name` retries skip the Y/n prompt.
- **Non-TTY / `--json`**: no prompt, no editor; structured retain + exact edit/retry/cleanup commands.

### Config and workspace behavior

Config: `.devcontainer/devcontainer.json`, else `.devcontainer.json`.

- **`up`** bind-mounts the host folder. **`clone`** uses volume `adev-*-ws` (no host checkout to edit).
- **`rebuild`** force-recreates from the current config: bind keeps the container name, volume mode reuses the same `adev-*-ws` workspace volume — data preserved, never re-cloned.
- Config hash mismatch → `up` errors with `config_hash_mismatch`; run `adevcontainer rebuild` (managed selection: `--name` or auto). No `--recreate`.
- **`delete`** = container only. **`prune`** = container + named volumes (including clone `*-ws`) + config image. Never deletes host bind paths. Ordinary `prune` skips marked recovery helpers.
- Progress on **stderr** (`==> …`). `ADEVCONTAINER_QUIET=1` silences progress only — policy warn-skips still emit. `--json` keeps stdout clean.

### Lifecycle hooks

Fresh create (`up`, `clone`, or `rebuild` after the tree exists / volume reused):

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

| Path | Hooks |
|------|--------|
| Fresh create (`up` / `clone` / `rebuild`) | full order; container deleted if any fail (`rebuild`: new container only; volumes preserved) |
| Reuse running | none |
| `up` start stopped | `postStartCommand` only |
| `start` (managed) | none |
| `postAttachCommand` | runs only after successful `--vscode` open on `up`/`start`/`clone`/`rebuild`; otherwise skipped (status when present); failure fails command, keeps container |

### runArgs allowlist

Mapped onto `container create` (empty/`[]` OK; `=VALUE` or two-token):

| Allowed | Notes |
|---------|--------|
| `--init`, `--cap-add`, `--cap-drop` | |
| `--shm-size`, `--dns`, `--dns-search`, `--dns-option`, `--dns-domain`, `--no-dns` | |
| `--ulimit`, `--tmpfs` | path before `:` if Docker opts present |
| `--cpus`/`-c`, `--memory`/`-m` | merge into create `-c`/`-m`; hostRequirements wins per dimension when set |
| `--network=NAME` | named only; Docker-only modes (`host`/`bridge`/`none`/`container:*`) warn-skip; empty name hard-error |
| `--rosetta`, `--ssh`, `--read-only` | |

**Warn-skip (ignored with stderr warning; see [ADR 0003](wiki/decisions/0003-warn-skip-apple-incompatibles.md)):**

| Family | Items |
|--------|--------|
| runArgs | `--privileged`, `--device…`, `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`, Docker-only `--network` modes (`host`/`bridge`/`none`/`container:*`) |
| Features | refs containing `docker-outside-of-docker` / `docker-in-docker` / `docker-from-docker` (dropped from admitted list) |
| Metadata | feature/image `privileged: true` / non-empty `securityOpt` (not applied; feature may still install — install.sh that *requires* them can still fail) |

When privileged/device are skipped and `cap-add NET_ADMIN` remains, one extra warning notes that caps alone do not provide device/privileged/VPN-in-container on Apple container.

**Hard-error:** Docker Compose keys, first-class flags smuggled via runArgs (`-e`/`-p`/`-v`/…), and any other non-allowlisted flag.

### hostRequirements

Preflight on **`up`**, **`clone`**, and **`rebuild`** parses `memory` (`8gb` / `8192mb`) and `cpus`:

- **Fail** the command on capacity shortfall or unreadable host (`rebuild`: before the old container is deleted)
- When host OK, pass requested limits to `container create` (`-m`/`-c`); absent → no limit flags
- **Warn** that `gpu` is unsupported (does not fail alone)
- **Fail** on unparseable values or unknown keys

### Features (OCI + local path)

Top-level `features` map (ref → options) on **`up` / `clone` / `rebuild`**. Builds a derived image on **native arm64**.

- **OCI** — e.g. `ghcr.io/devcontainers/features/node:1`
- **Local path** — `./…`, `../…`, absolute, or `file://…` (relative to **workspace root**; needs `devcontainer-feature.json` + `install.sh`)
- **Volume-mode `rebuild`** fetches OCI features only: the host fetcher (`DefaultFeatureFetcher`) and local-path feature refs inside the workspace volume are unsupported there and fail cleanly before the old container is deleted (bind-mode `rebuild` keeps `up` behavior)
- **Derived-tag reuse** on `rebuild`: unchanged base image + features material reuses `adev-{base}:{hash12}` (no `container build`)
- **Warn-skip:** docker-* feature refs and privileged/securityOpt metadata — see table above / [ADR 0003](wiki/decisions/0003-warn-skip-apple-incompatibles.md)
- **Rosetta / BuildKit:** if prompted once to set `build.rosetta=false`, accept — or set `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` for CI

### VS Code (`--vscode` + config customizations)

Prerequisites: VS Code with the [Remote - Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) installed (required for `--vscode`) and a discoverable `code` CLI.

Pass **`--vscode`** on `up`, `start`, `clone`, or `rebuild` to open a new VS Code window on the remote workspace folder.

- Runs config + feature **`postAttachCommand`** only after a successful open. Without `--vscode`, or if open soft-fails, postAttach is skipped.
- Soft-fail: missing VS Code/`code` → warn on stderr; container still succeeds.
- Manual attach: VS Code's experimental **Attach to Running Apple Container** command (separate path; `--vscode` does not need it).

**Config-file `customizations.vscode`:**

- **`settings`** — applied into the container on create-path (`up`/`clone`/`rebuild`); not gated on `--vscode`
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
