# Change Spec: vscode-open-flag

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Optional `--vscode` flag on up, start, and clone

The CLI MUST accept an optional boolean flag `--vscode` on:

- `adevcontainer up`
- `adevcontainer start`
- `adevcontainer clone`

When `--vscode` is **absent**, those commands MUST behave as today for editor open (no automatic editor open). When `--vscode` is **present**, after the command’s container lifecycle succeeds and the managed container is running (or already running for a start no-op), the CLI MUST attempt a **best-effort** open of a **new** VS Code window attached to that container at the **resolved remote workspace folder** (see VS Code best-effort open). postAttach gating after that open is specified under **postAttachCommand policy (CLI-only)**.

Unknown or misspelled variants that are not the product flag MUST continue to fail closed per existing usage rules. `--vscode` MUST be combinable with other valid flags for those commands (including `--json` where applicable).

#### Scenario: up with --vscode opens editor on remote workspace folder
- Given a successful `adevcontainer up` path that yields a running managed container and a resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer up … --vscode` (with host `code` available and launch succeeding, or mocks equivalent)
- Then after lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And the overall command still reports lifecycle success when open succeeds and postAttach is absent or exits 0

#### Scenario: start with --vscode opens after managed start
- Given a managed container that `adevcontainer start` can select (`--name` or picker) and that is running after start (including already-running no-op success)
- When the user runs `adevcontainer start … --vscode`
- Then after start success the CLI attempts to open a new VS Code window attached to that container at the resolved remote workspace folder from labels/inspect
- And start lifecycle success is unchanged by a successful open when postAttach is absent or exits 0

#### Scenario: clone with --vscode opens after volume-mode create
- Given a successful `adevcontainer clone <git-url>` that yields a running managed container and resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer clone <git-url> --vscode`
- Then after clone lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And clone lifecycle success is unchanged by a successful open when postAttach is absent or exits 0

#### Scenario: without --vscode behavior unchanged
- Given any valid `up`, `start`, or `clone` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of that command
- And manual attach (list/inspect + experimental Attach to Running Apple Container) remains valid

#### Scenario: --json works with --vscode
- Given a successful `up` or `clone` with both `--json` and `--vscode`
- When lifecycle completes successfully and open succeeds and postAttach is absent or exits 0
- Then stdout machine-readable success JSON (shape and fields for that command) remains unchanged by the open side effect
- And open progress or soft-fail warnings MUST NOT corrupt that JSON (warnings/progress on stderr per existing StatusPrinter norms)

---

### Requirement: VS Code best-effort open

When `--vscode` is set and lifecycle has succeeded, the CLI MUST attempt to open VS Code such that:

1. A **new** window is requested (not solely attaching into an arbitrary existing window without folder context).
2. The attachment targets the **managed container** that the command just created, started, or confirmed running.
3. The opened folder is the **resolved remote workspace folder** for that container:
   - Prefer the command’s success result `remoteWorkspaceFolder` when available (`up` / `clone`).
   - For `start`, use inspect/labels: `devcontainer.workspace_folder` (and related inspect fields) already stamped at create.
   - The open path MUST NOT re-parse raw `devcontainer.json` alone to invent a folder. Omit/empty `workspaceFolder` in config is already resolved by the product to the default `/workspaces/<basename>` (bind: host workspace basename; clone: git URL repo basename) and that resolved value MUST be what open uses.
4. Image ref and container id needed for the remote attachment MUST come from create/inspect (or equivalent runtime) results appropriate to the command path — not from user-typed freeform strings beyond normal selection (`--name` / picker / create identity).

**Soft-fail (MUST):**

- If no usable VS Code CLI (`code`) is found, or the open/launch fails for any reason (including missing id, image, or folder inputs needed to build the URI), the CLI MUST:
  - Emit a clear warning on stderr (naming the missing dependency or failure at a high level), and
  - **MUST NOT** change the lifecycle command’s success exit solely because open failed, and
  - **MUST NOT** tear down or alter the container as a consequence of open failure, and
  - **MUST NOT** execute postAttach solely because of that soft-failed open (see postAttachCommand policy).
