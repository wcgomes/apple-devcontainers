# ADR 0002: Reject docker-in-docker / ood, privileged, and tun device

## Status

**Superseded in part** by [0003](0003-warn-skip-apple-incompatibles.md). Optional incompatibles (docker-* features, privileged/device/security runArgs, feature privileged/securityOpt metadata) are now **warn-skip**. Compose, unknown runArgs, and first-class smuggling remain fail-closed as below.

## Context

Reference team config (`reference/devcontainer.json`) uses:

- Feature `ghcr.io/devcontainers/features/docker-outside-of-docker:1`
- `runArgs`: `--privileged`, `--cap-add=NET_ADMIN`, `--device=/dev/net/tun:/dev/net/tun`

Apple container is not Docker/Moby. Privileged mode, host device node passthrough, and docker-outside-of-docker / DinD-style features assume a different runtime security and API model. Blind `runArgs` passthrough would either fail opaquely or create unsupported security expectations.

## Decision (original; see Status)

**Policy (original until 0003):** hard-error — do not implement, emulate, or silently skip:

| Rejected | Rationale |
|----------|-----------|
| Feature id substrings: `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` | Match anywhere in the feature ref (any registry/tag or local path). Require Docker socket / host Docker / DinD semantics unavailable as a supported path |
| `--privileged` | Not a supported Apple container posture for this CLI |
| `--device=…` (incl. `/dev/net/tun`) | No supported device mapping path |
| Docker Compose | No Compose driver; multi-service files rejected |
| Blind `runArgs` passthrough | Only an explicit allowlist may be applied; unknown flags error |

Errors must be **structured and actionable** (which key/flag/feature, why unsupported, what to remove/change).

Feature metadata `privileged: true` or `securityOpt` was also forever-rejected (same policy family).

**Current policy:** optional rows above → warn-skip per [0003](0003-warn-skip-apple-incompatibles.md). Compose + unknown/first-class runArgs remain hard-error.

## Consequences

- Reference config multi-platform noise (docker-* / privileged / tun) no longer blocks `up`; warnings explain skips
- VPN-in-container / DinD-style workflows remain out of product scope (not emulated)
- `runArgs` handling lives behind allowlist + warn-skip logic in the runtime boundary ([cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md))
- Revisit emulation only via new ADR if Apple container gains safe, documented equivalents
