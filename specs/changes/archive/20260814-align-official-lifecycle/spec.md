# Change Spec: align-official-lifecycle

Delta against the live contract (realized `specs/*.md` plus active `specs/changes/vscode-customizations-up-clone-rebuild/spec.md`). RFC 2119 keywords apply. This change **supersedes** that active delta’s start hook lock (`start` MUST NOT run hooks / `postStartCommand`; “Volume-mode start runs no hooks”) and any postAttach rows that still require `--vscode` + successful open. It does **not** supersede “`start` MUST NOT apply vscode customizations”.

## ADDED Requirements

### Requirement: initializeCommand host execution

The CLI MUST admit `initializeCommand` with the same string, argv-array, and object-map forms as other lifecycle commands. Invalid form MUST fail resolve with a structured error naming `initializeCommand`. Omitted or empty object-map MUST be a no-op.

When `initializeCommand` is present, the CLI MUST run it on the **host** (not via container exec) at the start of:

- each `adevcontainer up`, `adevcontainer clone`, and `adevcontainer rebuild` invocation when a host workspace exists,
- each `adevcontainer rebuild` of a volume-mode or clone-origin container when **no** usable host workspace exists, using a temporary host workspace root as specified below, and
- a **real start** (stopped → running) of a managed container when a host workspace exists.

A host workspace exists when the command is operating on a bind-mode workspace, or when stamped `devcontainer.local_folder` / config identify a usable host path (including clone’s config-fetch or retained-checkout directory during `clone` / `rebuild` of a clone-origin container that still has that host path). When a usable host workspace exists, `rebuild` MUST use that path as the hook cwd and MUST NOT substitute a temporary workspace root.

Volume-mode `adevcontainer start` with no usable host workspace MUST skip `initializeCommand` and MUST emit a warning that the host command cannot run. Guest files are not available before `start` without starting the container; `start` MUST NOT start solely to obtain them. Already-running `adevcontainer start` MUST NOT run `initializeCommand` (no start occurred).

**Volume-mode / clone-origin rebuild with no usable host workspace.** When `initializeCommand` is present, the CLI MUST still run it on the host. The hook cwd MUST be a temporary host workspace root that contains the **current** guest config directory/files:

- the guest `.devcontainer/` directory when that directory exists in the guest workspace, and
- the guest root `.devcontainer.json` when that file is the config.

Those contents MUST come from the current guest workspace (the same live, possibly edited files rebuild already reads for config). The CLI MUST NOT re-fetch the git remote solely to obtain them. The temporary workspace root is **not** a full copy of the guest workspace; commands that depend on other repo-root paths (for example `./scripts/…`) are NOT required to work. A command of the form `bash .devcontainer/…` MUST be able to resolve that path from the hook cwd when the guest `.devcontainer/` directory exists.

Absence of a guest `.devcontainer/` directory MUST NOT skip the hook: a host-global `initializeCommand` (no relative config-dir path) MUST still run, with cwd still a temporary workspace root.

On this path the CLI MUST run `initializeCommand` after the current guest workspace is readable and **before** the old container is deleted and **before** the new container is created. After `initializeCommand` returns — success or failure — the CLI MUST remove that temporary workspace root. If removal fails, the CLI MUST emit a warning and MUST NOT fail the command solely due to that removal failure.

Object-map entries MUST run concurrently on the host per **Lifecycle hook surface**. String vs argv invocation MUST keep the existing product rules (`sh -lc` for strings; argv without a shell). Failure of `initializeCommand` MUST fail the command with a structured error naming `initializeCommand`. On create-path, the CLI MUST NOT create the managed container if `initializeCommand` fails. On volume-mode / clone-origin `rebuild` with no usable host workspace, that failure MUST also leave the old container in place. On a real start, the CLI MUST NOT start the stopped container if `initializeCommand` fails. On `up` reuse of an already-running container, `initializeCommand` still MUST run when a host workspace exists; failure MUST fail `up` and MUST NOT stop or delete the running container. `initializeCommand` is not a create-path delete-on-fail hook.

#### Scenario: up runs initializeCommand on the host before create

- Given a bind-mode workspace whose config has `initializeCommand` that exits 0 and no existing container
- When the user runs `adevcontainer up`
- Then the CLI runs `initializeCommand` on the host before creating the container
- And `up` continues through create-path hooks and succeeds

#### Scenario: clone runs initializeCommand on the host checkout

- Given a cloneable repo whose config has `initializeCommand` that exits 0
- When the user runs `adevcontainer clone <git-url>`
- Then the CLI runs `initializeCommand` on the host config-fetch or retained-checkout directory before creating the container
- And clone continues and succeeds

#### Scenario: real bind start runs initializeCommand from stamped host path

- Given a stopped bind-mode managed container with a usable stamped host workspace and a config `initializeCommand` that exits 0
- When the user runs `adevcontainer start --name <that-name>`
- Then the CLI runs `initializeCommand` on that host workspace before starting the container
- And then starts the container

#### Scenario: volume-mode start without host workspace skips initializeCommand

- Given a stopped volume-mode managed container, no usable host workspace, and a config that had `initializeCommand` at create time
- When the user runs `adevcontainer start --name <that-name>`
- Then the CLI starts the container without running `initializeCommand`
- And stderr includes a warning that the host command cannot run

#### Scenario: already-running start does not run initializeCommand

- Given a managed container that is already running and a config with `initializeCommand`
- When the user runs `adevcontainer start --name <that-name>`
- Then the command succeeds as a no-op start
- And `initializeCommand` does not run

#### Scenario: up reuse still runs initializeCommand on the host

- Given a matching already-running bind-mode container and a config with `initializeCommand` that exits 0
- When the user runs `adevcontainer up`
- Then the CLI runs `initializeCommand` on the host
- And onCreate / updateContent / postCreate / postStart do not run

#### Scenario: initializeCommand failure blocks create

