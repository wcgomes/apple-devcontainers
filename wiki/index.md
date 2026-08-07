# Wiki index

macOS Swift CLI (`adevcontainer`): read `devcontainer.json`, drive Apple `container`. Greenfield (not a @devcontainers/cli fork). Host: macOS 26+ Apple Silicon. Runtime dep: Apple container only.

## Architecture

- [architecture.md](architecture.md) — pipeline, package layout, commands (`up` volume reuse, `delete` vs `prune`), progress stderr, identity, lifecycle; binary `adevcontainer`; host macOS 26+; CLT test suite `swift run adevcontainerTests`
- Realized contract: `specs/adevcontainer/spec.md`. SDD change `adevcontainer-core` archived (`specs/changes/archive/20260807-adevcontainer-core/`). Phases 0–3 done; next Phase 4.

## Decisions (ADRs)

- [0001-greenfield-swift-cli.md](decisions/0001-greenfield-swift-cli.md) — greenfield vs fork; Swift; sole runtime = Apple container; no Node
- [0002-mvp-phase-3-scope.md](decisions/0002-mvp-phase-3-scope.md) — MVP cut Phase 3; ship 0→3; phased ladder 0–6; Phase 4 refined post-MVP
- [0003-reject-docker-ood-privileged-tun.md](decisions/0003-reject-docker-ood-privileged-tun.md) — reject docker-ood, privileged, tun; hard errors; no Compose; no blind runArgs

## Domain

- [devcontainer-apple-gaps.md](domain/devcontainer-apple-gaps.md) — Apple container vs Docker/devcontainers gaps; file binds rejected (dir only); list/inspect JSON; keep-alive; create --name = id; Compose/privileged/devices; VS Code attach
- [phase-ladder.md](domain/phase-ladder.md) — phases 0–6; MVP 0–3 done; **next Phase 4** = lifecycle + runArgs allowlist + hostRequirements; 5 features; 6 stretch

## Conventions

- [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md) — AppleContainerRuntime; MountNormalizer file→dir bind promotion; named volume ensure (list-first reuse); `prune` resource set; progress/`==>` tee; machine JSON; ProcessRunner pipe drain; interactive exec (inherit stdio / `-i -t`) vs non-interactive pipes; postCreate delete-on-fail; runArgs allowlist; names/labels
