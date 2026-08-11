# ADR 0003: Warn-skip Apple-incompatible optional bits

## Status

Accepted. Partially supersedes [0002](0002-reject-docker-ood-privileged-tun.md) for optional incompatibles.

## Context

Multi-platform `devcontainer.json` files often include Docker-oriented features and runArgs (`docker-outside-of-docker`, `--privileged`, `--device`, Docker-only network modes) alongside portable settings. Hard-rejecting the whole config blocked `up` on Apple container even when the remaining surface was usable.

## Decision

**Warn-and-skip** (stderr warning via `StatusPrinter.warning`; strip from effective config; continue) for:

| Item | Behavior |
|------|----------|
| Feature refs containing `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` | Drop from admitted features; do not fetch/install |
| Feature/image metadata `privileged: true` | Do not apply privileged to create; feature may still install if admitted |
| Feature/image metadata non-empty `securityOpt` | Do not apply; feature/image contributions otherwise continue |
| runArgs: `--privileged`, `--device…`, `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime` | Skip entry |
| runArgs `--network` modes `host` / `bridge` / `none` / `container:*` | Skip entry |

**Still hard-error (fail-closed):**

- Docker Compose keys
- Unknown runArgs (not allowlisted and not in the warn-skip family)
- First-class smuggling via runArgs (`-e`, `-u`, `-w`, `-p`, `-v`, …)
- Unknown top-level dangerous properties, missing `image`, invalid feature option shapes, hostRequirements shortfalls, unsupported substitutions

**Semantics:**

- No silent skip — every skipped item warns at least once (via `StatusPrinter.warning`; still emits under `ADEVCONTAINER_QUIET=1`, which only silences progress)
- Config hash / identity uses **effective** config after skips
- Empty features after all docker-* skipped → no Features runner; `up` may still succeed
- Do **not** map privileged → `--virtualization`
- When `--privileged` and/or `--device` are warn-skipped and effective runArgs still include `cap-add` `NET_ADMIN`, emit **one** extra contextual warning that caps alone do not provide device/privileged/VPN-in-container on Apple container
- Warn-stripping feature `privileged`/`securityOpt` does **not** guarantee feature install succeeds if `install.sh` requires those capabilities

## Consequences

- Multi-platform configs can `up` on Apple container with clear warnings
- Removing only skipped noise does not force rebuild (hash is effective-only)
- Agents and docs must not re-learn “forever-reject docker-* features” as hard-error
- Compose and blind/unknown runArgs remain fail-closed per 0002’s remaining scope