- Given no existing container and a config whose `initializeCommand` exits non-zero
- When the user runs `adevcontainer up`
- Then `up` fails with a structured error naming `initializeCommand`
- And no managed container is created

#### Scenario: initializeCommand failure leaves a stopped container stopped

- Given a stopped managed container with a usable host workspace and a config whose `initializeCommand` exits non-zero
- When the user runs `adevcontainer start --name <that-name>`
- Then the command fails with a structured error naming `initializeCommand`
- And the container remains stopped

#### Scenario: volume-mode rebuild without host workspace still runs initializeCommand

- Given a volume-mode or clone-origin managed container, no usable host workspace, a guest `.devcontainer/` directory, and a config `initializeCommand` of the form `bash .devcontainer/…` that exits 0
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI runs `initializeCommand` on the host with cwd a temporary workspace root that contains that guest `.devcontainer/` directory
- And `bash .devcontainer/…` can resolve that path from that cwd
- And the new container is created only after `initializeCommand` succeeds
- And that temporary workspace root is removed after the hook

#### Scenario: volume-mode rebuild initialize temp is removed after failure

- Given a volume-mode or clone-origin managed container, no usable host workspace, and a config whose `initializeCommand` exits non-zero
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `rebuild` fails with a structured error naming `initializeCommand`
- And no new container is created
- And the old container remains
- And the temporary workspace root is removed after the hook

#### Scenario: missing .devcontainer directory does not skip initializeCommand on volume rebuild

- Given a volume-mode or clone-origin managed container, no usable host workspace, a root `.devcontainer.json` as the config, no guest `.devcontainer/` directory, and a host-global `initializeCommand` that exits 0
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI still runs `initializeCommand` on the host with cwd a temporary workspace root that contains that root `.devcontainer.json`
- And the hook is not skipped solely because `.devcontainer/` is absent

#### Scenario: volume-mode rebuild initialize is not a full workspace checkout

- Given a volume-mode or clone-origin managed container, no usable host workspace, a guest `.devcontainer/` directory, and an `initializeCommand` that only needs paths under `.devcontainer/`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the hook runs successfully from a temporary workspace root that contains that `.devcontainer/` directory
- And success does not depend on other guest workspace paths such as `./scripts/…` being present on the host

#### Scenario: volume-mode rebuild with a retained host checkout uses that path

- Given a clone-origin managed container whose retained host checkout is still usable and a config `initializeCommand` that exits 0
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI runs `initializeCommand` with cwd that host checkout
- And it does not substitute a temporary workspace root created solely for the hook

---

### Requirement: waitFor readiness

The CLI MUST admit `waitFor` as an enum of `initializeCommand`, `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, or `postStartCommand`. Omitted `waitFor` MUST default to official `updateContentCommand`. An unknown value MUST fail resolve with a structured error naming `waitFor`.

`waitFor` MUST control when the supporting tool may connect. The command MUST block Ready, optional vscode open, and `postAttachCommand` until the named stage **inclusive** has finished successfully. Stages after `waitFor` MAY complete in the background. The process SHOULD still wait for those remaining hooks before exiting so create-path delete-on-fail and the process exit code remain correct.

The CLI MUST NOT emit success JSON until the `waitFor` stage has succeeded. Ready and connection hints MAY be emitted once `waitFor` is satisfied, even while later create-path hooks are still running. Optional vscode open MAY happen after `waitFor` is satisfied and MUST NOT wait for later background hooks solely to open.

Hook order is unchanged: create-path remains initialize (host) → onCreate → updateContent → postCreate → postStart. First-create `postStartCommand` still belongs to a successful start and MUST still be initiated after `postCreateCommand`, even when `waitFor` is `updateContentCommand` and Ready MAY occur before postCreate / postStart complete. Default `waitFor` therefore means `postCreateCommand` MAY run in the background after Ready.

On resume (real start / `up` start-stopped), create-path stages from a prior successful create are already satisfied. If `waitFor` names a create-path stage (`initializeCommand` through `postCreateCommand`), Ready / open / postAttach MUST NOT wait for those stages again. Ready / open / postAttach MUST wait for this invocation’s `postStartCommand` only when `waitFor` is `postStartCommand`; otherwise on resume they MAY occur before this invocation’s `postStartCommand`.

Failure of a background post-`waitFor` hook MUST fail the command (non-zero) once observed. If Ready was already emitted, the process MUST still exit non-zero and MUST NOT emit a later success JSON. Create-path delete-on-fail still MUST apply to `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and first-create `postStartCommand`. Restart-class hook failure (`postStartCommand` or `postAttachCommand` on a previously successful create) MUST NOT delete the container.

#### Scenario: default waitFor allows Ready before postCreate

- Given a fresh create whose config omits `waitFor` and has `updateContentCommand`, `postCreateCommand`, and `postStartCommand` each exiting 0
- When the user runs `adevcontainer up`
- Then Ready MAY be emitted after `updateContentCommand` succeeds and before `postCreateCommand` finishes
- And `postCreateCommand` then `postStartCommand` still run
- And the process does not exit 0 until those remaining hooks succeed

#### Scenario: waitFor postCreateCommand delays Ready until postCreate

- Given a fresh create whose `waitFor` is `postCreateCommand`
- When the user runs `adevcontainer up`
- Then Ready, optional vscode open, and postAttach do not occur before `postCreateCommand` finishes
- And `postStartCommand` is still initiated after `postCreateCommand`

#### Scenario: success JSON waits for waitFor not for later hooks

- Given a fresh create with default `waitFor` and `--json`
- When `updateContentCommand` has succeeded and `postCreateCommand` is still running
- Then the CLI MUST NOT have emitted success JSON before `updateContentCommand` succeeded
- And success JSON MAY be emitted before `postCreateCommand` finishes

#### Scenario: background create-path hook failure still deletes

- Given a fresh create with default `waitFor` whose `postCreateCommand` exits non-zero after Ready was emitted
- When the user runs `adevcontainer up`
- Then the command exits non-zero
- And the container MUST NOT remain for later reuse as a healthy create

