# Architecture

Greenfield native Swift executable (arm64). Reads `devcontainer.json`, drives Apple `container` CLI. No Node runtime for this product.

## Host and deps

| Item | Value |
|------|--------|
| Host | macOS 26+, Apple Silicon only |
| CLI language | Swift 6.x (SPM; full Xcode not required) |
| User runtime dep | Apple `container` CLI (install separately — [apple/container](https://github.com/apple/container); tested with 1.2.x JSON) |
| Apple container binary (typical) | `/usr/local/bin/container` |
| Product binary | `adevcontainer` |

## Package layout

| Path | Role |
|------|------|
| `Sources/ADevContainerLib` | Library: resolver, runtime, commands, Features, shared types |
| Thin executable target | CLI entry only; links the lib |
| `adevcontainerTests` | Executable product — **suite of record** (MiniTest) |

On CLT-only hosts, XCTest / `swift test` may report no tests. Run the suite with:

```bash
swift run adevcontainerTests
```

## Pipeline

```
devcontainer.json → Config resolver → [Features runner] → AppleContainerRuntime → /usr/local/bin/container
```

1. **Config resolver** — JSONC parse; variable substitution (`${localEnv:*}`, `${localWorkspaceFolderBasename}`); validate supported props; hard-error unsupported (never silent ignore).
2. **Features runner** (when `features` non-empty) — load local path and/or fetch OCI features; order; ensure `build.rosetta=false`; derived image build; swaps effective image before create. Detail: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md).
3. **AppleContainerRuntime** — sole boundary to the external `container` CLI; subprocess invoke; parse machine-readable JSON only. Features OCI fetch is separate (embedded HTTPS); local path is disk copy.
4. **Apple container** — create/run/exec/stop/delete/prune/inspect/build of the workspace container and related config volumes/image.

## Commands (product surface)

| Command | Role |
|---------|------|
| `doctor` | Host/runtime readiness checks |
| `up` | Resolve config, create/start/reuse container; ensure named volumes (reuse if present); workspace bind; Features derived image when needed; lifecycle hooks in scope |
| `exec` | Run command/shell in running container (`-it` / empty cmd → interactive TTY, default `bash`) |
| `stop` | Stop container |
| `delete` | Remove **container only** |
| `prune` | Remove container **and** named volumes from config **and** config image (not binds; not global prune) |
| `inspect` | Show resolved identity/state |

**delete vs prune:** `delete` drops the workspace container only. `prune` also removes config `type=volume` mounts and the config `image` reference. Neither deletes bind-mount host paths or runs global `volume`/`image` prune. Derived Features tags (`adevcontainer/features:*`) are not removed by `prune` unless they equal the config `image` field.

**Progress:** long ops print `==> …` progress lines on stderr and tee Apple `container` stderr (pull/create/start/stop/delete/volume create; Features: Resolving/Fetching/Building/Reusing; build.rosetta config when changing). `ADEVCONTAINER_QUIET=1` silences progress status.

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

- **runArgs allowlist** and **hostRequirements** enforce+apply: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md). Contract: [`specs/adevcontainer/spec.md`](../specs/adevcontainer/spec.md).
- Long-lived devcontainers use keep-alive entrypoint **`/bin/sleep` infinity** so the container stays up for `exec`/attach.

## Features

Shipped under `Sources/ADevContainerLib/Features/`. On `up` with a non-empty `features` map:

1. Admit **OCI** and **local path** refs; forever-reject docker-* markers and metadata `privileged` / `securityOpt`.
2. One-time consent for `build.rosetta=false` when needed (CI: `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`).
3. Load local packages or fetch OCI over HTTPS (embedded client).
4. Order via `dependsOn` / `installsAfter`; build derived image via `container build --platform linux/arm64`; reuse tag when unchanged.
5. Create from derived image; merge contributions (env **config wins**, `${PATH}` expansion).

Full runner steps, reject list, and progress lines: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md).

## VS Code flow

1. CLI `up` brings the container up.
2. User attaches with experimental **Attach to Running Apple Container** (not full Dev Containers extension parity).

## Reference config

Team sample: `reference/devcontainer.json` — dotnet image, features (incl. docker-ood), privileged+tun `runArgs`, mounts, `postCreateCommand`, `forwardPorts`, VS Code customizations. Several props are explicitly rejected; see [0002](decisions/0002-reject-docker-ood-privileged-tun.md) and [gaps](domain/devcontainer-apple-gaps.md).

## Out of scope (product shape)

- Not a fork of https://github.com/devcontainers/cli
- No Docker Compose driver
- No docker-outside-of-docker / docker-in-docker / docker-from-docker / privileged / tun device (hard reject)
