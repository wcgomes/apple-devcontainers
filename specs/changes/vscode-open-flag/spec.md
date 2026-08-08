# Change Spec: vscode-open-flag

Delta against realized contract `specs/adevcontainer/spec.md`. RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Optional `--vscode` flag on up, start, and clone

The CLI MUST accept an optional boolean flag `--vscode` on:

- `adevcontainer up`
- `adevcontainer start`
- `adevcontainer clone`

When `--vscode` is **absent**, those commands MUST behave as today (no automatic editor open). When `--vscode` is **present**, after the command’s container lifecycle succeeds and the managed container is running (or already running for a start no-op), the CLI MUST attempt a **best-effort** open of a **new** VS Code window attached to that container at the **resolved remote workspace folder** (see VS Code best-effort open).

Unknown or misspelled variants that are not the product flag MUST continue to fail closed per existing usage rules. `--vscode` MUST be combinable with other valid flags for those commands (including `--json` where applicable).

#### Scenario: up with --vscode opens editor on remote workspace folder
- Given a successful `adevcontainer up` path that yields a running managed container and a resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer up … --vscode` (with host `code` available and launch succeeding, or mocks equivalent)
- Then after lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And the overall command still reports lifecycle success

#### Scenario: start with --vscode opens after managed start
- Given a managed container that `adevcontainer start` can select (`--name` or picker) and that is running after start (including already-running no-op success)
- When the user runs `adevcontainer start … --vscode`
- Then after start success the CLI attempts to open a new VS Code window attached to that container at the resolved remote workspace folder from labels/inspect
- And start lifecycle success is unchanged by a successful open

#### Scenario: clone with --vscode opens after volume-mode create
- Given a successful `adevcontainer clone <git-url>` that yields a running managed container and resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer clone <git-url> --vscode`
- Then after clone lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And clone lifecycle success is unchanged by a successful open

#### Scenario: without --vscode behavior unchanged
- Given any valid `up`, `start`, or `clone` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of that command
- And manual attach (list/inspect + experimental Attach to Running Apple Container) remains valid

#### Scenario: --json works with --vscode
- Given a successful `up` or `clone` with both `--json` and `--vscode`
- When lifecycle completes successfully
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

- If no usable VS Code CLI (`code`) is found, or the open/launch fails for any reason, the CLI MUST:
  - Emit a clear warning on stderr (naming the missing dependency or failure at a high level), and
  - **MUST NOT** change the lifecycle command’s success exit solely because open failed, and
  - **MUST NOT** tear down or alter the container as a consequence of open failure.
- The product MAY warn when `code` is missing; it MUST NOT hard-require VS Code for `up` / `start` / `clone` success.

**Host prerequisites (document; soft):**

- VS Code, extension `ms-vscode-remote.remote-containers`, and experimental Apple Container support (`dev.containers.experimentalAppleContainerSupport`) are host prerequisites for a useful open. The CLI SHOULD document them in help and/or README. The CLI MUST NOT claim that `--vscode` provides full Dev Containers extension parity (up/rebuild driver, extension clone-in-volume, etc.).

**Optional nameConfig (MAY/SHOULD):**

- The CLI MAY write a Remote - Containers nameConfig for the container (workspace folder + remote user) when low-risk and useful for attach defaults. Folder-uri open remains the **required** open path; nameConfig MUST NOT be the sole mechanism and MUST NOT cause lifecycle failure if the write fails.

#### Scenario: omitted workspaceFolder uses product default already resolved
- Given a config that omits `workspaceFolder` (or leaves it empty) so resolve yields the product default `/workspaces/<basename>`
- When the user runs `up` or `clone` with `--vscode` after successful lifecycle
- Then the open targets that already-resolved default folder (e.g. `/workspaces/<basename>`), not an empty path and not a re-parse of raw JSON that bypasses the resolver

#### Scenario: soft-fail when code CLI missing
- Given lifecycle would otherwise succeed and `--vscode` is set
- When no usable `code` executable is discoverable on the host
- Then the command still exits successfully for the lifecycle outcome
- And a stderr warning indicates that VS Code open was skipped or failed because `code` was not found
- And the managed container remains running / created as the lifecycle commanded

#### Scenario: soft-fail when launch fails
- Given lifecycle success, `--vscode` set, and a discoverable `code` that fails when invoked for open
- When open/launch returns failure
- Then the lifecycle command still reports success
- And a stderr warning indicates the open failure
- And the managed container is not deleted or stopped solely due to that failure

#### Scenario: explicit workspaceFolder is honored for open
- Given a config with an explicit resolved `workspaceFolder` (e.g. `/custom/ws`)
- When `up` or `clone` succeeds with `--vscode`
- Then the open targets `/custom/ws` (the resolved remote workspace folder), not the default `/workspaces/<basename>`

---

## MODIFIED Requirements

### Requirement: VS Code attach acceptance

MVP acceptance for editor integration is:

1. **Manual attach (unchanged core):** After `up` (and equivalently after `clone` / when a managed container is running), the container is running and listable/inspectable so the user can manually use experimental **Attach to Running Apple Container**. The CLI MUST NOT claim full Dev Containers extension parity and MUST NOT fail `up` (or `clone` / `start`) solely because VS Code did not auto-attach or because an optional open was not requested.

2. **Optional best-effort open (additive):** When the user passes `--vscode` on `up`, `start`, or `clone`, the CLI MUST attempt a best-effort open of a new VS Code window on the resolved remote workspace folder per **VS Code best-effort open**. Open failure MUST be soft (warn; lifecycle success preserved). Without `--vscode`, no automatic open is required.

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

## REMOVED Requirements

(none)