#### Scenario: resume does not re-wait create-path waitFor

- Given a stopped container from a prior successful create and default `waitFor`
- When the user runs `adevcontainer up` (start-stopped) or `adevcontainer start`
- Then Ready / open / postAttach are not blocked on onCreate / updateContent / postCreate
- And Ready / open / postAttach MAY occur before this invocation’s `postStartCommand`
- And this invocation’s `postStartCommand` still runs after the container starts

---

### Requirement: userEnvProbe merge

The CLI MUST admit `userEnvProbe` as an enum of `none`, `interactiveShell`, `loginShell`, or `loginInteractiveShell`. Omitted `userEnvProbe` MUST default to official `loginInteractiveShell`. An unknown value MUST fail resolve with a structured error naming `userEnvProbe`.

When `userEnvProbe` is not `none`, the CLI MUST probe the **remote connection user’s** shell environment inside the running container and MUST merge the probed variables into the environment of subsequent injected processes on that container: in-container lifecycle execs and `adevcontainer exec`. `none` MUST skip the probe and MUST NOT fail solely because the key is `none`.

The probe MUST run after the container is running and before the first in-container lifecycle exec of that invocation (and before `adevcontainer exec` injects a process). Probe failure MUST fail the command with a structured error naming `userEnvProbe` and MUST NOT delete the container solely due to that failure.

#### Scenario: default probe merges into postCreate and exec

- Given a config that omits `userEnvProbe` and a remote connection user whose login-interactive shell exports a recognizable variable
- When the user runs a fresh `up` that executes `postCreateCommand`, then runs `adevcontainer exec`
- Then both injected processes observe that probed variable

#### Scenario: none skips probe

- Given a config with `userEnvProbe` set to `none`
- When the user runs `up` then `adevcontainer exec`
- Then the CLI does not probe the user’s shell environment
- And the command is not failed solely because probing was skipped

#### Scenario: probe uses remote connection user not containerUser

- Given `remoteUser` `alice`, `containerUser` `bob`, and `userEnvProbe` other than `none`
- When the probe runs
- Then it probes `alice`’s shell environment, not `bob`’s

#### Scenario: probe failure keeps the container

- Given a running or just-started container and a `userEnvProbe` other than `none` that fails
- When the command observes the probe failure
- Then the command exits non-zero with a structured error naming `userEnvProbe`
- And the container is not deleted solely due to that failure

---

### Requirement: shutdownAction admission

The CLI MUST admit `shutdownAction` as an enum so configs are not rejected solely for this property. For this image/Dockerfile product, omitted `shutdownAction` MUST default to official `stopContainer`.

- `stopContainer` means `adevcontainer stop` stops the managed container (already required).
- `none` MUST NOT change explicit `adevcontainer stop`: `stop` is still a user command and MUST still stop the container. Last-tool-window-close auto-stop remains out of scope; the CLI MUST NOT claim to observe last-window close.
- `stopCompose` MUST fail closed with a structured error that Compose is unsupported.

An unknown value MUST fail resolve with a structured error naming `shutdownAction`.

#### Scenario: stopContainer config still stops on stop

- Given a running managed container whose config has `shutdownAction` `stopContainer` or omits the key
- When the user runs `adevcontainer stop` for that container
- Then the container is stopped and the command succeeds

#### Scenario: none does not disable explicit stop

- Given a running managed container whose config has `shutdownAction` `none`
- When the user runs `adevcontainer stop` for that container
- Then the container is still stopped

#### Scenario: stopCompose fails closed

- Given a config with `shutdownAction` `stopCompose`
- When config is resolved
- Then the CLI fails with a structured error indicating Compose is unsupported

#### Scenario: shutdownAction presence does not fail parse

- Given an otherwise valid image config with `shutdownAction` `stopContainer` or `none`
- When config is resolved
- Then resolve succeeds

---

### Requirement: Feature postStart remelt on resume

On every path that MUST run `postStartCommand` after a successful start of a previously stopped container (`up` start-stopped and bare `adevcontainer start` in bind and volume modes), the CLI MUST remelt feature-contributed `postStart` commands for that invocation. The CLI MUST run the config `postStartCommand` when present, then feature-contributed postStart commands, in the same merge/order spirit as create-path feature lifecycle hooks.

Resume MUST NOT drop feature-contributed postStart solely because the container was created earlier. Feature onCreate / updateContent / postCreate MUST remain create-path only. A non-zero remelted feature postStart on resume MUST fail the command and MUST NOT delete the container.

When `start` recovery delegates to `rebuild`, the rebuild create-path already includes config and feature postStart. That recovery MUST NOT run an additional postStart after rebuild returns.

#### Scenario: volume-mode start remelts feature postStart

- Given a stopped volume-mode managed container created with a feature that contributed `postStart` (and optional config `postStartCommand`)
- When the user runs `adevcontainer start --name <that-name>`
- Then after the container starts, config postStart (when present) then the feature postStart run via container exec
- And the command succeeds if those commands exit 0

#### Scenario: up start-stopped remelts feature postStart

- Given a matching stopped bind-mode container and remeltable feature postStart
- When the user runs `adevcontainer up`
- Then feature postStart runs on this start (not only the original create)
- And onCreate / updateContent / postCreate do not run

#### Scenario: start recovery via rebuild does not double-run postStart

- Given `start` fails and recovery delegates to `rebuild` for that container
- When rebuild’s create-path runs `postStartCommand` (config and features) on the new container
- Then the user-visible start-recovery path does not run `postStartCommand` a second time after rebuild returns

## MODIFIED Requirements

### Requirement: Lifecycle hook surface

**Domain:** `lifecycle-hooks`

The CLI MUST admit and honor these lifecycle properties. Each command property MUST accept a **string**, an **argv array of strings**, or an **object map** of name → string or argv array. Omitted properties and empty object maps MUST be treated as no-ops.

