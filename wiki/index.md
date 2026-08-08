# Wiki index

macOS Swift CLI (`adevcontainer`): read `devcontainer.json`, drive Apple `container`. Greenfield (not a @devcontainers/cli fork). Host: macOS 26+ Apple Silicon. Runtime dep: install Apple `container` separately.

## Architecture

- [architecture.md](architecture.md) — pipeline, package layout, commands (`up` volume reuse, `delete` vs `prune`), progress stderr, identity, lifecycle matrix, runArgs allowlist, hostRequirements, Features (OCI + local path); binary `adevcontainer`; host macOS 26+; tests `swift run adevcontainerTests`
- Contract: [`specs/adevcontainer/spec.md`](../specs/adevcontainer/spec.md)

## Decisions (ADRs)

- [decisions/index.md](decisions/index.md) — ADR routing map
- [0001](decisions/0001-greenfield-swift-cli.md) — greenfield Swift / Apple container
- [0002](decisions/0002-reject-docker-ood-privileged-tun.md) — reject docker-* / privileged / device / Compose / blind runArgs

## Domain

- [devcontainer-apple-gaps.md](domain/devcontainer-apple-gaps.md) — Apple container vs Docker/devcontainers gaps; file binds rejected (dir only); list/inspect JSON; keep-alive `/bin/sleep`; create --name = id; Compose/privileged/devices; VS Code attach; Features OCI + local path

## Conventions

- [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md) — AppleContainerRuntime; Features runner (OCI + local path; derived `container build --platform`; build.rosetta consent; docker-* forever-reject; PATH expansion); MountNormalizer file→dir bind; named volume ensure; `prune` resource set; progress/`==>` tee; machine JSON; ProcessRunner pipe drain; interactive exec vs pipes; lifecycle matrix + create-path delete-on-fail; runArgs allowlist; hostRequirements; names/labels
