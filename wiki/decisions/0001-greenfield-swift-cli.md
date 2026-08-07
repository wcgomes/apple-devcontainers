# ADR 0001: Greenfield Swift CLI on Apple container

## Context

Need a macOS CLI that reads `devcontainer.json` and runs dev workspaces on Apple’s `container` stack. Upstream [@devcontainers/cli](https://github.com/devcontainers/cli) is Node-based and Docker/Moby-oriented. Target host: macOS 26+ arm64. **Prerequisites** (developers must install): Swift 6.x toolchain (Command Line Tools suffice) and Apple `container` CLI ([apple/container](https://github.com/apple/container); tested against 1.2.x machine JSON). `doctor` validates presence and system status.

## Decision

- **Greenfield** native Swift executable — do **not** fork or wrap `@devcontainers/cli`.
- **Sole external runtime dependency** for users: Apple `container` CLI. No Node runtime required to run our CLI.
- Target **Apple Silicon + macOS 26+** only for v1.
- Talk to Apple container only through a dedicated runtime boundary (subprocess + machine JSON).

## Consequences

- Full control of supported `devcontainer.json` surface and error policy; no Node/Docker assumptions inherited from upstream.
- Must reimplement config resolve, identity, lifecycle, and command UX (cost accepted).
- Feature parity with upstream CLI is intentional and phased — see [0002](0002-mvp-phase-3-scope.md).
- Portability beyond Apple container / non-arm64 macOS is out of scope until a later redesign.
- VS Code integration path is CLI `up` + attach-to-running-container, not full upstream extension driver parity.
