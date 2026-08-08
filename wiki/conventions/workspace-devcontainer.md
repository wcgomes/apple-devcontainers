# Workspace self-devcontainer

This repo ships `.devcontainer/devcontainer.json` for **Linux Swift tooling** and as a real config fixture for `adevcontainer` itself. It is not a full product build/test environment.

## Config shape

| Item | Value |
|------|--------|
| Path | `.devcontainer/devcontainer.json` |
| Image | `swift:6.3.3-noble` (official Docker Hub Swift; no Dockerfile/Compose) |
| Features | OCI (see below) — not docker-* forever-rejects |
| `postCreateCommand` | `bash .devcontainer/install-tools.sh && swift package resolve` |
| Keep-alive | product default (`/bin/sleep infinity`) — not overridden in config |
| `runArgs` | omitted (none) |
| `hostRequirements` | `cpus: 4`, `memory: "8gb"` — minimum floor; comfortable optional ~6–8 CPUs / 12–16gb |
| Customizations | `customizations.vscode.extensions`: `swiftlang.swift-vscode`; `settings`: `editor.tabSize: 3`, `files.insertFinalNewline: true`. CLI applies settings on create-path and extensions after successful `--vscode` open (Apple attach does not auto-install). Hard dep `llvm-vs-code-extensions.lldb-dap` comes via Swift’s `extensionDependencies` (BFS auto-install) — not necessarily listed in config. See [architecture.md — VS Code flow](../architecture.md#vs-code-flow) |

### Features

| Feature ID | Options |
|------------|---------|
| `ghcr.io/devcontainers/features/node:1` | `{ version: "lts" }` |
| `ghcr.io/wcgomes/devcontainer-features/opencode:0` | `{}` |
| `ghcr.io/wcgomes/devcontainer-features/agents-workspace:0` | `{ divisions: "engineering,testing,security" }` |

- **node:1 (lts)** — required for npm/global tools (codegraph). Opencode/agents-workspace Features do **not** provide Node.
- Opencode + agents-workspace unchanged from prior fixture.

These are supported OCI Features (product Features runner). They are not `docker-outside-of-docker` / `docker-in-docker` / `docker-from-docker` forever-rejects.

### postCreate / install-tools.sh

`postCreateCommand` runs `.devcontainer/install-tools.sh`, then `swift package resolve`.

`install-tools.sh`:

- Installs **codegraph** via npm global
- Agent wiring + init if needed

### VS Code settings and deps (fixture)

- Fixture settings are editor hygiene only (`editor.tabSize`, `files.insertFinalNewline`) — not Swift path overrides (`swift.path` defaults to PATH; image has `/usr/bin/swift`).
- `lldb-dap` is **not** listed in config; CLI installs it transitively from Swift’s `package.json` `extensionDependencies` when extensions apply runs. Do not confuse with CodeLLDB `lldb.library` settings.

## Intended use

- Edit sources, run `swift package resolve`, exercise Linux Swift toolchain paths.
- Validate `adevcontainer` against a real in-repo `devcontainer.json` (including OCI Features path).
- **Not** full product build/test: Package targets **macOS 26+ / CryptoKit**; Linux image cannot replace the macOS host for the suite of record.

## Security / admit surface (by design)

- No `runArgs` (no `SYS_PTRACE` or other caps).
- No `privileged`, DinD, devices, or `security-opt`.
- OCI Features only as listed — no docker-* Features.

## Research notes (what we did not copy)

| Option | Why not |
|--------|---------|
| Apple `container-machine-vscode` example | systemd/SSH / `container machine` Remote-SSH path — not standard `devcontainer.json` + `adevcontainer up` flow |
| `mcr.microsoft.com/devcontainers/swift` | Removed from devcontainers/images |
| Swift Server template seccomp unconfined | Product rejects that security posture |

## Related

- Product sample (includes intentionally rejected props): `reference/devcontainer.json` — see [architecture.md](../architecture.md) and [0002](../decisions/0002-reject-docker-ood-privileged-tun.md).
- Features runner: [cli-runtime-boundary.md](cli-runtime-boundary.md).
- Keep-alive and lifecycle: [devcontainer-apple-gaps.md](../domain/devcontainer-apple-gaps.md), [architecture.md](../architecture.md).
