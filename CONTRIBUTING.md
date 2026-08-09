# Contributing

## AI agents
Contributing with AI agents? Use [agents-workspace](https://github.com/wcgomes/agents-workspace), the Feature already declared in `.devcontainer/devcontainer.json`. Its wiki-maintenance and spec-builder skills keep docs and specs consistent: spec-driven changes land in `specs/`, realized knowledge in `wiki/`.

## Prerequisites
- macOS 26+ Apple Silicon; Apple `container` installed separately ([README.md#install](README.md#install))
- Swift 6.x toolchain
- Integration tests expect `container` status `running` (typically `/usr/local/bin/container`; tested **1.2.x**)

## Build
```bash
swift build            # binary: .build/debug/adevcontainer
swift build -c release # binary: .build/release/adevcontainer
```

## Tests
Plain `swift test` may report “no tests found” on Command Line Tools hosts, which lack `XCTest.framework`; the suite of record is `swift run adevcontainerTests`.

- Integration skips cleanly if Apple `container` is unavailable
- Override image: `ADEVCONTAINER_TEST_IMAGE`
- Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`
- Fixtures: JSON samples under [`Tests/Fixtures/`](Tests/Fixtures/); on-disk sample feature packages under `Tests/Fixtures/features-sample/`

## Optional: working in the repo's devcontainer
Optional — the repo's devcontainer is just a reference example of the tooling used to develop this project; you can set up the same tools directly on your macOS instead.

Clone the repo directly on the Mac and run `adevcontainer up --vscode` to develop inside the repo's devcontainer: Linux Swift toolchain (`swift:6.3.3-noble`), opencode, agents-workspace, and VS Code customizations. VS Code development tooling runs in the devcontainer, while the project stays directly openable on macOS to test against Apple `container`.

- **Not possible inside the devcontainer:** it is Linux and has no Apple `container` binary, so the lifecycle commands (`up`/`start`/`exec`/`clone`) cannot run inside it — it cannot drive or test the actual product runtime; macOS-only behaviors (host git credential fill, SSH agent, `hostRequirements`, release pipeline) cannot be exercised there.
