# ADR 0002: Reject docker-in-docker / ood, privileged, and tun device

## Context

Reference team config (`reference/devcontainer.json`) uses:

- Feature `ghcr.io/devcontainers/features/docker-outside-of-docker:1`
- `runArgs`: `--privileged`, `--cap-add=NET_ADMIN`, `--device=/dev/net/tun:/dev/net/tun`

Apple container is not Docker/Moby. Privileged mode, host device node passthrough, and docker-outside-of-docker / DinD-style features assume a different runtime security and API model. Blind `runArgs` passthrough would either fail opaquely or create unsupported security expectations.

## Decision

**Policy (until explicit redesign):** hard-error — do not implement, emulate, or silently skip:

| Rejected | Rationale |
|----------|-----------|
| Feature id substrings: `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` | Match anywhere in the feature ref (any registry/tag or local path). Require Docker socket / host Docker / DinD semantics unavailable as a supported path |
| `--privileged` | Not a supported Apple container posture for this CLI |
| `--device=…` (incl. `/dev/net/tun`) | No supported device mapping path |
| Docker Compose | No Compose driver; multi-service files rejected |
| Blind `runArgs` passthrough | Only an explicit allowlist may be applied; unknown flags error |

Errors must be **structured and actionable** (which key/flag/feature, why unsupported, what to remove/change).

Feature metadata `privileged: true` or `securityOpt` is also forever-rejected (same policy family).

## Consequences

- Reference config must be stripped/adapted for Apple-container workflows (remove docker-* features + privileged/tun runArgs).
- VPN-in-container / DinD-style workflows are out of product scope.
- `runArgs` handling lives behind allowlist logic in the runtime boundary ([cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md)).
- Revisit only via new ADR if Apple container gains safe, documented equivalents.
