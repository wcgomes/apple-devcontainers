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

## Install

**Requirements:** macOS 26+ on Apple Silicon. Install Apple [`container`](https://github.com/apple/container) separately (not bundled). Swift is only needed if you build from source.

### Homebrew

```bash
brew tap wcgomes/tap
brew install adevcontainer
```

`brew tap wcgomes/tap` uses `github.com/wcgomes/homebrew-tap` (standard Homebrew naming). Formula template: [`packaging/homebrew/`](packaging/homebrew/).

### GitHub Release binary

Download the arm64 tarball from [Releases](https://github.com/wcgomes/apple-dev-containers/releases). Example for `v0.1.0` — replace the version as needed:

```bash
curl -fsSL -o adevcontainer-macos-arm64.tar.gz \
  https://github.com/wcgomes/apple-dev-containers/releases/download/v0.1.0/adevcontainer-macos-arm64.tar.gz
curl -fsSL -o adevcontainer-macos-arm64.tar.gz.sha256 \
  https://github.com/wcgomes/apple-dev-containers/releases/download/v0.1.0/adevcontainer-macos-arm64.tar.gz.sha256
shasum -a 256 -c adevcontainer-macos-arm64.tar.gz.sha256
tar xzf adevcontainer-macos-arm64.tar.gz
sudo mv adevcontainer /usr/local/bin/   # or ~/bin if that directory is on PATH
```

### From source

See [Build](#build). After a release build, install the binary somewhere on `PATH` (for example `cp .build/release/adevcontainer /usr/local/bin/`).

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
- `features-node.json` — OCI Features runner (Node feature only; no docker-ood)
- `features-triple.json` — multi-feature install (node + git + github-cli)
- `features-local.json` — local path features (`./.devcontainer/features/sample-a` + `sample-b`)
- `features-docker-ood.json` — forever-reject fixture (`docker-outside-of-docker`)
- `features-sample/` — on-disk sample feature packages for unit + local E2E

### Features (OCI + local path)

`up` admits a top-level `features` object map of **feature ref → options**. Refs may be:

- **OCI** — e.g. `ghcr.io/devcontainers/features/node:1`
- **Local path** — `./…`, `../…`, absolute `/…`, or `file://…` (resolved relative to the **workspace root**; directory must contain `devcontainer-feature.json` + `install.sh`)

The Features path mirrors official Dev Containers (Dockerfile + `container build`) on **native arm64** — never `--rosetta` by default:

1. **One-time consent** (only if needed): when Apple BuildKit still has `build.rosetta=true` (or the key is missing), `up` explains and asks once to set `build.rosetta=false` in the host Apple container config so feature image builds do not require Rosetta. Already `false` → silent. Decline → fail. Non-interactive: set `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` to auto-accept, or set the config yourself.
2. Loads local path packages from disk into the feature cache, or fetches OCI artifacts over HTTPS (embedded registry client — **not** `container image pull`, ORAS, or Node)
3. Orders installs via `dependsOn` / `installsAfter` (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`) and merges runtime contributions (`init`, `capAdd`, `containerEnv` with **config wins**, mounts, lifecycle hooks). On create, `${PATH}` / `$PATH` in env values are expanded (Apple `container` does not expand them).
4. Generates a Dockerfile and runs `container build --platform linux/arm64` (on Apple Silicon) to a deterministic `adev-{base}:{hash12}` tag (empty base → `adevcontainer:{hash12}`; no `adevcontainer/features:` prefix; reuse when the tag already exists)
5. Creates from the **derived image** with the same platform flag, then runs lifecycle hooks

**Forever-reject:** any feature ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (OCI or local path); feature metadata with `privileged: true` or `securityOpt`.

**Hash note (v1):** local path identity uses the path string + options; editing files under the same path may not invalidate the derived tag until the path or options change.

## VS Code attach

After `up`, the container is running and listable. Attach manually with experimental **Attach to Running Apple Container**. This CLI does **not** implement full Dev Containers extension parity or auto-attach. `postAttachCommand` is admitted but not executed on `up`.

## Non-goals (current)

- No Docker Compose driver
- No `docker-outside-of-docker` (forever-reject)
- No `--privileged` or `--device` (including tun); feature privileged/securityOpt forever-reject
- No blind `runArgs` passthrough (runArgs allowlist only)
- No full `postAttachCommand` execution / IDE attach hook
- No Node / `@devcontainers/cli` / ORAS dependency for Features fetch

## Tests

Command Line Tools hosts do not ship `XCTest.framework`, so the suite of record is the Foundation MiniTest executable `adevcontainerTests` (plain `swift test` reports “no tests found” without full Xcode):

```bash
swift run adevcontainerTests
```

~156+ offline via `swift run adevcontainerTests` (discovery, JSONC, substitution, admission, lifecycle, runArgs, hostRequirements, Features runner mocks + local path fixtures, runtime argv mocks, commands, optional real-container integration). Integration skips cleanly if Apple `container` is unavailable. Local features E2E runs when Apple `container` is up (no ghcr gate). Override image with `ADEVCONTAINER_TEST_IMAGE`. Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`.

## Architecture

```
devcontainer.json → Config resolver → [Features runner] → AppleContainerRuntime → container CLI
```

Only `AppleContainerRuntime` invokes `container`. Features: OCI fetch is embedded HTTPS; local path via DefaultFeatureFetcher (no ORAS/Node). Labels: `devcontainer.local_folder`, `devcontainer.config_file`, `devcontainer.config_hash`.
