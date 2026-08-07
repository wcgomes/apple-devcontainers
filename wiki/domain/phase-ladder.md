# Phase ladder (0–6)

Product delivery ladder for the Apple-container devcontainer CLI. **MVP = Phases 0–3** ([ADR 0002](../decisions/0002-mvp-phase-3-scope.md)).

| Phase | Scope | Unlocks | Status |
|-------|--------|---------|--------|
| **0** | `image` + workspace bind mount + shell `exec` | Smallest runnable workspace; doctor/up/exec path | **Done** |
| **1** | `containerEnv`, `user`, `workspaceFolder` | Non-root user, env, correct cwd | **Done** |
| **2** | Mounts (bind + volume), `forwardPorts` → publish, `portsAttributes` metadata | Persistent volumes, host file binds, published ports | **Done** |
| **3** | `postCreateCommand` (+ established path for other lifecycle hooks) | Bootstrap scripts after create; pattern for later hooks | **Done** |
| **4** | Broader lifecycle as first-class (`onCreateCommand`, `updateContentCommand`, `postStartCommand`, `postAttachCommand`) **+** `runArgs` **allowlist** (e.g. `--cap-add`, `--init`; still reject privileged/device/unknown) **+** `hostRequirements` preflight (memory/CPU warn or fail — not silent ignore) | Full lifecycle hooks; safe runArgs subset; host capacity checks before create | **Next** |
| **5** | Features runner: OCI fetch + derived image build (runner-owned); never docker-ood | Feature installs without Docker-ood; still subject to reject list | Planned |
| **6** | Advanced parity / stretch (only what Apple container can support safely) | Closes remaining agreed gaps; still no silent unsupported props | Stretch |

## MVP boundary

- **Ship:** 0 → 1 → 2 → 3 in order; each phase assumes prior phases.
- **Do not ship in MVP:** features runner (5), Compose, docker-ood, privileged, tun/devices, blind `runArgs`.
- Phase 4+ may start design notes earlier but must not block 0–3.

## Implementation status

- **Phases 0–3 done** — core MVP realized; SDD change `adevcontainer-core` archived (`specs/changes/archive/20260807-adevcontainer-core/`). Realized contract: `specs/adevcontainer/spec.md`.
- **Next: Phase 4** — lifecycle hooks (first-class) + `runArgs` allowlist + `hostRequirements` preflight.
- postCreate failure cleanup and ProcessRunner pipe drain are in place; see [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
- Does not change ADR 0002 MVP cut; Phase 4 scope refined after MVP (see ADR 0002 consequences).

## Cross-phase rules

- Unsupported property → structured hard error.
- Forever-reject (v1): docker-ood, `--privileged`, `--device=/dev/net/tun`, Compose, blind `runArgs` — [0003](../decisions/0003-reject-docker-ood-privileged-tun.md).
- Features never imply docker-ood support.
- `runArgs` allowlist (Phase 4+) never admits privileged, device, or unknown flags.
- `hostRequirements` (Phase 4+) is preflight: warn or fail per policy — never silent ignore.
