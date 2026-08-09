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
- **Not** full product build/test: package still targets **macOS 26+**; the Linux image cannot replace the macOS host for the suite of record (integration tests need the Apple `container` CLI). Crypto is no longer the blocker: Sources now `import Crypto` (swift-crypto 4.5.1, `Crypto` product on ADevContainerLib — ContainerIdentity.swift:2, FeatureCache.swift:2, VSCodeCustomizationsApply.swift:1), which on Apple platforms re-exports CryptoKit, so macOS behavior is unchanged.
- Linux `swift build` is **green (0 errors / 0 warnings)** — the blockers listed earlier are closed (the only `#if canImport` guards left in Sources are AppleContainerConfig.swift:2,135 — Darwin, pre-existing and kept by design: they back the macOS-only Rosetta consent flow, and the edits elsewhere leave them untouched; `#if arch(arm64)` at ContainerPlatform.swift:9 is arch-, not platform-, conditional and unchanged). What closed them: `sysctlbyname` sysctl fallbacks deleted — `HostResourceInfo` reads `ProcessInfo` only (HostResourceInfo.swift:16,22); `_SYS_NAMELEN` → `MemoryLayout.size(ofValue:)` (ContainerPlatform.swift:34); `fputs`/`stderr` → `FileHandle.standardError.write` (StatusPrinter.swift:6, ManagedContainers.swift:73,120, CloneCommand.swift:143, UpCommand.swift:110, AppleContainerConfig.swift:170, AdevcontainerMain.swift:12); URLSession types compile via unconditional `import FoundationNetworking` (the module exists on Apple SDKs too, so nothing here is platform-gated) — OCIFeatureClient.swift:2, VSCodeCustomizationsApply.swift:3, ManagedContainers.swift:2, Tests/AllIntegrationTests.swift:2; CoreFoundation `CFGetTypeID`/`CFBooleanGetTypeID` checks removed — JSON booleans parse as Swift `Bool` on both platforms, the earlier `as? Bool` checks carry that semantics, and values that are still `NSNumber` are treated as numbers. Left as-is: the suite of record remains **macOS 26+**, and the integration suites that create the Apple `container` (`fixtureE2E_*`, `doctor`) still skip on Linux (10 skips — the `container` binary is absent), while the unit suites pass (335 passed / 0 failed).

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