**Object-map form (official parallel):** each named entry in a stage MUST run concurrently. The stage succeeds only if every entry exits 0. Sequential sorted-by-name MUST NOT be the required behavior.

In-container hooks that run MUST execute via AppleContainerRuntime **exec** into the running container (not baked into the image), using the **resolved remote connection user** and workspace folder when set — not create-only `containerUser` when `remoteUser` differs. String vs argv invocation MUST keep the existing product rules (`sh -lc` for strings; argv without a shell). `initializeCommand` is the host exception (see **initializeCommand host execution**).

| Property | Role |
|----------|------|
| `initializeCommand` | Host command at the start of `up` / `clone` / `rebuild` and of a real start when a host workspace exists; volume-mode / clone-origin rebuild with no host workspace still runs on a temporary workspace root that contains the guest config directory/files |
| `onCreateCommand` | Once on fresh create, before content/update and postCreate |
| `updateContentCommand` | On fresh create after `onCreateCommand` (no cloud periodic rerun) |
| `postCreateCommand` | On fresh create after `updateContentCommand` |
| `postStartCommand` | After every successful start of the container: end of fresh create (after postCreate) and start of a previously stopped container (`up` start-stopped and bare `start`, bind and volume) |
| `postAttachCommand` | Admitted; executed per **postAttachCommand policy (CLI-only)** |
| `waitFor` | Enum; default `updateContentCommand`; see **waitFor readiness** |
| `userEnvProbe` | Enum; default `loginInteractiveShell`; see **userEnvProbe merge** |
| `shutdownAction` | Enum; see **shutdownAction admission** |

Create-path order on fresh `up` / `clone` / `rebuild` remains initialize (host) → onCreate → updateContent → postCreate → postStart, with feature-contributed onCreate / updateContent / postCreate / postStart merged on create-path. Reuse of an already-running container on `up` MUST NOT re-run onCreate / updateContent / postCreate / postStart. `up` reuse MUST still run host `initializeCommand` when a host workspace exists and MUST still follow postAttach policy.

Create-path hook failure (onCreate, updateContent, postCreate, first-create postStart) MUST fail the command and MUST NOT leave the container for later reuse as a healthy create. Restart-class `postStartCommand` failure MUST fail the command and MUST NOT delete the container.

#### Scenario: Fresh create runs full hook order

- Given a config with `initializeCommand`, `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and `postStartCommand` each exiting 0
- When the user runs `up` and no container exists for the workspace
- Then the CLI runs initialize on the host, then onCreate → updateContent → postCreate → postStart via exec, and `up` succeeds

#### Scenario: Reuse running skips create-path and postStart

- Given a matching container already running (matching config hash) and a config with create-path hooks and `postStartCommand`
- When the user runs `up` (no rebuild)
- Then onCreate, updateContent, postCreate, and postStart are not executed
- And postAttach still follows **postAttachCommand policy (CLI-only)**

#### Scenario: Start stopped runs postStart on up

- Given a matching container that is stopped and a config with `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and `postStartCommand`
- When the user runs `up`
- Then only resume hooks for a real start run (initialize when a host workspace exists, then postStart; onCreate, updateContent, and postCreate do not run)
- And `up` succeeds if those resume hooks exit 0

#### Scenario: Create-path hook failure deletes container

- Given no existing container and a config whose `onCreateCommand` (or later create-path hook including first-create `postStartCommand`) exits non-zero
- When the user runs `up`
- Then `up` fails with a structured error naming the failing property and exit code, and the container MUST NOT remain for a later reuse as a healthy create

#### Scenario: Restart postStart failure does not delete container

- Given a stopped container from a prior successful create and a config whose `postStartCommand` exits non-zero
- When the user runs `up` or `adevcontainer start`
- Then the command fails with a structured error for `postStartCommand` and the container still exists (MUST NOT be deleted solely due to restart postStart failure)

#### Scenario: Lifecycle command forms

- Given `postStartCommand` as a string and `onCreateCommand` as an argv array of strings
- When config is resolved
- Then both admit successfully and map using the same shell-vs-argv rules as `postCreateCommand`

#### Scenario: Lifecycle object-map runs in parallel

- Given `onCreateCommand` as an object map with two named entries that each exit 0
- When that stage runs
- Then both named entries run concurrently
- And the stage succeeds only after every entry exits 0

#### Scenario: Lifecycle object-map stage fails if any entry fails

- Given `postStartCommand` as an object map where one named entry exits non-zero
- When that stage runs on a restart path
- Then the stage fails
- And the container is not deleted solely due to that restart failure

---

### Requirement: Start managed container

**Domain:** `managed-lifecycle`  
*(Overrides realized lock at `specs/managed-lifecycle.md` and active `specs/changes/vscode-customizations-up-clone-rebuild/spec.md` **Start managed container** hook lock. Does **not** override that delta’s vscode customizations exclusion on `start`.)*

The CLI MUST provide `adevcontainer start` that starts a **stopped** managed container.

**Selection** is unchanged: `--name`, single-eligible auto-select, interactive picker, non-TTY `--name` required; selection set is managed containers only.

**Runtime behavior**

- If the selected container is stopped → start it via AppleContainerRuntime after any required host `initializeCommand`.
- If already running → success **no-op** (MUST NOT error solely because it was already running). Already-running MUST NOT run `initializeCommand` or `postStartCommand`.
- MUST NOT re-clone the git URL.
- MUST NOT run the full `up` or `clone` create path (no Features rebuild, no volume re-populate, no onCreate / updateContent / postCreate).

**Lifecycle hooks on start (replaces the prior lock)**

| Workspace origin | Real start (stopped → running) |
|------------------|--------------------------------|
| **Bind-mode** | Host `initializeCommand` when a usable stamped host workspace exists; then start; then config `postStartCommand` then remelted feature postStart. Ready / open / postAttach follow **waitFor readiness** and **postAttachCommand policy (CLI-only)** |
| **Volume-mode / clone-origin** | Skip `initializeCommand` with a warning when no host workspace exists; start; then config `postStartCommand` then remelted feature postStart. Ready / open / postAttach follow **waitFor readiness** and **postAttachCommand policy (CLI-only)** |

