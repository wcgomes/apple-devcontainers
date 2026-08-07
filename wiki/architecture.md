# Architecture

Greenfield native Swift executable (arm64). Reads `devcontainer.json`, drives Apple `container` CLI. No Node runtime for this product.

## Host and deps

| Item | Value |
|------|--------|
| Host | macOS 26+, Apple Silicon only |
| CLI language | Swift 6.x (SPM; full Xcode not required) |
| User runtime dep | Apple `container` CLI (prerequisite; install separately — [apple/container](https://github.com/apple/container); tested with 1.2.x JSON) |
| Apple container binary (typical) | `/usr/local/bin/container` |
| Product binary | `adevcontainer` |

## Package layout

| Path | Role |
|------|------|
| `Sources/ADevContainerLib` | Library: resolver, runtime, commands, shared types |
| Thin executable target | CLI entry only; links the lib |
| `adevcontainerTests` | Executable product — **suite of record** (MiniTest) |

On CLT-only hosts, XCTest / `swift test` may report no tests. Run the suite with:

```bash
swift run adevcontainerTests
```

## Pipeline

```
devcontainer.json → Config resolver → AppleContainerRuntime → /usr/local/bin/container
```

1. **Config resolver** — JSONC parse; variable substitution (`${localEnv:*}`, `${localWorkspaceFolderBasename}`); validate supported props; hard-error unsupported (never silent ignore).
2. **AppleContainerRuntime** — sole boundary to the external CLI; subprocess invoke; parse machine-readable JSON only. See [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md).
3. **Apple container** — create/run/exec/stop/delete/prune/inspect of the workspace container and related config volumes/image.

## Commands (product surface)

| Command | Role |
|---------|------|
| `doctor` | Host/runtime readiness checks |
| `up` | Resolve config, create/start/reuse container; ensure named volumes (reuse if present); workspace bind; lifecycle hooks in scope |
| `exec` | Run command/shell in running container (`-it` / empty cmd → interactive TTY, default `bash`) |
| `stop` | Stop container |
| `delete` | Remove **container only** |
| `prune` | Remove container **and** named volumes from config **and** config image (not binds; not global prune) |
| `inspect` | Show resolved identity/state |

**delete vs prune:** `delete` drops the workspace container only. `prune` also removes config `type=volume` mounts and the config `image` reference. Neither deletes bind-mount host paths or runs global `volume`/`image` prune.

**Progress:** long ops print `==> …` progress lines on stderr and tee Apple `container` stderr (pull/create/start/stop/delete/volume create). `ADEVCONTAINER_QUIET=1` silences progress status.

## Identity

- Deterministic container name derived from workspace + config; Apple `container create --name` is the container **id**.
- Labels: `devcontainer.local_folder`, `devcontainer.config_file`, app config hash.
- Enables find/reuse without Docker-style label filter APIs (list has no label filter — client-side filter). See [gaps](domain/devcontainer-apple-gaps.md).

## Ports and lifecycle

- `forwardPorts` → publish ports on the Apple container (IDE auto-forward not guaranteed).
- `portsAttributes` stored/surfaced as metadata where useful.
- Lifecycle hooks run via `container exec` (not baked into image). Matrix:

  | `up` path | Hooks |
  |-----------|--------|
  | Fresh create | `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`; delete container if any create-path hook fails |
  | Reuse running | no lifecycle hooks |
  | Start stopped | `postStartCommand` only; failure fails `up` but does **not** delete |
  | `postAttachCommand` | admitted; **not** run on `up` (status: skipped — no attach hook) |

- **runArgs allowlist** and **hostRequirements** enforce+apply: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md). Ladder: [phase-ladder.md](domain/phase-ladder.md).
- Long-lived devcontainers use keep-alive entrypoint (`sleep … infinity` pattern) so the container stays up for `exec`/attach.

## Features

Features (OCI fetch + derived image build) are **next** (see [phase-ladder.md](domain/phase-ladder.md)) — not in current surface; runner-owned; never docker-ood.

## VS Code flow

1. CLI `up` brings the container up.
2. User attaches with experimental **Attach to Running Apple Container** (not full Dev Containers extension parity).

## Reference config

Team sample: `reference/devcontainer.json` — dotnet image, features (incl. docker-ood), privileged+tun `runArgs`, mounts, `postCreateCommand`, `forwardPorts`, VS Code customizations. Several props are explicitly rejected in v1 policy; see [0003](decisions/0003-reject-docker-ood-privileged-tun.md) and [gaps](domain/devcontainer-apple-gaps.md).

## Out of scope (product shape)

- Not a fork of https://github.com/devcontainers/cli
- No Docker Compose driver
- No docker-outside-of-docker / privileged / tun device (hard reject)
