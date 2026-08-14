# adevcontainer — Lifecycle Hooks Specification

## Purpose

Lifecycle hook surface for `initializeCommand` through `postAttachCommand` (string | argv | object-map forms, parallel object-map, create-path order, resume/reuse behavior, delete-on-fail), plus `waitFor`, `userEnvProbe`, and `shutdownAction`. postAttach execution lives in [vscode.md](vscode.md); create-path matrices on `up` also appear in [core.md](core.md).

## Requirements

### Requirement: Lifecycle hook surface

The CLI MUST admit and honor these lifecycle properties. Each command property MUST accept a **string**, an **argv array of strings**, or an **object map** of name → string or argv array. Omitted properties and empty object maps MUST be treated as no-ops.

**Object-map form (official parallel):** each named entry in a stage MUST run concurrently. The stage succeeds only if every entry exits 0. Sequential sorted-by-name MUST NOT be the required behavior.

In-container hooks that run MUST execute via AppleContainerRuntime **exec** into the running container (not baked into the image), using the **resolved remote connection user** (see [core.md](core.md) **Remote connection user resolution**) and workspace folder when set — not create-only `containerUser` when `remoteUser` differs. String vs argv invocation MUST keep the existing product rules (`sh -lc` for strings; argv without a shell). `initializeCommand` is the host exception (see **initializeCommand host execution**).

| Property | Role |
|----------|------|
| `initializeCommand` | Host command at the start of `up` / `clone` / `rebuild` and of a real start when a host workspace exists; volume-mode / clone-origin rebuild with no host workspace still runs on a temporary workspace root that contains the guest config directory/files |
| `onCreateCommand` | Once on fresh create, before content/update and postCreate |
| `updateContentCommand` | On fresh create after `onCreateCommand` (no cloud periodic rerun) |
| `postCreateCommand` | On fresh create after `updateContentCommand` |
| `postStartCommand` | After every successful start of the container: end of fresh create (after postCreate) and start of a previously stopped container (`up` start-stopped and bare `start`, bind and volume) |
| `postAttachCommand` | Admitted; executed per [vscode.md](vscode.md) **postAttachCommand policy (CLI-only)** |
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

### Requirement: Lifecycle hook progress and live stream

When a create-path hook, restart `postStartCommand`, or running `postAttachCommand` executes, the CLI MUST:

1. Emit a stderr progress status line in the StatusPrinter family before the hook runs: `==> Running <property>` (string/argv form), or the labeled form `==> Running <property> (<name>)` for each object-map entry. Presentation MAY apply color and phase section spacing per [terminal-output.md](terminal-output.md); the monochrome text family MUST remain greppable as `==> Running …`.
2. Live-tee the hook command’s **stdout and stderr** to **host stderr** while the command runs, **framed as internal tool output** (each displayed line prefixed with `| ` and indented per [terminal-output.md](terminal-output.md) **Internal tool output framing**), and still capture that output as **unprefixed raw** text for failure diagnostics (structured error text). Non-lifecycle `exec` MAY remain capture-then-print unless another requirement enables streaming.
3. Keep machine JSON on stdout pure when `--json` (or equivalent) is used — hook script stdout MUST NOT write to host stdout (tee to host stderr only).
4. Treat `ADEVCONTAINER_QUIET=1` as silencing **status lines only** (`==> Running …`); hook script output MUST still emit on host stderr under QUIET (framed as internal tool lines).

This requirement MUST NOT change hook order, admitted forms, fail/delete-on-fail policy, or postAttach policy.

#### Scenario: Hook run emits status and framed live-tees I/O
- Given a create-path (or restart postStart / running postAttach) hook that prints to stdout and stderr and exits 0, and quiet mode unset
- When the CLI executes that hook
- Then stderr includes `==> Running <property>` (or labeled form), the hook’s stdout and stderr appear live on host stderr as framed `| ` tool lines, captured diagnostics remain available as raw text on failure paths, and with `--json` host stdout remains pure machine JSON

#### Scenario: Quiet silences status not hook output
- Given `ADEVCONTAINER_QUIET=1` and a hook that prints a recognizable line to stdout
- When the CLI executes that hook
- Then `==> Running …` status lines are not printed and the hook’s output still appears on host stderr as framed internal tool lines

See also: [core.md](core.md) **Up lifecycle** for the create/reuse/start path matrix (including postAttach and vscode customizations rows); [vscode.md](vscode.md) for **postAttachCommand policy (CLI-only)**; [features.md](features.md) **Feature postStart remelt on resume** and **Features progress status lines** for remelt and StatusPrinter / QUIET / `--json` norms; [terminal-output.md](terminal-output.md) for framing/color/QUIET presentation.
