# Phase ladder (0–6)

Product delivery ladder for the Apple-container devcontainer CLI. **MVP = Phases 0–3** ([ADR 0002](../decisions/0002-mvp-phase-3-scope.md)).

| Phase | Scope | Unlocks | Status |
|-------|--------|---------|--------|
| **0** | `image` + workspace bind mount + shell `exec` | Smallest runnable workspace; doctor/up/exec path | **Done** |
| **1** | `containerEnv`, `user`, `workspaceFolder` | Non-root user, env, correct cwd | **Done** |
| **2** | Mounts (bind + volume), `forwardPorts` → publish, `portsAttributes` metadata | Persistent volumes, host file binds, published ports | **Done** |
| **3** | `postCreateCommand` (+ established path for other lifecycle hooks) | Bootstrap scripts after create; pattern for later hooks | **Done** |
| **4** | Broader lifecycle as first-class (`onCreateCommand`, `updateContentCommand`, `postStartCommand`, `postAttachCommand`) **+** `runArgs` **allowlist** (e.g. `--cap-add`, `--init`; still reject privileged/device/unknown) **+** `hostRequirements` preflight (memory/CPU fail-on-shortfall + create `-m`/`-c`; parse/unknown fail) | Full lifecycle hooks; safe runArgs subset; host capacity enforce + apply on create | **Done** |
| **5** | Features runner: OCI **and** local path fetch + derived image build (runner-owned, native arm64); never docker-ood | Feature installs without Docker-ood; still subject to reject list | **Done** |
| **6** | Advanced parity / stretch (only what Apple container can support safely) | Closes remaining agreed gaps; still no silent unsupported props | Stretch (optional next) |

## MVP boundary

- **Ship:** 0 → 1 → 2 → 3 in order; each phase assumes prior phases.
- **Do not ship in MVP:** features runner (5), Compose, docker-ood, privileged, tun/devices, blind `runArgs`.
- Phase 4+ may start design notes earlier but must not block 0–3.

## Implementation status

- **Phases 0–3 done** — core MVP realized; SDD change `adevcontainer-core` archived (`specs/changes/archive/20260807-adevcontainer-core/`).
- **Phase 4 done** — lifecycle matrix, `runArgs` allowlist, `hostRequirements` enforce+apply (fail shortfall; map limits on create). Merged into realized contract `specs/adevcontainer/spec.md`. Archived: `specs/changes/archive/20260807-lifecycle-runargs-host/`.
- **Phase 5 done** — Features in realized contract `specs/adevcontainer/spec.md`. Code: `Sources/ADevContainerLib/Features/`. Archived: `specs/changes/archive/20260807-features-runner/`. No active changes.
  - **Refs:** OCI + local path (`./`, `../`, `/`, `file://`) via DefaultFeatureFetcher
  - **Forever-reject:** `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker`; metadata `privileged` / `securityOpt`
  - **Build:** generated Dockerfile + `container build --platform linux/arm64` (native arm); derived tag reuse; one-time `build.rosetta=false` consent (`ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` for CI)
  - **Fixtures:** `features-node`, `features-triple`, `features-local`, `features-docker-ood`, `features-sample/*`
  - **Tests:** ~156+ offline via `swift run adevcontainerTests`; local features E2E when Apple `container` available; OCI E2E needs `ADEVCONTAINER_FEATURES_E2E=1`
- **Phase 6** — stretch / advanced parity only; nothing urgent.
- postCreate / create-path hook failure cleanup and ProcessRunner pipe drain are in place; see [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
- Does not change ADR 0002 MVP cut; Phase 4+ scope refined after MVP (see ADR 0002 consequences).

## Cross-phase rules

- Unsupported property → structured hard error.
- Forever-reject (v1): docker-ood (and docker-in-docker / docker-from-docker), `--privileged`, `--device=/dev/net/tun`, Compose, blind `runArgs` — [0003](../decisions/0003-reject-docker-ood-privileged-tun.md).
- Features never imply docker-ood support.
- `runArgs` allowlist never admits privileged, device, or unknown flags.
- `hostRequirements` is preflight: fail on capacity shortfall or unreadable host; apply requested memory/cpus as create `-m`/`-c` when host OK; warn unsupported `gpu`; fail on unparseable values or unknown keys — never silent ignore.
