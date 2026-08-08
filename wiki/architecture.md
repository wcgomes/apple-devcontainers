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
| GitHub repo | [wcgomes/apple-devcontainers](https://github.com/wcgomes/apple-devcontainers) (ex-`apple-dev-containers`, ex-`dev-containerization`) |
| Release / install | CI + GitHub Release tarball; Homebrew primary — [release-distribution.md](conventions/release-distribution.md) |

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

## Workspace modes

| Mode | Entry | Workspace storage | Host FS path |
|------|-------|-------------------|--------------|
| **Bind** | `up` from host workspace | Host dir via virtiofs (APFS) | Real path on Mac |
| **Volume** | `clone <git-url>` | Named volume via virtio-blk (`volume.img` ext4) | No durable host checkout; label `local_folder=volume://…` |

Volume mode exists for better metadata I/O (git status, node_modules, many small files) vs virtiofs binds. Contract: [`specs/adevcontainer/spec.md`](../specs/adevcontainer/spec.md) (archived change `20260808-clone-in-volume`).

## Commands (product surface)

| Command | Role |
|---------|------|
| `doctor` | Host/runtime readiness checks |
| `up` | **Bind-mode** only: resolve config from host workspace, create/start/reuse; ensure named volumes; workspace bind; Features; lifecycle hooks in scope |
| `clone <git-url>` | **Volume-mode** workspace (VS Code clone-in-volume analogue): host sparse/shallow **config-only** fetch → resolve (workspaceFolder default + `${localWorkspaceFolderBasename}` = **git URL repo basename**, not temp dir name) → **author identity before Features/create:** host `git -C <sparse-temp> config --get user.name/email` (includeIf-aware; env `ADEVCONTAINER_GIT_AUTHOR_*`); both env → skip prompt; TTY confirm/override or collect; non-TTY silent + warn if incomplete → **ensure Features `ghcr.io/devcontainers/features/git:1` when no `git`/`common-utils`** (Features path, not apt; `up` unchanged) → ensure workspace volume → create + start (**SSH:** inject `create --ssh` when `SSH_AUTH_SOCK` set) → **in-container full `git clone`** + verify `.git` (**HTTPS:** host `git credential fill` one-shot → guest `credential.helper store`; no GCM-in-guest; no host full+tar happy path) → author both → guest `--local`; else warn, no partial → create-path hooks; always clean config temps |
| `list [--json]` | Managed containers only (`devcontainer.managed=adevcontainer`) |
| `start [--name]` | Start a managed stopped container via `--name` or interactive picker; **volume-mode: no lifecycle hooks**; bind start-stopped `postStart` only via `up` path (not bare `start`) |
| `exec [--name]` | Run command/shell in running managed container (`-it` / empty cmd → interactive TTY, default `bash`). Selection: `--name` or picker (no `-w`). User/workdir from labels `devcontainer.remote_user` / `devcontainer.workspace_folder` when set |
| `stop [--name]` | Stop managed container (`--name` or picker; no `-w`) |
| `delete [--name]` | Remove **container only** (`--name` or picker; no `-w`) |
| `prune [--name]` | Remove container **and** config named volumes (label) **and** workspace `*-ws` volume **and** config image (`--name` or picker; not binds; not global prune) |
| `inspect [--name]` | Show resolved identity/state (`--name` or picker; no `-w`) |

**Selection:** only `up` takes `-w`/cwd (bind workspace). Lifecycle commands (`start`/`exec`/`stop`/`delete`/`prune`/`inspect`) resolve managed containers by `--name` or interactive picker — never `-w`.

**delete vs prune:** `delete` drops the workspace container only. `prune` also removes config `type=volume` mounts (by label), the clone workspace volume (`adev-*-ws`), and the config `image` reference. Neither deletes bind-mount host paths or runs global `volume`/`image` prune. Derived Features tags (`adev-{base}:{hash12}` / `adevcontainer:{hash12}`) are not removed by `prune` unless they equal the config `image` field.

**Progress:** long ops print `==> …` progress lines on stderr and tee Apple `container` stderr (pull/create/start/stop/delete/volume create; Features: Resolving/Fetching/Building/Reusing; build.rosetta config when changing). `ADEVCONTAINER_QUIET=1` silences progress status.

## Identity

- **Human base:** sanitize(`devcontainer.json` `name`) when non-empty after trim; else sanitize(workspace folder basename) — **volume-mode:** git URL repo basename (not a temp host path). DNS-safe (lowercase, non-`[a-z0-9-]` → `-`, trim hyphens, base ~20 chars).
- **Container name:** `adev-{base}-{hash12}`; empty base → `adev-{hash12}`; ≤63 chars. Apple `container create --name` is the container **id**.
  - **Bind-mode `hash12`:** workspace path + config path.
  - **Volume-mode `hash12`:** normalized git URL + config relpath (not a temp host path). Stable across reclones of the same repo/config.
- **Workspace volume (volume-mode):** `adev-{base}-{hash12}-ws`.
- **Features derived tag** (when Features build runs): `adev-{base}:{hash12}` (content hash of base image + features); empty base → `adevcontainer:{hash12}`. No `adevcontainer/features:` prefix. Plain config `image` (no Features) is unchanged.
- **Labels (managed set):** stamped on create for both modes — `devcontainer.managed=adevcontainer`, `devcontainer.local_folder` (bind: host path; volume: `volume://…`), `devcontainer.config_file`, app config hash, `devcontainer.workspace_mode` (`bind` on `up`, `volume` on `clone`), `devcontainer.workspace_folder`, `devcontainer.remote_user` (may be empty), `devcontainer.config_volumes` when applicable. Volume-mode also `devcontainer.git_url` (userinfo stripped), `devcontainer.workspace_volume`.
- Enables find/reuse without Docker-style label filter APIs (list has no label filter — client-side filter; `list` keeps only managed). See [gaps](domain/devcontainer-apple-gaps.md).

## Ports and lifecycle

- `forwardPorts` → publish ports on the Apple container (IDE auto-forward not guaranteed).
- `portsAttributes` stored/surfaced as metadata where useful.
- Lifecycle hooks run via `container exec` (not baked into image). Matrix:

  | Path | Hooks |
  |------|--------|
  | Fresh create (`up` bind or `clone` volume) | `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`; delete container if any create-path hook fails |
  | Reuse running | no lifecycle hooks |
  | Bind start-stopped (`up`) | `postStartCommand` only; failure fails `up` but does **not** delete |
  | Volume-mode `start` | **no hooks** |
  | `postAttachCommand` | admitted; **not** run on `up`/`clone`/`start` (status: skipped — no attach hook) |

- **runArgs allowlist** and **hostRequirements** enforce+apply: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md). Contract: [`specs/adevcontainer/spec.md`](../specs/adevcontainer/spec.md).
- Long-lived devcontainers use keep-alive entrypoint **`/bin/sleep` infinity** so the container stays up for `exec`/attach.

