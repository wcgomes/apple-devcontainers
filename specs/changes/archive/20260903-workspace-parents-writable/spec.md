# Change Spec: workspace-parents-writable

Status: Active. Branch: `workspace-parents-writable`. Applies to: all releases.

## ADDED Requirements

### Requirement: Workspace parent directories writable on create paths

On the managed create paths — `up` fresh create (bind mode), `clone` (volume mode), and `rebuild` replacement create (bind and volume mode) — the CLI MUST make the container-rootfs parent directories of the resolved container workspace folder writable by the resolved remote connection user before any create-path lifecycle hook (onCreateCommand, updateContentCommand, postCreateCommand, postStartCommand) runs: it MUST create the workspace folder path with `mkdir -p` as needed, then non-recursively `chown` each ancestor directory from the workspace folder's parent upward to the connection user (or `user:user` when a group of that name exists), stopping at the system-top break list — `/`, `/home`, `/Users`, `/var`, `/usr`, `/opt`, `/tmp`, `/root`, `/etc`, `/mnt`, `/media`, `/dev`, `/proc`, `/sys`, `/run`, `/boot`, `/lib`, `/lib64`, `/bin`, `/sbin` — and it MUST NOT chown any break-list entry.

The workspace folder itself MUST be chowned only in volume mode, under the existing recursive workspace-folder chown semantics (clone: always after start; rebuild: only when the resolved connection user differs from the stamped `devcontainer.remote_user`). In bind mode the workspace folder is the host bind target and MUST NEVER be chowned on any path, including by the parent fix-up. On `clone` the parent outcome is already achieved by the existing workspace-folder chown's parent walk, so the CLI MUST NOT add a second fix-up mechanism on `clone`; regression coverage MUST prove the parent outcome is delivered.

When the resolved connection user is empty or the literal `root`, the CLI MUST NOT run any parent fix-up exec. The parent fix-up MUST NOT run on non-create paths: `up` reuse of a running matching container, `up` start-stopped, and bare `start` MUST NOT chown workspace parents.

#### Scenario: up bind fresh create fixes parents before hooks

- Given a bind-mode `up` fresh create with a non-root connection user `alice` and workspace folder `/workspaces/project`
- When container create and start succeed and create-path hooks are about to run
- Then before any hook exec the CLI runs a single root exec whose script contains `mkdir -p` for the workspace folder path and non-recursive `chown` of `/workspaces` (and any other ancestors up to the break list) to `alice`, no `chown -R`, and no `chown` of the workspace folder itself, and a `postCreateCommand` that creates a sibling directory under `/workspaces` succeeds

#### Scenario: up bind never chowns the host bind target

- Given a bind-mode `up` fresh create with a non-root connection user
- When the create path runs
- Then no exec on the create path contains `chown -R` of the workspace folder and no exec chowns the workspace folder path itself (parents only)

#### Scenario: clone achieves parents via the existing workspace chown (regression)

- Given a volume-mode `clone` create with a non-root connection user and workspace folder `/workspaces/repo`
- When the existing workspace-folder chown runs after start and before populate
- Then its single script non-recursively chowns `/workspaces` as a parent of the recursively chowned `/workspaces/repo`, making parents writable before create-path hooks, and no second parent fix-up exec runs on `clone`

#### Scenario: rebuild bind fixes parents before hooks and never chowns the target

- Given a bind-mode managed container rebuilt with a non-root connection user
- When the rebuild create path runs after start and before create-path hooks
- Then a parents-only exec runs (the workspace folder itself is never chowned) and create-path hooks observe writable parents

#### Scenario: rebuild volume fixes parents even when the connection user is unchanged

- Given a volume-mode rebuild where the resolved connection user equals the stamped `devcontainer.remote_user`
- When the rebuild create path runs
- Then the recursive workspace-folder chown is NOT invoked (the volume data tree is left as is) and a parents-only exec still runs against the new container's rootfs before create-path hooks

#### Scenario: root or unset connection user is a no-op

- Given a bind-mode `up` fresh create whose resolved connection user is `root` (or unset)
- When create and start succeed
- Then no parent fix-up exec runs

#### Scenario: nested workspaceFolder creates intermediates and stops at the break list

- Given a workspace folder `/workspaces/a/b/c` whose intermediate directories do not exist in the container rootfs
- When the parent fix-up runs
- Then `mkdir -p` creates the chain, non-recursive `chown` applies to `/workspaces/a/b`, `/workspaces/a`, and `/workspaces`, and neither `/` nor any break-list entry is chowned

#### Scenario: break-list stop under home

- Given a workspace folder `/home/alice/ws`
- When the parent fix-up runs
- Then `/home/alice` is chowned and `/home` is not

#### Scenario: workspace folder directly under a break-list entry has nothing to chown

- Given a workspace folder `/opt/tool` (or `/tmp/x`)
- When the parent fix-up runs
- Then the walk stops at the break-list entry, no ancestor is chowned, and the fix-up does not fail

#### Scenario: up reuse and start-stopped do not run the parent fix-up

- Given a matching running or stopped bind-mode container
- When `up` reuses the running container or starts the stopped one
- Then no parent fix-up exec runs

### Requirement: Parent fix-up failure semantics

Failure of the parent fix-up MUST follow the per-command create-path ownership semantics:

- `up` fresh create: fix-up failure MUST fail `up` with a structured error, MUST delete the created container, and MUST remain eligible for bring-up recovery (the realized `workspace-ownership` recovery trigger).
- `rebuild` (both modes): fix-up failure MUST be a soft-fail — warn on stderr and continue the create path; it MUST NOT delete the new container and MUST NOT enter bring-up recovery.
- `clone` (volume): no new mechanism; the existing workspace-folder chown failure semantics are unchanged.

#### Scenario: up parent fix-up failure deletes and stays recovery-eligible

- Given a bind-mode `up` fresh create whose parent fix-up exec fails
- When the failure is observed
- Then `up` fails with a structured error, the created container is deleted, and the failure is eligible for bring-up recovery

#### Scenario: rebuild parent fix-up failure warns and continues

- Given a `rebuild` (bind or volume) whose parent fix-up exec fails
- When the failure is observed
- Then stderr carries a warning, the rebuild continues through create-path hooks and succeeds absent other failures, and the new container is not deleted

#### Scenario: clone parent outcome failure keeps existing throwing semantics (regression)

- Given a volume-mode `clone` whose workspace-folder chown fails
- When clone runs
- Then clone fails with a structured error, deletes the managed container and the `*-ws` workspace volume, and remains eligible for bring-up recovery (unchanged)