- The product MAY warn when `code` is missing; it MUST NOT hard-require VS Code for `up` / `start` / `clone` success.

**Host prerequisites (document; soft):**

- VS Code, extension `ms-vscode-remote.remote-containers`, and experimental Apple Container support (`dev.containers.experimentalAppleContainerSupport`) are host prerequisites for a useful open. The CLI SHOULD document them in help and/or README. The CLI MUST NOT claim that `--vscode` provides full Dev Containers extension parity (up/rebuild driver, extension clone-in-volume, etc.).

**Optional nameConfig (MAY/SHOULD):**

- The CLI MAY write a Remote - Containers nameConfig for the container (workspace folder + remote user) when low-risk and useful for attach defaults. Folder-uri open remains the **required** open path; nameConfig MUST NOT be the sole mechanism and MUST NOT cause lifecycle failure if the write fails.

**Approximation (document):**

- Successful host `code` launch is a **CLI-initiated attach approximation**. The CLI MUST NOT wait for VS Code Server fully ready or for IDE-confirmed remote attach before treating open as success for postAttach gating. Detecting manual UI attach is out of scope.

#### Scenario: omitted workspaceFolder uses product default already resolved
- Given a config that omits `workspaceFolder` (or leaves it empty) so resolve yields the product default `/workspaces/<basename>`
- When the user runs `up` or `clone` with `--vscode` after successful lifecycle
- Then the open targets that already-resolved default folder (e.g. `/workspaces/<basename>`), not an empty path and not a re-parse of raw JSON that bypasses the resolver

#### Scenario: soft-fail when code CLI missing
- Given lifecycle would otherwise succeed and `--vscode` is set
- When no usable `code` executable is discoverable on the host
- Then the command still exits successfully for the lifecycle outcome (when postAttach does not run)
- And a stderr warning indicates that VS Code open was skipped or failed because `code` was not found
- And the managed container remains running / created as the lifecycle commanded
- And postAttach MUST NOT execute

#### Scenario: soft-fail when launch fails
- Given lifecycle success, `--vscode` set, and a discoverable `code` that fails when invoked for open
- When open/launch returns failure
- Then the lifecycle command still reports success (when postAttach does not run)
- And a stderr warning indicates the open failure
- And the managed container is not deleted or stopped solely due to that failure
- And postAttach MUST NOT execute

#### Scenario: explicit workspaceFolder is honored for open
- Given a config with an explicit resolved `workspaceFolder` (e.g. `/custom/ws`)
- When `up` or `clone` succeeds with `--vscode`
- Then the open targets `/custom/ws` (the resolved remote workspace folder), not the default `/workspaces/<basename>`

---

## MODIFIED Requirements

### Requirement: VS Code attach acceptance

MVP acceptance for editor integration is:

1. **Manual attach (unchanged core):** After `up` (and equivalently after `clone` / when a managed container is running), the container is running and listable/inspectable so the user can manually use experimental **Attach to Running Apple Container**. The CLI MUST NOT claim full Dev Containers extension parity and MUST NOT fail `up` (or `clone` / `start`) solely because VS Code did not auto-attach or because an optional open was not requested.

2. **Optional best-effort open (additive):** When the user passes `--vscode` on `up`, `start`, or `clone`, the CLI MUST attempt a best-effort open of a new VS Code window on the resolved remote workspace folder per **VS Code best-effort open**. Open failure MUST be soft (warn; lifecycle success preserved **by itself**). Without `--vscode`, no automatic open is required.

3. **CLI attach hook for postAttach:** A successful best-effort open under `--vscode` is the product’s CLI attach hook for gating `postAttachCommand` (see **postAttachCommand policy (CLI-only)**). This is an approximation of IDE attach, not confirmation that the remote session is fully ready.

#### Scenario: Running container is attachable target
- Given a successful `up` (or `clone`)
- When the user lists/inspects containers via the CLI
- Then the workspace container is identifiable for manual VS Code attach