`up` start-stopped MUST keep the same resume hook set (initialize when a host workspace exists, then postStart including remelted feature postStart). Bare `start` is no longer runtime-start-only.

Restart-class hook failure MUST fail `start` and MUST NOT delete the container. When `start` recovery delegates to `rebuild`, rebuild’s create-path already includes postStart; the recovery path MUST NOT double-run postStart after rebuild.

**Vscode customizations on start (unchanged by this change)**

- `adevcontainer start` MUST NOT apply `customizations.vscode.settings` or `customizations.vscode.extensions`, with or without `--vscode`.
- Config load on `start` MAY be used for hooks, open, and postAttach. It MUST NOT be used to apply settings or extensions.

#### Scenario: Start stopped managed container

- Given a managed container created by clone that is stopped
- When the user runs `adevcontainer start --name <that-name>`
- Then the container is running and the command succeeds without re-cloning

#### Scenario: Start already running is no-op success

- Given a managed container that is already running
- When the user runs `adevcontainer start --name <that-name>`
- Then the command succeeds without changing the container
- And `initializeCommand` and `postStartCommand` do not run

#### Scenario: Start interactive picker when multiple

- Given two stopped managed containers and an interactive TTY stdin
- When the user runs `adevcontainer start` without `--name`
- Then the CLI presents an interactive selection UI and starts the chosen container

#### Scenario: Volume-mode start runs postStart

- Given a volume-mode managed container with labels from clone and a config that had `postStartCommand` at create time
- When the user runs `adevcontainer start --name <that-name>` on a stopped container
- Then the container starts and `postStartCommand` runs via container exec
- And onCreate / updateContent / postCreate do not run

#### Scenario: Bind-mode start runs postStart

- Given a stopped bind-mode managed container and a config with `postStartCommand` that exits 0
- When the user runs `adevcontainer start --name <that-name>`
- Then the container starts and `postStartCommand` runs
- And the command succeeds

#### Scenario: start does not apply vscode customizations

- Given a managed container whose config has well-formed settings and extensions and whose guest marker is missing or drifted
- When the user runs `adevcontainer start` without or with `--vscode`
- Then the CLI MUST NOT apply those settings or extensions on this path
- And resume hooks still follow this requirement

---

### Requirement: postAttachCommand policy (CLI-only)

**Domain:** `vscode`

The CLI MUST parse and admit `postAttachCommand` when present (string, argv array, or object map of name → string|argv — same forms as other hooks) so configs are not rejected solely for this property. Invalid form MUST still fail resolve with a structured error naming `postAttachCommand`. Object-map entries MUST run concurrently per **Lifecycle hook surface**.

This policy is a **CLI attach model**. The CLI is the supporting tool. Manual IDE UI attach without the CLI remains out of scope. `adevcontainer exec` is **not** attach and MUST NOT run `postAttachCommand`. The product MUST NOT require IDE-confirmed remote ready and MUST NOT wait for VS Code Server fully ready.

**When postAttach RUNS**

The CLI MUST execute postAttach when **any** of the following hold after the command’s prior lifecycle steps required by `waitFor` have succeeded:

1. Successful `adevcontainer up`, `adevcontainer clone`, or `adevcontainer rebuild` (including `up` reuse of an already-running matching container) — the CLI attach at the end of that supporting-tool command.
2. A **real** `adevcontainer start` of a previously stopped container.
3. Already-running `adevcontainer start` **only when** `--vscode` is set **and** best-effort open succeeds — that open is an actual tool attach.

When `--vscode` is set on a path that already qualifies as CLI attach (items 1–2), postAttach MUST still run **after** the open attempt. If that open **soft-fails**, the CLI MUST still run postAttach (open is best-effort and MUST NOT suppress the CLI attach). When `--vscode` is set and open **succeeds**, postAttach MUST run after that successful open.

**What runs**

When the run gate is satisfied, the CLI MUST run config `postAttachCommand` when present, then feature-contributed postAttach commands, using the resolved remote connection user and workspace folder when set. When `remoteUser` is `alice` and `containerUser` is `bob`, postAttach MUST use `alice`.

**When postAttach is SKIPPED (status line, not executed)**

- Already-running `start` without a successful `--vscode` open: if any postAttach is present, emit a single stderr skip status and MUST NOT execute postAttach.
- `--vscode` set on already-running `start` and open soft-failed or skipped: MUST NOT execute postAttach; SHOULD emit a skip status that attach open did not succeed.
- No postAttach present: MUST NOT emit a postAttach skip line.

**Failure policy**

- If postAttach runs and any postAttach command exits non-zero, the lifecycle command MUST fail (non-zero) with a structured error naming postAttach.
- The CLI MUST NOT delete or stop the container solely due to postAttach failure. On `rebuild`, a non-zero postAttach MUST keep the **new** container and MUST NOT start a recovery session.
- Open soft-fail still MUST NOT fail the lifecycle command **by itself**.
- On postAttach failure, the command MUST follow the existing error path (no success JSON on stdout for `--json` paths).

**Consistency**

Presence of `postAttachCommand` alone MUST NOT fail those commands when postAttach is skipped. vscode customizations apply on `start` remains forbidden.

#### Scenario: postAttach runs at end of up without --vscode

- Given a valid config with `postAttachCommand` that exits 0 and a successful `up` (fresh, reuse, or start-stopped)
- When the user runs `up` without `--vscode`
- Then the CLI executes `postAttachCommand` via container exec after waitFor is satisfied
- And the command reports lifecycle success when postAttach exits 0

#### Scenario: postAttach runs after real start without --vscode

