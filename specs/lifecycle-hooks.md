# adevcontainer — Lifecycle Hooks Specification

## Purpose

Lifecycle hook surface for `onCreateCommand` through `postStartCommand` (string or argv forms, create-path order, reuse/start behavior, delete-on-fail). postAttach gating lives in [vscode.md](vscode.md); create-path matrices on `up` also appear in [core.md](core.md).

## Requirements

### Requirement: Lifecycle hook surface

The CLI MUST admit and honor these lifecycle properties in addition to existing `postCreateCommand`. Each property MUST accept a **string** or **argv array of strings** (same forms as core `postCreateCommand`). Omitted properties MUST be treated as no-ops. Hooks that run MUST execute via AppleContainerRuntime **exec** into the running container (not baked into the image), using the effective remote/container user and workspace folder when set.

| Property | Role |
|----------|------|
| `onCreateCommand` | Once on fresh create, before content/update and postCreate |
| `updateContentCommand` | On fresh create after `onCreateCommand` |
| `postCreateCommand` | On fresh create after `updateContentCommand` (core; kept) |
| `postStartCommand` | After the container is running on fresh create (after postCreate) and on start of a stopped container |
| `postAttachCommand` | Admitted; executed only after successful `--vscode` open (CLI attach hook); otherwise skipped with status when present (see postAttachCommand policy) |

#### Scenario: Fresh create runs full hook order
- Given a config with `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and `postStartCommand` each exiting 0
- When the user runs `up` and no container exists for the workspace
- Then the CLI runs hooks in order **onCreate → updateContent → postCreate → postStart** via exec and `up` succeeds

#### Scenario: Reuse running skips lifecycle
- Given a matching container already running (matching config hash)
- When the user runs `up` (no rebuild)
- Then no lifecycle hook is executed and `up` succeeds

#### Scenario: Start stopped runs postStart only
- Given a matching container that is stopped and a config with `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and `postStartCommand`
- When the user runs `up`
- Then only `postStartCommand` runs (onCreate, updateContent, and postCreate do not run) and `up` succeeds if postStart exits 0

#### Scenario: Create-path hook failure deletes container
- Given no existing container and a config whose `onCreateCommand` (or later create-path hook including first-create `postStartCommand`) exits non-zero
- When the user runs `up`
- Then `up` fails with a structured error naming the failing property and exit code, and the container MUST NOT remain for a later reuse as a healthy create

#### Scenario: Restart postStart failure does not delete container
- Given a stopped container from a prior successful create and a config whose `postStartCommand` exits non-zero
- When the user runs `up`
- Then `up` fails with a structured error for `postStartCommand` and the container still exists (MUST NOT be deleted solely due to restart postStart failure)

#### Scenario: Lifecycle command forms
- Given `postStartCommand` as a string and `onCreateCommand` as an argv array of strings
- When config is resolved
- Then both admit successfully and map to exec argv using the same shell-vs-argv rules as `postCreateCommand`

See also: [core.md](core.md) **Up lifecycle** for the create/reuse/start path matrix (including postAttach and vscode customizations rows); [vscode.md](vscode.md) for **postAttachCommand policy (CLI-only)**.

