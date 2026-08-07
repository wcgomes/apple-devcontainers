# ADR 0002: MVP cut at Phase 3

## Context

Full devcontainers feature set (features-as-OCI, Compose, broad `runArgs`, Docker-parity networking) does not map cleanly onto Apple container today. Shipping everything delays a usable path: image + workspace + env + mounts/ports + postCreate.

## Decision

- Adopt phased ladder **0–6** (detail: [phase-ladder.md](../domain/phase-ladder.md)).
- **MVP ships Phases 0→3 only.**
- Later phases (features runner, richer lifecycle, advanced parity) are explicitly post-MVP.
- Unsupported properties **hard-error** (never silent ignore), including forever-reject items in [0003](0003-reject-docker-ood-privileged-tun.md).

### MVP support matrix

| Phase | Supported |
|-------|-----------|
| 0 | `image` + workspace bind + shell `exec` |
| 1 | `containerEnv`, `user`, `workspaceFolder` |
| 2 | mounts (bind + volume), `forwardPorts` publish, `portsAttributes` metadata |
| 3 | `postCreateCommand` (+ clear path to other lifecycle hooks) |

## Consequences

- Reference `devcontainer.json` will not run as-is until rejected props are removed or later phases land.
- Agents and docs must treat Phases 4–6 as non-goals for MVP PRs.
- Lifecycle beyond `postCreateCommand` may be stubbed or gated until the post-MVP path is implemented; Phase 3 establishes the exec-based pattern.
- Scope creep into features/Compose/docker-ood is a product violation, not a stretch goal.
- **Refinement (post-MVP):** Phase 4 scope was refined to broader lifecycle (first-class) **+** `runArgs` allowlist **+** `hostRequirements` preflight — see [phase-ladder.md](../domain/phase-ladder.md).