#### Scenario: Optional open does not replace manual attach
- Given a successful lifecycle without or with `--vscode`
- When the user chooses not to rely on automatic open (flag omitted, or open soft-failed)
- Then list/inspect still expose enough identity for manual experimental attach
- And the CLI documentation MUST NOT state that full Dev Containers extension parity is provided

---

### Requirement: postAttachCommand policy (CLI-only)

The CLI MUST parse and admit `postAttachCommand` when present (string or argv array) so configs are not rejected solely for this property. Invalid form (non-string, non-array) MUST still fail resolve with a structured error naming `postAttachCommand` (unchanged).

**When postAttach RUNS**

The CLI MUST execute postAttach only when **all** of the following hold on `up`, `start`, or `clone`:

1. `--vscode` is set, and
2. The best-effort VS Code open outcome is **success** (host `code` launch succeeded per **VS Code best-effort open**).

That successful open is the **CLI attach hook**. Execution MUST occur **after** the successful open attempt completes — never before open when `--vscode` is set.

**What runs**

When the run gate is satisfied, the CLI MUST run:

- Config `postAttachCommand` when present, then
- Feature-contributed postAttach commands (`featurePostAttachCommands` / equivalent merge), in the same merge/order patterns as other feature lifecycle hooks already in product (LifecycleRunner conventions: config hook then feature hooks for that stage).

Each command MUST execute via existing container **exec** lifecycle machinery (same shell-vs-argv rules as `postCreateCommand` / `postStartCommand`), using effective `remoteUser` when set and the resolved workspace folder when set.

**When postAttach is SKIPPED (status line, not executed)**

- **`--vscode` absent** (manual attach path / no CLI attach): if any postAttach is present (config and/or features), the CLI MUST emit a single stderr status line indicating attach is not hooked (e.g. `postAttach skipped (no attach hook)` or a clearer equivalent) and MUST NOT execute postAttach.
- **`--vscode` set but open soft-failed or skipped** (missing `code`, launch fail, missing id/image/folder, or other soft-fail open outcome): the CLI MUST NOT execute postAttach. The CLI SHOULD emit a skip status explaining that attach open did not succeed (in addition to the open soft-fail warning as applicable).
- **No postAttach present** (config and features empty): the CLI MUST NOT emit a postAttach skip line.

**Failure policy**

- If postAttach **runs** and any postAttach command exits non-zero, the lifecycle command (`up` / `start` / `clone`) MUST fail (non-zero) with a clear structured error naming postAttach (property label consistent with other lifecycle hooks, including feature-labeled forms when applicable).
- The CLI MUST NOT delete or stop the container solely due to postAttach failure (container already successfully brought up; VS Code may already be opening). This contrasts with create-path onCreate / updateContent / postCreate / first-create postStart delete-on-fail.
- Open soft-fail still MUST NOT fail the lifecycle command **by itself**. postAttach failure after successful open **does** fail the lifecycle exit.
- On postAttach failure, the command MUST follow the existing error path (no success JSON on stdout for `--json` paths).

**Approximation caveat**

Running postAttach after successful host `code` launch is a **CLI-initiated attach approximation**. The product MUST NOT require IDE-confirmed remote ready, MUST NOT wait for VS Code Server fully ready, and MUST NOT treat manual UI attach as a postAttach trigger. Full IDE attach event integration remains out of scope beyond this gate.

**Consistency**

The gated policy MUST apply consistently on `up`, `start`, and `clone`. Presence of `postAttachCommand` alone MUST NOT fail those commands when postAttach is skipped.

#### Scenario: postAttach runs after successful --vscode open
- Given a valid config with `postAttachCommand` that exits 0, and a successful container lifecycle on `up` (or equivalently `start` / `clone`)
- When the user runs the command with `--vscode` and host `code` launch succeeds (or mocks equivalent)
- Then after the successful open the CLI executes `postAttachCommand` via container exec
- And the command reports lifecycle success
- And success JSON shape (when `--json`) remains unchanged

