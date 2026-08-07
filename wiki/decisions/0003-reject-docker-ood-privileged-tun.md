# ADR 0003: Reject docker-ood, privileged, and tun device

## Context

Reference team config (`reference/devcontainer.json`) uses:

- Feature `ghcr.io/devcontainers/features/docker-outside-of-docker:1`
- `runArgs`: `--privileged`, `--cap-add=NET_ADMIN`, `--device=/dev/net/tun:/dev/net/tun`

Apple container is not Docker/Moby. Privileged mode, host device node passthrough, and docker-outside-of-docker assume a different runtime security and API model. Blind `runArgs` passthrough would either fail opaquely or create unsupported security expectations.

## Decision

**v1 policy (until explicit redesign):** hard-error — do not implement, emulate, or silently skip:

| Rejected | Rationale |
|----------|-----------|
| `docker-outside-of-docker` feature | Requires Docker socket/host Docker semantics unavailable as a supported path |
| `--privileged` | Not a supported Apple container posture for this CLI |
| `--device=/dev/net/tun` (and device node passthrough generally) | No supported device mapping path in v1 |
| Docker Compose | No Compose driver; multi-service files rejected |
| Blind `runArgs` passthrough | Only an explicit allowlist may be applied; unknown flags error |

Errors must be **structured and actionable** (which key/flag, why unsupported, what to remove/change).

## Consequences

- Reference config must be stripped/adapted for Apple-container workflows (remove ood feature + privileged/tun runArgs).
- VPN-in-container / DinD-style workflows are out of product scope for v1.
- `runArgs` handling lives behind allowlist logic in the runtime boundary ([cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md)).
- Revisit only via new ADR if Apple container gains safe, documented equivalents.
