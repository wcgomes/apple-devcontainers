# Wiki index

## Architecture

- [Architecture](architecture.md) — architecture, lifecycle, identity — System structure, lifecycle behavior, and command routing.

## Decisions

- [Decisions](decisions/index.md) — decisions, ADRs, policy — Architectural decision records and their routing map.
- [Greenfield Swift CLI](decisions/0001-greenfield-swift-cli.md) — greenfield, Swift, runtime — Records the project’s greenfield runtime decision.
- [Apple incompatibles](decisions/0002-reject-docker-ood-privileged-tun.md) — Docker, privileges, rejection — Records the original incompatibility rejection policy.
- [Warn-skip incompatibles](decisions/0003-warn-skip-apple-incompatibles.md) — Docker, warnings, compatibility — Records the optional incompatibility warning policy.

## Domain

- [Apple devcontainer gaps](domain/devcontainer-apple-gaps.md) — Apple, identity, gaps — Documents compatibility gaps between Apple containers and devcontainers.

## Conventions

- [Terminal output](conventions/terminal-output.md) — terminal, output, formatting — Defines terminal output conventions and presentation behavior.
- [CLI runtime boundary](conventions/cli-runtime-boundary.md) — runtime, identity, Features — Defines runtime boundaries, identities, mounts, and Feature handling.
- [Release distribution](conventions/release-distribution.md) — release, distribution, Homebrew — Defines release, packaging, and distribution conventions.
- [Workspace devcontainer](conventions/workspace-devcontainer.md) — workspace, devcontainer, tooling — Documents the repository’s development container conventions.