#### Scenario: postAttach skipped without --vscode
- Given a valid minimal image config that also sets `postAttachCommand` to a command that would exit non-zero if run
- When the user runs `up` (fresh create) without `--vscode`
- Then `up` succeeds without executing `postAttachCommand`
- And stderr includes a one-time skip status for postAttach (e.g. no attach hook)

#### Scenario: postAttach skipped when open soft-fails
- Given a config with `postAttachCommand` present and lifecycle that would otherwise succeed
- When the user runs `up` (or `start` / `clone`) with `--vscode` and open soft-fails (missing `code`, launch failure, or missing open inputs)
- Then the CLI MUST NOT execute `postAttachCommand`
- And the lifecycle command still exits successfully
- And stderr includes open soft-fail warning and SHOULD include a postAttach skip status explaining attach open did not succeed
- And the managed container is not deleted or stopped solely due to open soft-fail

#### Scenario: postAttach failure fails command but keeps container
- Given lifecycle success, `--vscode` set, successful open, and `postAttachCommand` that exits non-zero
- When the user runs `up` (or `start` / `clone`)
- Then the command fails with a structured error naming postAttach
- And the managed container still exists and is not deleted or stopped solely due to that postAttach failure
- And no success JSON is emitted on the error path

#### Scenario: feature postAttach runs after successful open
- Given resolved config with feature-contributed postAttach commands (and optional config `postAttachCommand`) and successful open under `--vscode`
- When postAttach runs
- Then feature postAttach commands execute via container exec after the config hook when both are present (same merge/order spirit as other feature lifecycle hooks)
- And non-zero exit of a feature postAttach fails the command under the same keep-container failure policy as config postAttach

#### Scenario: Invalid postAttach form still fails resolve
- Given `postAttachCommand` set to a non-string, non-array value
- When config is resolved
- Then the CLI fails with a structured error naming `postAttachCommand`

#### Scenario: no skip line when postAttach absent
- Given a config with no `postAttachCommand` and no feature-contributed postAttach commands
- When the user runs `up` without or with `--vscode`
- Then the CLI MUST NOT emit a postAttach skip status line solely for postAttach

---

### Requirement: Lifecycle hook surface

*(Delta only — full hook table remains; replace the `postAttachCommand` role row.)*

| Property | Role |
|----------|------|
| `postAttachCommand` | Admitted; executed only after successful `--vscode` open (CLI attach hook); otherwise skipped with status when present (see postAttachCommand policy) |

Create-path hooks (onCreate → updateContent → postCreate → postStart), reuse, and restart postStart behavior are otherwise unchanged by this delta. postAttach is **not** part of create-path delete-on-fail.

---

### Requirement: Lifecycle hook matrix by path

*(Delta — replace the postAttach matrix row; other rows unchanged.)*

| Path | Lifecycle |
|------|-----------|
| Any path with postAttach present and `--vscode` absent | skip execute; one status line (no attach hook) |
| Any path with postAttach present, `--vscode` set, open soft-failed/skipped | skip execute; SHOULD status that attach open did not succeed |
| Any path with postAttach present, `--vscode` set, open success | after open: run config then feature postAttach via exec; on failure fail command, keep container |
| Any path with postAttach absent | no postAttach skip line; no postAttach exec |

postAttach gating applies on `up`, `start`, and `clone` after the command’s own prior lifecycle steps succeed and (when `--vscode`) after the open attempt outcome is known.

---

### Requirement: Clone lifecycle hooks and temp cleanup

*(Delta only for postAttach bullet under clone lifecycle.)*

- `postAttachCommand` follows the same gated policy as `up` (run only after successful `--vscode` open; skip with status when no attach hook or open soft-failed; failure fails `clone` but MUST NOT delete container/volume solely due to postAttach failure). Create-path hook failure delete policy for onCreate/updateContent/postCreate/postStart is unchanged.

---

## REMOVED Requirements

(none)