- Given a stopped managed container, default `waitFor`, and a config with `postAttachCommand` that exits 0
- When the user runs `adevcontainer start --name <that-name>` without `--vscode`
- Then after the real start, once waitFor is satisfied, the CLI executes `postAttachCommand`
- And that MAY be before this invocation’s `postStartCommand`
- And the command succeeds

#### Scenario: already-running start skips postAttach without successful open

- Given a managed container that is already running and a config with `postAttachCommand` that would exit non-zero if run
- When the user runs `adevcontainer start --name <that-name>` without `--vscode`
- Then `postAttachCommand` does not run
- And stderr includes a one-time skip status
- And the command succeeds

#### Scenario: already-running start runs postAttach after successful --vscode open

- Given an already-running managed container, `postAttachCommand` that exits 0, and `--vscode` whose host `code` launch succeeds
- When the user runs `adevcontainer start … --vscode`
- Then after the successful open the CLI executes `postAttachCommand`
- And `initializeCommand` and `postStartCommand` do not run

#### Scenario: open soft-fail does not suppress CLI-attach postAttach

- Given a config with `postAttachCommand` present and a successful `up` / `clone` / `rebuild` or real `start`
- When the user runs that command with `--vscode` and open soft-fails
- Then the CLI still executes `postAttachCommand`
- And open soft-fail does not by itself fail the command
- And the managed container is not deleted or stopped solely due to open soft-fail

#### Scenario: postAttach still runs after successful --vscode open on CLI-attach paths

- Given a valid config with `postAttachCommand` that exits 0 and a successful container lifecycle on `up` (or equivalently real `start` / `clone` / `rebuild`)
- When the user runs the command with `--vscode` and host `code` launch succeeds
- Then after the successful open the CLI executes `postAttachCommand`
- And the command reports lifecycle success

#### Scenario: postAttach failure fails command but keeps container

- Given a CLI-attach path that runs postAttach and `postAttachCommand` exits non-zero
- When the user runs `up` (or `start` / `clone` / `rebuild`)
- Then the command fails with a structured error naming postAttach
- And the managed container still exists and is not deleted or stopped solely due to that failure
- And on rebuild, no recovery session is created
- And no success JSON is emitted on the error path

#### Scenario: feature postAttach runs on CLI attach

- Given resolved config with feature-contributed postAttach commands (and optional config `postAttachCommand`) on a CLI-attach path
- When postAttach runs
- Then feature postAttach commands execute via container exec after the config hook when both are present
- And non-zero exit of a feature postAttach fails the command under the same keep-container failure policy as config postAttach

#### Scenario: exec is not attach

- Given a running managed container and a config with `postAttachCommand`
- When the user runs `adevcontainer exec`
- Then `postAttachCommand` does not run

#### Scenario: Invalid postAttach form still fails resolve

- Given `postAttachCommand` set to a non-string, non-array, non-object value
- When config is resolved
- Then the CLI fails with a structured error naming `postAttachCommand`

#### Scenario: no skip line when postAttach absent

- Given a config with no `postAttachCommand` and no feature-contributed postAttach commands
- When the user runs `up` without or with `--vscode`
- Then the CLI MUST NOT emit a postAttach skip status line solely for postAttach

#### Scenario: postAttach runs as remote connection user not containerUser

- Given `remoteUser` `alice`, `containerUser` `bob`, and a CLI-attach path that runs postAttach
- When postAttach runs
- Then postAttach exec uses user `alice`

---

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

**Domain:** `core`  
*(Delta — lifecycle bullets only; other surface bullets remain as in the live contract including active vscode-customizations editor-customizations text.)*

**Lifecycle**

- `initializeCommand` — string, argv array, or object map; host command per **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and **postAttachCommand policy (CLI-only)**
- `waitFor` — enum; default `updateContentCommand`; policy per **waitFor readiness**
- `userEnvProbe` — enum; default `loginInteractiveShell`; policy per **userEnvProbe merge**
- `shutdownAction` — enum; default `stopContainer` for this image/Dockerfile product; `stopCompose` fails closed; policy per **shutdownAction admission**

#### Scenario: Lifecycle / runArgs / hostRequirements property set does not hard-error as unknown

- Given a config that includes only core supported keys plus the lifecycle properties in this requirement, allowlisted `runArgs`, and `hostRequirements`
- When config is validated
- Then validation does not fail with unsupported-property for those keys

#### Scenario: initializeCommand waitFor userEnvProbe shutdownAction admit

- Given a minimal image config that also sets valid `initializeCommand`, `waitFor`, `userEnvProbe`, and `shutdownAction` `stopContainer`
- When config is resolved
- Then resolve succeeds and those fields are available to lifecycle paths

---

### Requirement: Up lifecycle (create, start, reuse)

**Domain:** `core`  
*(Delta — replace the lifecycle hook matrix and postAttach rows. Vscode customizations apply matrix from active `vscode-customizations-up-clone-rebuild` remains in force, including `start` MUST NOT apply. The sentence “Bind start-stopped postStartCommand remains an `up` path only” is superseded.)*

**Lifecycle hook matrix by path**

| Path | Lifecycle |
|------|-----------|
| Fresh create (missing) | Host initialize (when a host workspace exists) → onCreate → updateContent → postCreate → postStart; delete container if any create-path hook (onCreate / updateContent / postCreate / first postStart) fails; Ready / open / postAttach wait for `waitFor` (default updateContent) |
| `rebuild <name>` | Same fresh create-path on the **new** container, including host initialize (volume-mode / clone-origin with no usable host workspace: initialize still runs on a temporary workspace root that contains the guest config directory/files; temp removed after the hook); delete-on-fail applies to the **new** container; recovery offer rules unchanged |
| Reuse running (matching identity) | No onCreate / updateContent / postCreate / postStart; host initialize MUST run when a host workspace exists; postAttach runs as CLI attach |
| Start stopped (`up` or bare `start`) | Host initialize when a host workspace exists; postStart (config then remelted feature postStart); on failure fail the command, do not delete; Ready / open / postAttach follow **waitFor readiness** (this invocation’s postStart only when `waitFor` is `postStartCommand`); postAttach runs as CLI attach |
| Already-running `start` | No initialize / postStart; postAttach only after successful `--vscode` open |
| CLI-attach path (`up` / `clone` / `rebuild` / real `start`) with postAttach present | After waitFor: run config then feature postAttach; `--vscode` open soft-fail MUST NOT skip; on failure fail command, keep container |
| Already-running `start` with postAttach present and no successful `--vscode` open | skip execute; one status line |
| Any path with postAttach absent | no postAttach skip line; no postAttach exec |