## Features

Shipped under `Sources/ADevContainerLib/Features/`. On `up`/`clone` when `features` is non-empty (after clone git-ensure):

1. Admit **OCI** and **local path** refs; forever-reject docker-* markers and metadata `privileged` / `securityOpt`.
2. One-time consent for `build.rosetta=false` when needed (CI: `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`).
3. Load local packages or fetch OCI over HTTPS (embedded client).
4. Order via `dependsOn` / `installsAfter`; build derived image via `container build --platform linux/arm64`; reuse tag when unchanged. If BuildKit was stopped before the build, restore-after-build stops it again (best-effort); already-running / undetermined status → leave alone.
5. Create from derived image; merge contributions (env **config wins**, `${PATH}` expansion on create and later exec).

**Clone-only:** if no admitted feature id is `git` or `common-utils`, inject `ghcr.io/devcontainers/features/git:1` (Features path, not apt) so populate can run **in-container full `git clone`** and in-container git works. `up` does not inject. Host git is required only for config-only sparse/shallow fetch and HTTPS `git credential fill`.

Full runner steps, reject list, and progress lines: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md).

## VS Code flow

1. CLI `up` brings the container up.
2. User attaches with experimental **Attach to Running Apple Container** (not full Dev Containers extension parity).

## Reference config

- **Workspace self-devcontainer:** `.devcontainer/devcontainer.json` — `swift:6.3.3-noble` plus OCI Features (`opencode`, `agents-workspace`) for Linux Swift tooling + product fixture; not full macOS product build/test. Detail: [workspace-devcontainer.md](conventions/workspace-devcontainer.md).
- **Team sample (reject surface):** `reference/devcontainer.json` — dotnet image, features (incl. docker-ood), privileged+tun `runArgs`, mounts, `postCreateCommand`, `forwardPorts`, VS Code customizations. Several props are explicitly rejected; see [0002](decisions/0002-reject-docker-ood-privileged-tun.md) and [gaps](domain/devcontainer-apple-gaps.md).


## Out of scope (product shape)

- Not a fork of https://github.com/devcontainers/cli
- No Docker Compose driver
- No docker-outside-of-docker / docker-in-docker / docker-from-docker / privileged / tun device (hard reject)
