# Contributing

## AI agents
Contributing with AI agents? Use [agents-workspace](https://github.com/wcgomes/agents-workspace), the Feature already declared in `.devcontainer/devcontainer.json`. Its wiki-maintenance and spec-builder skills keep docs and specs consistent: spec-driven changes land in `specs/`, realized knowledge in `wiki/`.

## Prerequisites
- macOS 26+ Apple Silicon; Apple `container` installed separately ([README.md#install](README.md#install))
- Swift 6.x toolchain
- Integration tests expect `container` status `running` (typically `/usr/local/bin/container`; tested **1.2.x**)

## Build
```bash
sh scripts/build-guest-credential-relay.sh # authenticated toolchain + both embedded guest targets
swift build            # binary: .build/debug/adevcontainer
swift build -c release # binary: .build/release/adevcontainer
```

To install from source onto PATH and link the Apple CLI plugin:

```bash
sh scripts/build-guest-credential-relay.sh
swift build -c release
cp .build/release/adevcontainer /usr/local/bin/   # or another directory on PATH
adevcontainer plugin --install                    # use sudo when the plugin destination requires elevation
```

## Tests
Safe, synthetic credential checks (no user broker/provider/container):

```sh
sh scripts/test-guest-credential-relay.sh
sh Tests/GuestGitCredentialRelay/build_artifacts_tests.sh
swift build --product adevcontainer # internal-entry subprocess tests use this binary
ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests
ADEVCONTAINER_DETACHED_BROKER_TEST=1 ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests
```

The last command adds the isolated detached-broker probe: private context,
test-owned executable copies, synthetic provider, CLI-exit survival, single-owner
concurrency, idle exit, crash containment, and upgrade replacement. It never runs
`launchctl`, creates a plist, or touches production state.

Native tests have recorded behavioral red/green for absent transport, stdout
backpressure and tampered extracted toolchains. Artifact tests compare independent
output/cache rebuilds, ELF architecture/bounds/no-loader/no-dynamic metadata,
manifest/payload hashes and protocol identity. Generated Swift payloads under
`Sources/ADevContainerLib/Git/Generated/` must not be edited or committed. Details:
[`Tests/GuestGitCredentialRelay/README.md`](Tests/GuestGitCredentialRelay/README.md).
Linux CI uses the pinned compiler/raw-only mode and actually executes the shipped
amd64 ELF; macOS-native parser tests do not prove Linux target execution. The
isolated detached-broker probe runs from test-owned executable copies under the
temporary root and requires no authorization; arm64 guest smoke requires separately
authorized exclusively-created resources.

Do not run the full suite against an installed/running runtime without explicit
authorization for its integration side effects. Never stop an existing runtime
or user container merely to force integration skips. No real authentication or
host credential erase/reject is part of the synthetic checks.

Plain `swift test` may report “no tests found” on Command Line Tools hosts, which lack `XCTest.framework`; the suite of record is `swift run adevcontainerTests`. On a TTY, clone tests can prompt for git identity; `swift run adevcontainerTests < /dev/null` runs the suite without prompts.

- Integration skips cleanly if Apple `container` is unavailable
- Override image: `ADEVCONTAINER_TEST_IMAGE`
- Optional live OCI Features E2E: `ADEVCONTAINER_FEATURES_E2E=1`
- Fixtures: JSON samples under [`Tests/Fixtures/`](Tests/Fixtures/); on-disk sample feature packages under `Tests/Fixtures/features-sample/`

## Optional: working in the repo's devcontainer
Optional — the repo's devcontainer is just a reference example of the tooling used to develop this project; you can set up the same tools directly on your macOS instead.

Clone the repo directly on the Mac and run `adevcontainer up --vscode` to develop inside the repo's devcontainer: Linux Swift toolchain (`swift:6.3.3-noble`), opencode, agents-workspace, and VS Code customizations. VS Code development tooling runs in the devcontainer, while the project stays directly openable on macOS to test against Apple `container`.

- **Not possible inside the devcontainer:** it is Linux and has no Apple `container` binary, so the lifecycle commands (`up`/`start`/`exec`/`clone`) cannot run inside it — it cannot drive or test the actual product runtime; macOS-only behaviors (host git credential fill, SSH agent, `hostRequirements`, release pipeline) cannot be exercised there.