postAttach is **not** part of create-path delete-on-fail. Settings/open soft-fail and postAttach failure MUST NOT enter either recovery session. Customizations apply remains **not** part of create-path delete-on-fail, **not** folded into postAttach, and **not** run on `start`.

Create-path cleanup is unchanged: if any create-path hook fails before the command returns success, the CLI MUST delete the new/created container (extend to onCreate, updateContent, postCreate, and first-create postStart). On `rebuild`, delete-on-fail applies to the **new** container only.

#### Scenario: Create then reuse

- Given no existing container for the workspace
- When the user runs `up` twice with the same config
- Then the first run creates and starts a container and prints success JSON including `containerId` and `remoteWorkspaceFolder`, and the second run reuses the running container without error

#### Scenario: Start stopped container

- Given a container previously created by `up` that is stopped
- When the user runs `up`
- Then the container is started, resume hooks run, and success JSON is emitted

#### Scenario: Create then reuse still stable with hooks

- Given a successful fresh `up` with postStart configured
- When the user runs `up` again while the container is running
- Then the second run reuses without re-running onCreate / updateContent / postCreate / postStart

#### Scenario: up start-stopped remelts feature postStart

- Given a matching stopped container and a feature-contributed postStart
- When the user runs `up`
- Then feature postStart runs after the container starts
- And onCreate / updateContent / postCreate do not run

#### Scenario: up without --vscode still runs postAttach

- Given a matching running or freshly created container and `postAttachCommand` that exits 0
- When the user runs `up` without `--vscode`
- Then postAttach runs after waitFor is satisfied

#### Scenario: rebuild hook matrix row applies

- Given a managed container being rebuilt with a config carrying initialize plus the four create-path hooks
- When `rebuild` runs the fresh create-path on the new container
- Then initialize runs on the host, then onCreate → updateContent → postCreate → postStart execute on the new container, and a first create-path hook failure deletes only the new container

---

### Requirement: Clone lifecycle hooks and temp cleanup

**Domain:** `clone`

**Lifecycle (clone fresh create)**

At the start of `clone`, when a host checkout exists, the CLI MUST run host `initializeCommand` per **initializeCommand host execution**. After successful populate, `clone` MUST run create-path lifecycle hooks with the **same matrix as `up` fresh create**:

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

- In-container hooks run via AppleContainerRuntime exec (not baked into the image).
- Non-zero exit of any create-path hook MUST fail `clone` and MUST delete the container **and** the workspace volume before returning failure.
- `postAttachCommand` follows **postAttachCommand policy (CLI-only)** (CLI attach at the end of successful `clone`; not `--vscode`-gated; failure fails `clone` but MUST NOT delete container/volume solely due to postAttach failure).
- `waitFor` applies as on `up` fresh create.

**Temp cleanup** is unchanged: config-fetch temps deleted on success and failure; temp-deletion failure warns only.

#### Scenario: Create-path hooks run after populate

- Given a config with `postCreateCommand` that exits 0
- When clone completes create, start, and populate successfully
- Then create-path hooks run in order and clone reports success

#### Scenario: clone runs postAttach without --vscode

- Given a successful clone populate and create-path hooks and `postAttachCommand` that exits 0
- When the user runs `clone` without `--vscode`
- Then the CLI executes `postAttachCommand`
- And clone reports success

#### Scenario: Temp dirs always cleaned up

- Given clone runs to success or to a mid-flow structured failure after temps were created
- When the command returns
- Then config-fetch temp directories are removed (or a stderr warning is emitted if removal failed)

#### Scenario: Hook failure deletes container and workspace volume

- Given populate succeeded and `postCreateCommand` exits non-zero
- When clone runs
- Then clone fails structured, the managed dev container is deleted, the workspace `*-ws` volume is deleted, and temps are cleaned up

---

### Requirement: VS Code attach acceptance

**Domain:** `vscode`  
*(Delta — replace CLI attach hook bullet 3. Manual attach, optional open, and customizations-apply bullets stay as in the live contract including active vscode-customizations.)*

3. **CLI attach hook for postAttach:** The CLI is the supporting tool. `postAttachCommand` runs per **postAttachCommand policy (CLI-only)** — at the end of successful `up` / `clone` / `rebuild`, after a real `start`, and on already-running `start` only after successful `--vscode` open. A successful best-effort open is an additional tool attach, not the sole gate, and MUST NOT be required for CLI-attach paths. This is an approximation of IDE attach, not confirmation that the remote session is fully ready.

#### Scenario: Running container is attachable target

- Given a successful `up` (or `clone`)
- When the user lists/inspects containers via the CLI
- Then the managed dev container is identifiable for manual VS Code attach

#### Scenario: Optional open does not replace manual attach

- Given a successful lifecycle without or with `--vscode`
- When the user chooses not to rely on automatic open (flag omitted, or open soft-failed)
- Then list/inspect still expose enough identity for manual experimental attach
- And the CLI documentation MUST NOT state that full Dev Containers extension parity is provided

---

### Requirement: Optional `--vscode` flag on up, start, clone, and rebuild

**Domain:** `vscode`  
*(Delta — `--vscode` remains best-effort open; postAttach is no longer gated on the flag except for already-running `start`. Customizations apply on `start` remains forbidden.)*

