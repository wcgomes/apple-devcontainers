# Contributing

## Contributing with AI agents

If you are contributing with AI agents, ideally use [agents-workspace](https://github.com/wcgomes/agents-workspace), the devcontainer Feature already declared in this repo's `.devcontainer/devcontainer.json`. It can help with the workflow, but its main value is the wiki-maintenance and spec-builder skills that keep this repo's docs and specs consistent with the repo's standards: spec-driven changes land in `specs/`, realized knowledge in `wiki/`.

## Prerequisites

- [Install requirements](README.md#install) (macOS 26+ Apple Silicon, Apple `container`)
- Swift 6.x toolchain
- Integration tests expect `container` system status `running` (typical path `/usr/local/bin/container`; tested **1.2.x**)

## Build from source

```bash
swift build
# binary: .build/debug/adevcontainer

swift build -c release
# binary: .build/release/adevcontainer
```

## Tests

Command Line Tools hosts do not ship `XCTest.framework`, so the suite of record is the Foundation MiniTest executable `adevcontainerTests` (plain `swift test` may report “no tests found” without full Xcode):

```bash
swift run adevcontainerTests
```

Covers discovery, JSONC, substitution, admission, lifecycle, runArgs, hostRequirements, Features, runtime mocks, commands, and clone/volume-mode (plus optional real-container integration).

- Integration skips cleanly if Apple `container` is unavailable.
- Local features E2E runs when Apple `container` is up (no ghcr gate).
- Override image: `ADEVCONTAINER_TEST_IMAGE`.
- Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`.

## Fixtures

Pure JSON samples under [`Tests/Fixtures/`](Tests/Fixtures/), including smoke, env/user, mounts/ports, lifecycle hooks, runArgs/hostRequirements, OCI and local Features, and forever-reject cases (e.g. docker-ood). On-disk sample feature packages live under `Tests/Fixtures/features-sample/`.

## Working in the repo's devcontainer

You can also develop this repository from inside its own devcontainer: run `adevcontainer up --vscode` from the repo root on your Mac (or the `start` / `clone` equivalents) and you get the repo's Linux Swift toolchain (`swift:6.3.3-noble`), the opencode and agents-workspace features, Node for the `codegraph` CLI install, and VS Code with the `swiftlang.swift-vscode` extension and settings applied. Editing the repo's own `.devcontainer/devcontainer.json` is ordinary config iteration — container name, config hash, and labels derive from the resolved config, so your changes apply the next time `up` recreates the container (`--recreate` when the config hash changed).

- **Container lifecycle commands need the macOS host.** This product runs only on macOS 26+ (Apple Silicon) and drives the Apple `container` runtime installed separately; the devcontainer has no `container` binary, so `adevcontainer up` / `start` / `exec` / `clone` / … cannot be executed from inside the container.
- **Linux toolchain, macOS suite of record.** The project builds on Linux (cross-platform builds enabled in recent commits) and the portable unit suites pass there under `swift run adevcontainerTests`, while the runtime-backed integration suites require the macOS host; CI runs on `macos-26` only.
- **macOS-only behaviors cannot be exercised here:** macOS-side git credential flows (host credential fill / keychain), SSH agent detection via the host `SSH_AUTH_SOCK`, real CPU/memory `hostRequirements` checks, Rosetta / architecture consent flows, and the release pipeline (Homebrew formula rendering, GitHub Actions on macOS runners, notarization).
- **Keep-alive.** The workspace container stays alive via an injected `/bin/sleep infinity`; do not set `overrideCommand` in this devcontainer.
- **VS Code attach.** Use `code --folder-uri vscode-remote://apple-container+...`; the Apple attach does not auto-install customizations — the CLI applies extensions (including local debugging via lldb-dap) and settings. The `settings` in the config are VS Code defaults kept for testing that customizations apply.
