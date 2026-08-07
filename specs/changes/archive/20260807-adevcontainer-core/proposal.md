# Proposal: MVP Phase 0–3 Apple-container devcontainer CLI

## Intent

macOS developers need a native CLI that reads `devcontainer.json` and runs workspaces on Apple’s `container` stack. Upstream `@devcontainers/cli` is Node/Docker-oriented and is not a fit. This change establishes the durable outcome contract and executable plan for a greenfield Swift CLI that ships Phases 0–3 only.

## Scope

- Greenfield Swift SPM executable **`adevcontainer`** at package root `/Users/wyller/Repos/dev-containerization/` (Package.swift, Sources/, Tests/).
- Host: macOS 26+ Apple Silicon; sole external user runtime dependency: Apple `container` (already on host; no install tasks).
- Product commands: `doctor`, `up`, `exec`, `stop`, `delete`, `prune`, `inspect`.
- Phases 0→3 feature surface (each assumes prior phases):
  - **0** — `image` + workspace bind + shell `exec`
  - **1** — `containerEnv`, `remoteUser`/`containerUser`, `workspaceFolder`, variable substitution subset
  - **2** — mounts (bind + volume; `up` reuses existing named volumes), `forwardPorts` → publish, `portsAttributes` as metadata only
  - **3** — `postCreateCommand` via exec; non-zero exit fails `up`
- Post-MVP polish in this change: `prune` (container + config named volumes + config image; not binds/global prune); named-volume reuse on `up` (list-first, never fail solely because volume exists).
- Config discovery, JSONC parse, deterministic identity/labels, structured unsupported-property errors, machine-readable `up` JSON result.
- Phase fixture configs under `Tests/Fixtures/` for tests and manual smoke.
- VS Code path: container running and listable after `up`; attach is manual/experimental (not full Dev Containers extension parity).

## Non-goals

- Fork or wrap of https://github.com/devcontainers/cli; no Node runtime for this product.
- Phases 4–6 (broader lifecycle set, features OCI runner, advanced parity).
- Docker Compose driver; multi-service Compose keys.
- `docker-outside-of-docker`, `--privileged`, device passthrough (`--device=…` including tun), blind `runArgs` passthrough.
- Implementing other features (including non-ood features) on the MVP path.
- Full VS Code Dev Containers extension driver parity or automatic attach.
- Network package installs in task execution (assume Swift/SPM and Apple `container` already present).
- Non-arm64 / non-macOS 26 hosts.

## Approach

Lite SDD: this proposal + delta `spec.md` + dependency-ordered `tasks.md`. Implementation is a Swift CLI with a Config resolver (JSONC, substitution, admission) and a single **AppleContainerRuntime** boundary (subprocess + machine JSON only). Phases land in order 0→3 with test-first units, mockable process runner, and optional real-container integration tests that skip when Apple `container` is unavailable. Forever-reject and unknown-dangerous properties hard-error with structured messages. `customizations.vscode` does not fail parse (ignore or metadata only).
