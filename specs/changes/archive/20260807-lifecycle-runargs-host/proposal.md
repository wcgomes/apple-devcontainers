# Proposal: lifecycle hooks, runArgs allowlist, hostRequirements

## Intent

Core ships a usable Apple-container devcontainer path through `postCreateCommand`. Teams still need the rest of the common lifecycle set, a **safe** subset of `runArgs`, and honest host capacity checks. This change establishes the durable outcome contract for lifecycle + runArgs + hostRequirements: first-class lifecycle hooks via container exec, an explicit `runArgs` allowlist mapped to Apple `container create`, and `hostRequirements` preflight (warn by default).

## Scope

- Change id: **`lifecycle-runargs-host`**
- Package root: `/Users/wyller/Repos/dev-containerization/`
- Library paths under `Sources/ADevContainerLib/`; suite under `Tests/adevcontainerTests/`; fixtures under `Tests/Fixtures/`
- Realized base contract remains union of `specs/<domain>.md` (core in `specs/core.md`). This delta **adds** lifecycle / runArgs / hostRequirements requirements and **modifies** runArgs admission + `hostRequirements` policy.

### A. Lifecycle hooks (first-class, via `container exec`)

| Property | When it runs |
|----------|----------------|
| `onCreateCommand` | Fresh create path only, first |
| `updateContentCommand` | Fresh create path only, after `onCreateCommand` |
| `postCreateCommand` | Fresh create path only, after `updateContentCommand` (existing core behavior kept) |
| `postStartCommand` | Every successful start that leaves the container running: end of fresh create (after `postCreateCommand`), and when starting a **stopped** container |
| `postAttachCommand` | **Admitted** (string or argv); **not run** on `up`; status once that attach is N/A for CLI-only |

**Locked path matrix**

1. **Fresh create:** `onCreate` → `updateContent` → `postCreate` → `postStart` (all via runtime exec). Non-zero exit fails `up`. On failure of any create-path hook (including `postStart` on first create), delete the container before returning failure (same cleanup posture as core postCreate).
2. **Reuse running:** no lifecycle re-run.
3. **Start stopped:** `postStart` only. Non-zero fails `up`; do **not** delete the container (it was previously usable).
4. **`postAttachCommand`:** parse/admit; never fail solely because it is present; do not execute on `up`; emit a single stderr status such as `postAttach skipped (no attach hook)`.

Forms: each hook is string or argv array (same `LifecycleCommand` model as `postCreateCommand`). Omitted hooks are no-ops.

### B. `runArgs` allowlist

- **Allow:** `--init`; `--cap-add` / `--cap-drop`; `--shm-size`; `--dns` / `--dns-search` / `--dns-option` / `--dns-domain` / `--no-dns`; `--ulimit`; `--tmpfs` (path-before-colon); `--cpus`/`-c` and `--memory`/`-m` (merge into create limits; hostRequirements wins per dimension); named `--network` only; `--rosetta`; `--ssh`; `--read-only`. Valued flags: `=VALUE` or two-token.
- **Empty `runArgs`:** OK (no-op).
- **Forever reject:** `--privileged`; `--device…`; `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`; network modes host/bridge/none/container:*; first-class flags (`-e`/`-u`/`-w`/`-p`/`-v`/`--mount`/`--name`/`--label`/`-i`/`-t`/`-d`/`--rm`/`--entrypoint`); any other non-allowlisted flag.
- **Map** allowlisted entries onto Apple `container create` argv via CreateRequest (memory/cpus via `-m`/`-c` merge only).
- No blind passthrough.

### C. `hostRequirements` preflight

- Remove pure-ignore treatment; **evaluate** on resolve/`up`.
- Support **`memory`** (e.g. `"8gb"`, `"8192mb"`, case-insensitive unit suffixes) and **`cpus`** (number or numeric string).
- **Default policy:** if host is below a parseable requirement → **fail `up`**; when host OK, map requested memory/cpus to `container create` `-m`/`-c`; absent → no limit flags.
- If `hostRequirements` is present but **unparseable** (bad type/shape/unit) → **fail** with structured error naming the field.
- **`gpu`:** if present → **warn** unsupported (do not fail `up` solely for `gpu`).
- Other unknown keys inside `hostRequirements` → structured error (fail closed inside the object).

### D. Fixtures

- `Tests/Fixtures/lifecycle-hooks.json` — multi-hook surface for lifecycle.
- `Tests/Fixtures/runargs-host.json` — allowlisted `runArgs` + parseable `hostRequirements`.

### E. Non-goals

- Features runner / OCI features (see phase-ladder; next).
- Docker Compose / multi-service.
- `--privileged`, device passthrough, blind `runArgs`.
- Full `postAttachCommand` IDE/attach integration (no reliable CLI attach event).
- Soft-warn-only shortfall (product chose enforce+apply instead).
- Network package installs in task execution.

## Approach

Lite SDD: this proposal + delta `spec.md` + dependency-ordered `tasks.md`. Implementation extends existing Config resolver admission, `LifecycleCommand` / `ResolvedDevContainerConfig`, `CreateRequest` argv mapping, and `UpCommand` path matrix. Test-first under MiniTest (`swift run adevcontainerTests`); mockable `ProcessRunning` / runtime; optional real-container integration that skips when Apple `container` is unavailable. No installs in tasks.