When `--vscode` is **absent**, those commands MUST NOT invoke a host VS Code open. When `--vscode` is **present**, after the command’s container lifecycle has reached the `waitFor` connection point and the managed container is running (or already running for a start no-op), the CLI MUST attempt a **best-effort** open of a **new** VS Code window attached to that container at the **resolved remote workspace folder**. postAttach after that open is specified under **postAttachCommand policy (CLI-only)**.

`--vscode` MUST NOT gate settings apply or extensions apply. On `start`, the flag still requests open (and postAttach only when open succeeds on an already-running container); `start` MUST NOT apply customizations. On CLI-attach paths, omitting `--vscode` MUST NOT skip postAttach.

#### Scenario: --vscode still only gates open not apply on up

- Given a successful `up` create-path with well-formed settings and extensions and a config that also has `postAttachCommand`
- When the user runs `up` **without** `--vscode`
- Then settings and extensions apply still run per the apply requirements
- And the CLI MUST NOT invoke a host VS Code open
- And postAttach MUST execute as CLI attach

#### Scenario: --vscode on already-running start opens without applying customizations

- Given a managed container that is already running and a config with settings, extensions, and `postAttachCommand`
- When the user runs `start --vscode` and host `code` launch succeeds
- Then after start success the CLI attempts to open a new VS Code window attached to that container
- And postAttach runs after that successful open
- And the CLI MUST NOT apply settings or extensions on that `start` invocation
- And `postStartCommand` does not run

#### Scenario: without --vscode behavior unchanged for open

- Given any valid `up`, `start`, `clone`, or `rebuild` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of that command
- And manual attach remains valid

---

### Requirement: VS Code best-effort open

**Domain:** `vscode`  
*(Delta — open soft-fail MUST NOT suppress CLI-attach postAttach. Other open mechanics stay.)*

**Soft-fail (MUST):**

- If no usable VS Code CLI (`code`) is found, or the open/launch fails for any reason, the CLI MUST emit a clear warning on stderr, MUST NOT change the lifecycle command’s success exit solely because open failed, and MUST NOT tear down or alter the container as a consequence of open failure.
- On a path that would otherwise run postAttach as CLI attach (`up` / `clone` / `rebuild` / real `start`), open soft-fail MUST NOT prevent postAttach.
- On already-running `start`, open soft-fail MUST NOT by itself execute postAttach (there was no CLI attach and no successful tool open).

Successful host `code` launch remains a CLI-initiated attach approximation. The CLI MUST NOT wait for VS Code Server fully ready. Detecting manual UI attach is out of scope.

#### Scenario: soft-fail when code CLI missing on CLI-attach path

- Given lifecycle would otherwise succeed on `up` and `--vscode` is set and `postAttachCommand` exits 0
- When no usable `code` executable is discoverable on the host
- Then the command still attempts `postAttachCommand`
- And a stderr warning indicates that VS Code open was skipped or failed because `code` was not found
- And the managed container remains running / created as the lifecycle commanded

#### Scenario: soft-fail when launch fails on already-running start

- Given an already-running container, `--vscode` set, and a discoverable `code` that fails when invoked for open
- When open/launch returns failure
- Then the lifecycle command still reports success
- And a stderr warning indicates the open failure
- And `postAttachCommand` MUST NOT execute
- And the managed container is not deleted or stopped solely due to that failure

---

### Requirement: Merge feature metadata into create and lifecycle

**Domain:** `features`  
*(Delta — lifecycle-hooks contribution row only.)*

| Contribution | Merge behavior |
|--------------|----------------|
| lifecycle hooks contributed by features | Appended/merged into the create-path exec order after start (installs already in derived image); same string/argv/object-map forms and failure/delete-on-fail policy as config hooks for create-path failures. Feature `postStart` (and feature `postAttach` when postAttach runs) MUST remelt on resume per **Feature postStart remelt on resume** and **postAttachCommand policy (CLI-only)**. Feature onCreate / updateContent / postCreate MUST NOT run on resume. |

#### Scenario: Feature lifecycle hooks run on fresh create via exec

- Given feature metadata contributing a post-create-style lifecycle command and a fresh create path
- When `up` succeeds through create
- Then the contributed hook runs via runtime exec after start (features already installed in the derived image), and non-zero exit fails `up` under create-path policy

#### Scenario: Feature postStart remelts on start

- Given feature metadata contributing `postStart` and a stopped managed container from a prior successful create
- When the user runs `adevcontainer start` or `up` start-stopped
- Then the contributed postStart runs via runtime exec on this start

#### Scenario: start with unreadable config still runs metadata postStart

- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postStart`
- When the user runs `adevcontainer start --name <that-name>`
- Then after the container starts, feature-only postStart runs via container exec (`failKeepContainer`)
- And onCreate / updateContent / postCreate do not run
- And vscode customizations are not applied

#### Scenario: start with unreadable config still runs metadata postAttach on CLI attach

- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postAttach`
- When the user runs a real `adevcontainer start` (CLI-attach gate)
- Then feature-only postAttach runs via container exec (`failKeepContainer`)

#### Scenario: derived-image LABEL includes base-image postStart/postAttach after Features build

- Given a base image whose `devcontainer.metadata` contributes `postStart` / `postAttach` and a feature that also contributes those hooks
- When Features builds a derived image
- Then the derived `LABEL devcontainer.metadata` includes both the base-image and feature hooks

#### Scenario: no-features up runs image-metadata postCreate/postStart

- Given a config with empty `features` and a base image whose `devcontainer.metadata` contributes `onCreate` / `updateContent` / `postCreate` / `postStart` / `postAttach`
- When the user runs a fresh `up`
- Then those image-metadata hooks run via container exec on the create path (and postAttach as CLI attach)
- And Features `container build` does not run

#### Scenario: up finish still has base-image postAttach after remelt

- Given Features apply already unioned base-image `postAttach` into the create config
- When `up` finish remelts feature postAttach from image metadata that is features-only
- Then the base-image postAttach still runs (remelt unions, does not replace-away)
