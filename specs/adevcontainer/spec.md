# adevcontainer Specification

## Purpose

macOS developers need a native CLI that reads `devcontainer.json` and runs workspaces on Apple’s `container` stack. Upstream `@devcontainers/cli` is Node/Docker-oriented and is not a fit. This specification defines the durable outcome contract for a greenfield Swift CLI (`adevcontainer`): image-based workspaces with bind mounts, env/user/workspace folder, mounts and ports, lifecycle hooks (`onCreateCommand` through `postStartCommand`, plus admitted `postAttachCommand`), allowlisted `runArgs`, `hostRequirements` preflight with create limits, an OCI and local-path **Features runner** (derived image build on native arm64), plus lifecycle commands including `prune` and named-volume reuse on `up`.

## Requirements

### Requirement: Product identity and packaging

The product MUST be a greenfield Swift SPM executable named **`adevcontainer`**, package root at the repository root. It MUST target macOS 26+ Apple Silicon only. It MUST NOT require Node. It MUST NOT fork or wrap `@devcontainers/cli`. The sole external runtime dependency for users MUST be the Apple `container` CLI.

#### Scenario: Binary name and package layout
- Given a clean checkout of the repository
- When the Swift package is built
- Then the executable product is named `adevcontainer` and sources live under standard SPM layout (`Package.swift`, `Sources/`, `Tests/`)

#### Scenario: No Node dependency
- Given a host with Swift toolchain and Apple `container` only (no Node)
- When the user runs `adevcontainer doctor` and supported `up`/`exec` flows
- Then the CLI completes without invoking Node or `@devcontainers/cli`

---

### Requirement: Config discovery

The CLI MUST discover configuration by searching, in order, relative to the workspace root: (1) `.devcontainer/devcontainer.json`, (2) `.devcontainer.json`. The first existing file MUST win. If neither exists, the CLI MUST fail with a structured error identifying the paths searched.

#### Scenario: Prefer nested devcontainer path
- Given a workspace with both `.devcontainer/devcontainer.json` and `.devcontainer.json`
- When config is resolved for `up` or `inspect`
- Then the CLI uses `.devcontainer/devcontainer.json`

#### Scenario: Fallback to root file
- Given a workspace with only `.devcontainer.json`
- When config is resolved
- Then the CLI uses `.devcontainer.json`

#### Scenario: Missing config
- Given a workspace with neither config path
- When the user runs `adevcontainer up`
- Then the command fails with a structured error listing both candidate paths

---

### Requirement: JSONC configuration parsing

The CLI MUST parse `devcontainer.json` as JSONC (JSON with comments and, where standard JSONC allows, trailing commas as supported by the chosen parser policy). Real-world configs with `//` and `/* */` comments MUST parse successfully when otherwise valid.

#### Scenario: Comments in config
- Given a config file containing line and block comments and a valid `image` field
- When the config is parsed
- Then parsing succeeds and commented-out keys are not present in the resolved model

---

### Requirement: Variable substitution subset

After parse, the resolver MUST apply this substitution subset anywhere string values appear in supported properties:

| Token | Replacement |
|-------|-------------|
| `${localWorkspaceFolder}` | Absolute path of the workspace root |
| `${localWorkspaceFolderBasename}` | Basename of the workspace root |
| `${localEnv:VAR}` | Value of host environment variable `VAR` (empty string if unset, unless a default form is later specified) |
| `${containerWorkspaceFolder}` | Resolved container workspace folder path (after `workspaceFolder` resolution) |

Unsupported substitution tokens MUST cause a structured error naming the token. Substitution MUST run before runtime admission and mount/port mapping.

#### Scenario: localEnv in mount source
- Given `containerEnv` or a mount `source` containing `${localEnv:HOME}/.kube/config` and `HOME` is set on the host
- When config is resolved
- Then the token is replaced with the host value

#### Scenario: Unknown substitution token
- Given a string value containing `${unknownToken}`
- When config is resolved
- Then the CLI fails with a structured error naming `unknownToken`

---

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

The CLI MUST accept and honor the property surface below. Properties outside this surface that are forever-rejected or unknown-dangerous MUST hard-error (see Unsupported property policy). Benign editor metadata MAY be ignored per that policy.

**Image & workspace**
- `name` (optional; when non-empty after trim, drives the human base of deterministic container/image identity — see Deterministic identity and labels)
- `image` (required for image-based workspaces)
- Implicit workspace bind: host workspace root → container workspace folder

**Env & user**
- `containerEnv` (map of string → string, post-substitution)
- `remoteUser` and/or `containerUser` (non-root or named user when set)
- `workspaceFolder` (container cwd / remote workspace folder)

**Mounts & ports**
- `mounts` — bind and volume entries (string or object form consistent with devcontainers mount syntax subset)
- `forwardPorts` — published to the Apple container as port publish/mappings
- `portsAttributes` — retained and surfaced as metadata only (no IDE auto-forward semantics promised)

**Lifecycle**
- `postCreateCommand` — string or argv array; executed via runtime exec on fresh create after `updateContentCommand`; non-zero exit MUST fail `up`
- `onCreateCommand`, `updateContentCommand`, `postStartCommand`, `postAttachCommand` — policy per lifecycle hook surface and postAttachCommand policy requirements

**runArgs + hostRequirements**
- `runArgs` — allowlisted subset only; mapped on create
- `hostRequirements` — evaluated preflight (fail on capacity shortfall; map memory/cpus to create limits; fail on parse/unknown keys)

**Features**
- `features` — object map of OCI or local path feature ref → options; processed by the Features runner (see Features requirements)

#### Scenario: Minimal image config
- Given fixture `Tests/Fixtures/smoke.json` as the workspace config
- When the user runs a successful `up` then `exec`
- Then a container runs from the specified image with the workspace bound and an interactive or command exec succeeds

#### Scenario: Env user folder
- Given fixture `Tests/Fixtures/env-user.json`
- When `up` succeeds
- Then container env includes configured `containerEnv`, process user matches `remoteUser`/`containerUser` policy, and default cwd is `workspaceFolder`

#### Scenario: Mounts and ports
- Given fixture `Tests/Fixtures/mounts-ports.json`
- When `up` succeeds
- Then bind and volume mounts are applied, `forwardPorts` are published, and `portsAttributes` are available via `inspect` metadata without affecting publish success

#### Scenario: postCreate success
- Given fixture `Tests/Fixtures/lifecycle.json` with a `postCreateCommand` that exits 0
- When `up` runs
- Then postCreate runs via exec after the container is up and `up` reports success

#### Scenario: postCreate failure
- Given a config whose `postCreateCommand` exits non-zero
- When `up` runs
- Then `up` fails with a structured error including the exit code and MUST NOT report overall success

#### Scenario: Lifecycle / runArgs / hostRequirements property set does not hard-error as unknown
- Given a config that includes only core supported keys plus lifecycle hooks, allowlisted `runArgs`, and `hostRequirements`
- When config is validated
- Then validation does not fail with unsupported-property for those keys

#### Scenario: features is on the supported surface
- Given a config that includes only previously supported keys plus an OCI `features` map without forever-rejected entries
- When config is validated
- Then validation does not fail with unsupported-property for `features`

---

### Requirement: Unsupported property policy

The CLI MUST fail closed on unsupported or forever-rejected configuration. Errors MUST be structured and actionable: identify the property/flag, state that it is unsupported, and indicate what to remove or change. The CLI MUST NEVER silently ignore forever-rejected or unknown-dangerous entries.

**Forever reject (v1) — Features-aware**

- Feature refs containing `docker-outside-of-docker` / `docker-in-docker` / `docker-from-docker` (any registry/tag or local path)
- Feature metadata requiring `privileged: true` or `securityOpt` (or equivalent)
- `runArgs` containing `--privileged` or `--device…`
- `runArgs` entries not on the runArgs allowlist
- Docker Compose keys / compose-file driven multi-service config

**No longer reject**

- Non-ood OCI `features` entries solely for being features — they MUST enter the Features runner path
- Local path feature refs — they MUST enter the Features runner path (load from disk relative to workspace)

**May ignore or store as metadata (MUST NOT fail parse)**
- `customizations.vscode` (and nested extensions/settings)

**Not pure metadata (identity-affecting)**
- Optional `name` — when non-empty after trim, MUST drive the human base of container name and Features derived tag (see Deterministic identity and labels); MUST NOT fail parse

**No longer pure-ignore**
- `hostRequirements` — MUST evaluate per **hostRequirements preflight** (not silent ignore)

**Unknown non-metadata top-level properties**
- MUST hard-error (fail closed), except keys explicitly supported in core plus lifecycle hooks, allowlisted `runArgs`, `hostRequirements`, and **`features`**.

#### Scenario: Reject docker-outside-of-docker (policy retained)
- Given a config with `features` including a docker-outside-of-docker ref
- When config is validated
- Then the CLI fails with a structured error naming the feature and the reject policy

#### Scenario: Non-ood features no longer rejected as blanket-unsupported
- Given `features` with only `ghcr.io/devcontainers/features/node:1`
- When config is validated at admission
- Then the CLI does not fail with a blanket “features are not supported” error

#### Scenario: Reject privileged runArgs
- Given `runArgs` including `--privileged`
- When config is validated
- Then the CLI fails naming `--privileged`

#### Scenario: Reject device runArgs
- Given `runArgs` including `--device=/dev/net/tun:/dev/net/tun`
- When config is validated
- Then the CLI fails naming the device flag

#### Scenario: Reject Compose keys
- Given a config with `dockerComposeFile` set
- When config is validated
- Then the CLI fails indicating Compose is unsupported

#### Scenario: customizations.vscode does not fail
- Given a config that is otherwise a valid minimal image config and includes `customizations.vscode.extensions`
- When config is parsed and validated
- Then validation succeeds and `up` is not blocked solely by `customizations.vscode`

#### Scenario: Allowlisted cap-add no longer errors as unknown runArgs
- Given `runArgs` including only `--cap-add=NET_ADMIN` and `--init`
- When config is validated
- Then the CLI does **not** fail solely because those entries are present

#### Scenario: hostRequirements no longer silently ignored
- Given `hostRequirements` with valid `memory` below host capacity
- When the user runs `up`
- Then `up` fails with a structured hostRequirements error (observable preflight), not a silent no-op

---

### Requirement: Doctor preflight

`adevcontainer doctor` MUST verify host readiness before users rely on `up`: Apple `container` binary presence (default path `/usr/local/bin/container` or PATH resolution), invokability, and a reported version suitable for machine use. Doctor MUST emit a clear pass/fail summary. Doctor MUST NOT require a devcontainer.json.

#### Scenario: Doctor success
- Given Apple `container` is installed and runnable
- When the user runs `adevcontainer doctor`
- Then the command exits 0 and reports binary path and version

#### Scenario: Doctor missing binary
- Given `container` is not on PATH and not at the default path
- When the user runs `adevcontainer doctor`
- Then the command exits non-zero with a structured error explaining the missing runtime

---

### Requirement: Deterministic identity and labels

On create, the CLI MUST assign a deterministic container name and MUST set labels. Apple `container create --name` MUST equal the container id used for later inspect/exec/stop/delete.

**Human base**

1. If `devcontainer.json` `name` is present and non-empty after trim → sanitize that value.
2. Else → sanitize the workspace folder basename.

Sanitize MUST be DNS-safe: lowercase; replace each run of characters outside `[a-z0-9-]` with `-`; trim leading/trailing hyphens; clip the base to about 20 characters (same policy as the implementation).

**Container name**

- Format: `adev-{base}-{hash12}` where `hash12` is a 12-character hash of workspace path + config path (unchanged material).
- If the human base is empty after sanitize → `adev-{hash12}`.
- The full name MUST be ≤ 63 characters.

**Labels**

| Label | Purpose |
|-------|---------|
| `devcontainer.local_folder` | Absolute workspace path |
| `devcontainer.config_file` | Absolute config file path used |
| App config hash label (stable key, e.g. `devcontainer.config_hash`) | Hash of resolved supporting config for drift detection |

Discovery and reuse MUST prefer deterministic name + inspect, NOT Docker-style `ps --filter label=` as the primary mechanism.

When `features` is present, config hash material MUST include the selected feature refs, options, and ordered identity inputs. Changing features MUST change config hash so reuse and drift detection remain correct (recreate when features change).

`name` is not metadata-only: when set (non-empty after trim), it MUST drive the human base used for the container name and for Features derived image tags.

#### Scenario: Stable name across invocations
- Given the same workspace path and config content
- When `up` is invoked twice without delete
- Then the second invocation reuses the same container identity rather than creating a conflicting duplicate

#### Scenario: Container name uses config name when set
- Given a config with `"name": "My App"` and a workspace folder basename `other-folder`
- When the container name is computed
- Then the human base is derived from `My App` (sanitized), not from `other-folder`, and the name matches `adev-{base}-{hash12}` (or is clipped to ≤ 63 characters)

#### Scenario: Container name falls back to workspace basename
- Given a config with no `name` (or only whitespace)
- When the container name is computed
- Then the human base is the sanitized workspace folder basename and the name matches `adev-{base}-{hash12}` (empty base → `adev-{hash12}`)

#### Scenario: Labels present on inspect
- Given a container created by `up`
- When the user runs `adevcontainer inspect`
- Then local folder, config file, and config hash labels/fields are visible in the inspect output

#### Scenario: Features participate in identity hash
- Given two configs identical except for a feature option value
- When config hashes are computed
- Then the hashes differ

---

### Requirement: Up lifecycle (create, start, reuse)

`adevcontainer up` MUST resolve config, admit properties, and ensure a running workspace container: create if missing, start if stopped, reuse if already running with matching identity. Workspace bind MUST mount the host workspace into the container workspace folder. `up` MUST support a machine-readable JSON result on success (and structured failure otherwise).

**Success JSON fields (required)**
- `outcome` — success indicator consistent with reference CLI style (e.g. `"success"`)
- `containerId` — runtime container id
- `remoteUser` — effective remote/container user (may be empty/default if unset)
- `remoteWorkspaceFolder` — absolute path inside the container used as workspace folder

Additional helpful fields (e.g. `containerName`) MAY be included.

**Create image selection (Features-aware)**

On paths that create a new container (fresh create or recreate):

- **Before create**, if resolved `features` is non-empty: ensure **build.rosetta=false** (consent), then **resolve → fetch → order → contribution merge → Dockerfile generate → `container build`** (or reuse derived tag). Create uses the **derived image** with contributions merged and **`--platform`** host-native.
- Then start and lifecycle hooks (onCreate → updateContent → postCreate → postStart, etc.); feature-contributed hooks merge per the merge-feature-metadata requirement (installs are already in the derived image).
- If `features` is absent or empty: create uses config `image` as today (still with default platform); Features build path is not required.
- Reuse running / start stopped paths MUST NOT re-fetch/rebuild features unless product identity says config/features hash drift requires recreate (existing drift/recreate policy applies; features hash is part of config identity material when features present).

**Lifecycle hook matrix by path**

| Path | Lifecycle |
|------|-----------|
| Fresh create (missing or after recreate delete) | onCreate → updateContent → postCreate → postStart; delete container if any of these fail |
| Reuse running (matching identity, not recreate) | no hooks |
| Start stopped | postStart only; on failure fail `up`, do not delete container |
| Any path with `postAttachCommand` set | skip execute; one status line |

Create-path cleanup: if any create-path hook fails before `up` returns success, the CLI MUST delete the container before failing (extend core postCreate delete-on-fail to onCreate, updateContent, postCreate, and first-create postStart).

#### Scenario: Create then reuse
- Given no existing container for the workspace
- When the user runs `up` twice with the same config
- Then the first run creates and starts a container and prints success JSON including `containerId` and `remoteWorkspaceFolder`, and the second run reuses the running container without error

#### Scenario: Start stopped container
- Given a container previously created by `up` that is stopped
- When the user runs `up`
- Then the container is started and success JSON is emitted

#### Scenario: Up JSON shape
- Given a successful `up`
- When the machine-readable result is parsed
- Then it includes `outcome`, `containerId`, `remoteUser`, and `remoteWorkspaceFolder`

#### Scenario: Create then reuse still stable with hooks
- Given a successful fresh `up` with postStart configured
- When the user runs `up` again while the container is running
- Then the second run reuses without re-running onCreate/updateContent/postCreate/postStart

#### Scenario: Up with features builds then hooks
- Given fixture-equivalent config with OCI node feature
- When the user runs `up` (fresh create) with fetch/build available or mocked success
- Then resolve/fetch/build run before create, create uses the derived image, then lifecycle hooks

#### Scenario: Up without features unchanged image path
- Given a config with no `features` key
- When the user runs `up` fresh create
- Then create uses config `image` and the Features build path is not required

#### Scenario: Reuse running does not re-fetch features
- Given a matching container already running with features identity satisfied
- When the user runs `up` without recreate
- Then no feature fetch/build is required and lifecycle hooks are not re-run

---

### Requirement: Exec

`adevcontainer exec` MUST run a command or shell inside the running workspace container via AppleContainerRuntime. If the container is not running, exec MUST fail with a structured error suggesting `up`. Default working directory SHOULD be the remote workspace folder when set.

#### Scenario: Exec in running container
- Given a container started by `up`
- When the user runs `adevcontainer exec -- echo ok`
- Then the command runs in the container and exits with the remote process exit code

#### Scenario: Exec without running container
- Given no running container for the workspace
- When the user runs `exec`
- Then the CLI fails with a structured error indicating the container is not running

---

### Requirement: Stop and delete

`adevcontainer stop` MUST stop the workspace container if running. `adevcontainer delete` MUST remove the workspace container only (stopping first if required). Both MUST use deterministic identity resolution. Missing container MUST yield a clear structured error (or documented no-op policy applied consistently — prefer error for delete of unknown identity). `delete` MUST NOT remove named volumes or images.

#### Scenario: Stop running container
- Given a running container from `up`
- When the user runs `adevcontainer stop`
- Then the container is stopped and is no longer running

#### Scenario: Delete container
- Given an existing container from `up` (running or stopped)
- When the user runs `adevcontainer delete`
- Then the container no longer exists and named volumes from config still exist if they did before

---

### Requirement: Prune command

`adevcontainer prune` MUST remove the workspace container, named volumes listed in config `mounts` with `type=volume`, and the config `image` reference. It MUST NOT delete bind-mount host paths. It MUST NOT run global `volume prune` or `image prune`. Missing resources MUST be skipped. The command MUST exit non-zero only if deleting an existing resource fails. Identity resolution MUST match `delete`/`up` (deterministic name).

#### Scenario: Prune removes container, volumes, and image
- Given a workspace that has been `up`'d with at least one named volume mount and a config image
- When the user runs `adevcontainer prune`
- Then the workspace container is gone, each config named volume is removed, and the config image reference is removed

#### Scenario: Prune skips missing resources
- Given no workspace container and no matching named volumes
- When the user runs `adevcontainer prune`
- Then the command succeeds without erroring solely because resources were already absent

#### Scenario: Prune does not touch binds or global prune
- Given bind mounts in config pointing at host paths that exist
- When the user runs `adevcontainer prune`
- Then those host paths remain and no global volume/image prune is invoked

---

### Requirement: Named volume reuse on up

When ensuring named volumes during `up`, the runtime MUST list existing volumes first. If a named volume from config already exists, `up` MUST reuse it (status indicating already exists / reusing) and MUST NOT fail solely because the volume exists. If missing, `up` MUST create it, then mount it.

#### Scenario: Existing named volume is reused
- Given a config with a `type=volume` mount and that volume already exists on the host
- When the user runs `adevcontainer up`
- Then `up` succeeds, reuses the existing volume, and does not error solely due to volume existence

#### Scenario: Missing named volume is created
- Given a config with a `type=volume` mount and that volume does not exist
- When the user runs `adevcontainer up`
- Then the volume is created and mounted and `up` can succeed

---

### Requirement: Inspect

`adevcontainer inspect` MUST show resolved identity and state for the workspace container: name/id, running state, labels, effective remote user, remote workspace folder, and metadata such as `portsAttributes` when present. If no container exists, inspect MUST fail structurally or report not-found consistently.

#### Scenario: Inspect after up
- Given a successful `up`
- When the user runs `adevcontainer inspect`
- Then output includes container id/name, state, and workspace identity labels

---

### Requirement: AppleContainerRuntime boundary

All interaction with Apple `container` MUST go through a single **AppleContainerRuntime** module. No other module MAY shell out to `container`. The runtime MUST invoke the binary as a subprocess, prefer/require machine-readable JSON for parsed results, and MUST NOT scrape human TTY tables for control flow. Non-zero exits MUST map to structured CLI errors.

#### Scenario: Mockable runtime in tests
- Given unit tests for commands
- When tests run without a real Apple `container`
- Then commands can be exercised via a mock/fake process runner behind AppleContainerRuntime

---

### Requirement: VS Code attach acceptance

MVP acceptance for editor integration is: after `up`, the container is running and listable/inspectable so the user can manually use experimental **Attach to Running Apple Container**. The CLI MUST NOT claim full Dev Containers extension parity and MUST NOT fail `up` solely because VS Code did not auto-attach.

#### Scenario: Running container is attachable target
- Given a successful `up`
- When the user lists/inspects containers via the CLI
- Then the workspace container is identifiable for manual VS Code attach

---

### Requirement: Capability fixtures

The repository MUST provide pure JSON capability fixtures used by tests and docs:

| Path | Capability |
|------|------------|
| `Tests/Fixtures/smoke.json` | image + workspace bind |
| `Tests/Fixtures/env-user.json` | env, user, workspaceFolder |
| `Tests/Fixtures/mounts-ports.json` | mounts, forwardPorts, portsAttributes |
| `Tests/Fixtures/lifecycle.json` | postCreateCommand |
| `Tests/Fixtures/lifecycle-hooks.json` | lifecycle hooks |
| `Tests/Fixtures/runargs-host.json` | runArgs + hostRequirements |
| `Tests/Fixtures/features-node.json` | OCI Features runner (node only; no docker-ood) |
| `Tests/Fixtures/features-local.json` | Local path Features runner (sample-a + sample-b) |

Fixtures MUST be valid for their capability (no forever-rejected props). They SHOULD align field styles with `reference/devcontainer.json` where applicable (image family, env keys, mount shapes, ports) while remaining Apple-container-runnable. Existing core fixtures MUST remain valid under lifecycle / runArgs / hostRequirements / Features-aware admission (configs without `features` behave as today).

#### Scenario: Fixtures are parseable configs
- Given each file under `Tests/Fixtures/`
- When parsed with JSONC/JSON rules and validated against admission
- Then each fixture is admitted for its capability without unsupported-property errors

#### Scenario: All listed fixtures still admit for their capability
- Given each file under `Tests/Fixtures/` listed in the capability table including `features-node.json` and `features-local.json`
- When parsed and validated against admission
- Then each fixture is admitted for its capability without unexpected unsupported-property errors

---

### Requirement: Lifecycle hook surface

The CLI MUST admit and honor these lifecycle properties in addition to existing `postCreateCommand`. Each property MUST accept a **string** or **argv array of strings** (same forms as core `postCreateCommand`). Omitted properties MUST be treated as no-ops. Hooks that run MUST execute via AppleContainerRuntime **exec** into the running container (not baked into the image), using the effective remote/container user and workspace folder when set.

| Property | Role |
|----------|------|
| `onCreateCommand` | Once on fresh create, before content/update and postCreate |
| `updateContentCommand` | On fresh create after `onCreateCommand` |
| `postCreateCommand` | On fresh create after `updateContentCommand` (core; kept) |
| `postStartCommand` | After the container is running on fresh create (after postCreate) and on start of a stopped container |
| `postAttachCommand` | Admitted only; not executed on `up` (see postAttach policy) |

#### Scenario: Fresh create runs full hook order
- Given a config with `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, and `postStartCommand` each exiting 0
- When the user runs `up` and no container exists for the workspace
- Then the CLI runs hooks in order **onCreate → updateContent → postCreate → postStart** via exec and `up` succeeds

#### Scenario: Reuse running skips lifecycle
- Given a matching container already running
- When the user runs `up` without recreate
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

---

### Requirement: postAttachCommand policy (CLI-only)

The CLI MUST parse and admit `postAttachCommand` when present (string or argv array) so configs are not rejected solely for this property. The CLI MUST NOT execute `postAttachCommand` during `up`. On `up` paths where the property is present, the CLI MUST emit a single stderr status line indicating attach is not hooked (e.g. `postAttach skipped (no attach hook)`). Full IDE attach integration is out of scope. Presence of `postAttachCommand` MUST NOT fail `up` by itself.

#### Scenario: postAttach admitted but not run on up
- Given a valid minimal image config that also sets `postAttachCommand` to a command that would exit non-zero if run
- When the user runs `up` (fresh create)
- Then `up` succeeds without executing `postAttachCommand`, and stderr includes a one-time skip status for postAttach

#### Scenario: Invalid postAttach form still fails resolve
- Given `postAttachCommand` set to a non-string, non-array value
- When config is resolved
- Then the CLI fails with a structured error naming `postAttachCommand`

---

### Requirement: runArgs allowlist and create mapping

The CLI MUST admit `runArgs` only when every entry matches the runArgs allowlist. Empty `runArgs` (`[]`) or omitted `runArgs` MUST be accepted. Allowlisted entries MUST be mapped onto Apple `container create` argv via AppleContainerRuntime / `CreateRequest` (no other module invents `container` flags).

**Allowlist (exact shapes)**

Each valued flag accepts `=VALUE` or two-token (`FLAG` + next array element) form unless noted. Two-token values MUST NOT start with `-`.

| Shape | createTokens / notes |
|-------|----------------------|
| `--init` | `--init`; at most once (duplicates MAY collapse) |
| `--cap-add=NAME` / two-token | `--cap-add`, `NAME` |
| `--cap-drop=NAME` / two-token | `--cap-drop`, `NAME` |
| `--shm-size=SIZE` / two-token | `--shm-size`, `SIZE` |
| `--dns=IP` / two-token | `--dns`, `IP` |
| `--dns-search=VAL` / two-token | `--dns-search`, `VAL` |
| `--dns-option=VAL` / two-token | `--dns-option`, `VAL` |
| `--dns-domain=VAL` / two-token | `--dns-domain`, `VAL` |
| `--no-dns` | `--no-dns` |
| `--ulimit=type=soft[:hard]` / two-token | `--ulimit`, value |
| `--tmpfs=PATH` / two-token | `--tmpfs`, path; if value contains `:`, take path before first `:` only (Docker opts stripped) |
| `--cpus=N` / `-c` / two-token | **No** createTokens; merge into `cpuLimit` (see memory/CPU merge) |
| `--memory=SIZE` / `-m` / two-token | **No** createTokens; merge into `memoryLimit` (see memory/CPU merge) |
| `--network=NAME` / two-token | `--network`, `NAME`; **named only** — reject `host`, `bridge`, `none`, empty, `container:*` (case-insensitive) |
| `--rosetta` | `--rosetta` |
| `--ssh` | `--ssh` |
| `--read-only` | `--read-only` |

**Memory/CPU merge policy**

- `CreateRequest` already may set `memoryLimit`/`cpuLimit` from `hostRequirements`.
- If runArgs also supplies memory/cpus:
  - If hostRequirements set that dimension → **hostRequirements wins** (ignore runArgs for that dimension; MAY warn once on stderr)
  - If hostRequirements not set that dimension → apply runArgs value to `memoryLimit`/`cpuLimit` (normalize memory to Apple form when parseable)
- MUST NOT emit duplicate `-m`/`-c` from both runArgs createTokens and limits — memory/cpus MUST NOT contribute createTokens.

**Do NOT allow via runArgs** (prefer first-class config properties): `-e`/`--env`, `-u`/`--user`, `-w`/`--workdir`, `-p`/`--publish`, `-v`/`--volume`, `--mount`, `--name`, `--label`/`-l`, `-i`/`-t`/`-d`, `--rm`, `--entrypoint`.

**Forever reject (still hard-error)**

- `--privileged` and `--privileged=…`
- Any `--device`, `--device=…`, or `--device` + value token form
- `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime` (and `=…` / two-token forms)
- Network modes `host` / `bridge` / `none` / `container:*` / empty
- Any other flag or bare token not consumed by the allowlist rules above

Errors MUST name the offending `runArgs` entry and state allowlist or forever-reject policy.

#### Scenario: Allowlisted runArgs admit and map
- Given `runArgs`: `["--init", "--cap-add=NET_ADMIN", "--cap-add", "SYS_PTRACE", "--cap-drop=MKNOD"]`
- When config is resolved and a create request is built
- Then admission succeeds and create argv includes `--init` and the corresponding `--cap-add` / `--cap-drop` forms supported by the runtime mapper

#### Scenario: Wave A+B allowlisted flags admit and map
- Given `runArgs` including `--shm-size=64m`, `--dns=8.8.8.8`, `--tmpfs=/tmp:rw`, `--network=mynet`, `--rosetta`, `--ssh`, `--read-only`
- When config is resolved and a create request is built
- Then admission succeeds; create argv includes `--shm-size`/`64m`, `--dns`/`8.8.8.8`, `--tmpfs`/`/tmp` (opts stripped), `--network`/`mynet`, `--rosetta`, `--ssh`, `--read-only`

#### Scenario: runArgs memory/cpus merge
- Given no hostRequirements and `runArgs` `["--memory=2g", "--cpus", "2"]`
- When a create request is built
- Then create argv includes `-m`/`2G` (or equivalent) and `-c`/`2`, and does not also emit `--memory`/`--cpus` tokens
- Given hostRequirements memory/cpus set and runArgs also set memory/cpus
- When a create request is built
- Then hostRequirements values win for those dimensions

#### Scenario: Empty runArgs OK
- Given `"runArgs": []`
- When config is validated
- Then validation succeeds

#### Scenario: Reject privileged
- Given `runArgs` including `--privileged`
- When config is validated
- Then the CLI fails naming `--privileged`

#### Scenario: Reject device
- Given `runArgs` including `--device=/dev/net/tun:/dev/net/tun`
- When config is validated
- Then the CLI fails naming the device entry

#### Scenario: Reject network=host and Docker-only modes
- Given `runArgs` including `--network=host` (or bridge/none/container:*)
- When config is validated
- Then the CLI fails with a structured error rejecting that network mode

#### Scenario: Reject unknown flag
- Given `runArgs` including any non-allowlisted flag (e.g. `--not-a-real-flag`)
- When config is validated
- Then the CLI fails with a structured error naming that entry and stating it is not on the allowlist

#### Scenario: Reject dangling cap-add value
- Given `runArgs`: `["--cap-add"]` with no following name token
- When config is validated
- Then the CLI fails with a structured error for the incomplete `--cap-add` form

---

### Requirement: hostRequirements preflight and create limits

The CLI MUST evaluate `hostRequirements` during `up` preflight (not pure-ignore) **before** create/start/reuse paths. Supported keys:

| Key | Value | Behavior |
|-----|--------|----------|
| `memory` | String with size + unit: `gb`/`g`, `mb`/`m` (case-insensitive), e.g. `"8gb"`, `"8192mb"` | If host has enough: pass **requested** value to `container create` as `-m` / `--memory` (Apple suffixes `K,M,G,T,P`; e.g. `8gb` → `8G`). If host shortfall: **fail `up`** (do not create). |
| `cpus` | Number or numeric string (positive) | If host has enough: pass **requested** value to `container create` as `-c` / `--cpus`. If host shortfall: **fail `up`**. |
| `gpu` | Any present value | **Warn** that GPU requirements are unsupported; do **not** fail `up` solely for `gpu`; no create flags for gpu |

| Condition | Behavior |
|-----------|----------|
| Absent / empty `hostRequirements` | Do **not** pass `-m`/`-c`; Apple defaults |
| memory/cpus set AND host has capacity | Pass create limits; `up` may proceed |
| memory/cpus shortfall | **Fail `up`** with structured error naming the shortfall |
| Cannot read host memory/cpus when required | **Fail `up`** (cannot verify) |
| `gpu` only | Warn unsupported; does not fail alone; no create flags |

**Parse failures:** if `hostRequirements` is present but not an object, or a supported key has an unparseable value, or an **unknown** key appears inside the object, the CLI MUST **fail** with a structured error naming the property/field.

Host measurement source is implementation-defined but MUST be deterministic enough for tests to mock (e.g. injectable host info provider). Shortfall checks run on **every** `up`; create flags apply only on the create path (existing containers already carry limits).

Config hash material MUST include `hostRequirements` memory/cpus when set (limits affect create identity).

#### Scenario: Memory below requirement fails up
- Given `hostRequirements.memory` is `"8gb"` and the host reports less than 8 GiB
- When the user runs `up`
- Then `up` fails with a structured error naming `memory` / the requirement, and no container is created

#### Scenario: CPUs below requirement fails up
- Given `hostRequirements.cpus` is `4` and the host reports fewer than 4 CPUs
- When the user runs `up`
- Then `up` fails with a structured error naming `cpus`, and no container is created

#### Scenario: Enough host applies create limits
- Given `hostRequirements.memory` is `"8gb"` and `cpus` is `4` and the host meets both
- When the user runs `up` on a fresh create path
- Then create argv includes `-m`/`8G` (or equivalent) and `-c`/`4`, and `up` succeeds

#### Scenario: Absent hostRequirements omits create limits
- Given no `hostRequirements` key
- When a create request is built
- Then create argv does not include `-m` or `-c`

#### Scenario: Unparseable memory fails
- Given `hostRequirements.memory` is `"plenty"` (or another non-size string)
- When config is resolved
- Then the CLI fails with a structured error naming `hostRequirements.memory`

#### Scenario: Unknown hostRequirements key fails
- Given `hostRequirements` includes `"storage": "100gb"`
- When config is resolved
- Then the CLI fails with a structured error naming the unknown key

#### Scenario: GPU warns unsupported
- Given `hostRequirements.gpu` is present (e.g. `"optional"`) and memory/cpus are absent or satisfied
- When the user runs `up`
- Then stderr warns that GPU host requirements are unsupported and `up` is not failed solely for `gpu`

#### Scenario: Absent hostRequirements is no-op
- Given no `hostRequirements` key
- When config is resolved
- Then no hostRequirements error or warning is required

---

### Requirement: Lifecycle / runArgs / hostRequirements fixtures

The repository MUST provide pure JSON fixtures for lifecycle, runArgs, and hostRequirements surfaces:

| Path | Covers |
|------|--------|
| `Tests/Fixtures/lifecycle-hooks.json` | `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`; MAY include admitted `postAttachCommand` |
| `Tests/Fixtures/runargs-host.json` | Allowlisted `runArgs` and parseable `hostRequirements` (`memory` and/or `cpus`) |

Fixtures MUST NOT include forever-rejected props (no privileged/device, no features, no Compose). They SHOULD remain Apple-container-runnable for optional integration tests.

#### Scenario: Lifecycle / runArgs / hostRequirements fixtures admit
- Given each lifecycle / runArgs / hostRequirements fixture file
- When parsed and validated under admission rules
- Then admission succeeds without unsupported-property errors

---

### Requirement: Features object admission (OCI + local path)

The CLI MUST admit a top-level `features` property when it is an **object** (map). Each map key is a feature reference string; each value MUST be an object of option key → JSON value, or an empty object. A missing `features` key or empty object `{}` MUST be treated as no features (no-op for the runner).

**Supported reference forms (v1):**

1. **OCI** feature references resolvable over HTTP(S) registry APIs, including optional tag/version suffix, e.g. `ghcr.io/devcontainers/features/node:1`.
2. **Local path** feature keys: relative (`./…`, `../…`), absolute (`/…`), and `file://…` URIs. Relative paths resolve against the **workspace root**. The path MUST be a directory containing `devcontainer-feature.json` and `install.sh`; the package is copied into the feature cache. Missing directory / metadata / install script → structured error at fetch/load (not a silent skip).

Options object MAY supply feature options (e.g. `"version": "lts"`).

**Not supported (v1) — structured hard error:**

- Non-object `features` value (array, string, number, boolean).
- Non-object option values for a feature entry (unless the entry value is explicitly empty object).
- Forever-rejected docker-* feature markers (see forever-reject requirement) even when expressed as a local path.

Error messages MUST name the feature key (when applicable) and indicate supported OCI and/or local path forms.

Omitted `features` MUST NOT fail validation solely for absence.

**Hash material (v1):** local path refs participate via the path string (and options); content changes under the same path MAY NOT invalidate the derived tag until the path or options change — acceptable for v1.

#### Scenario: OCI feature ref with options admits
- Given a config with `"features": { "ghcr.io/devcontainers/features/node:1": { "version": "lts" } }` and a valid `image`
- When config is validated
- Then validation does not fail solely because `features` is present, and the resolved model carries the feature ref and options

#### Scenario: Empty features object is no-op
- Given `"features": {}`
- When config is validated and `up` runs without other features work
- Then admission succeeds and the Features runner performs no fetch/install

#### Scenario: Local path feature admits
- Given `"features": { "./.devcontainer/features/sample-a": { "greeting": "local" } }`
- When config is validated
- Then admission succeeds and the resolved model carries the local path ref and options

#### Scenario: Local path missing package fails at load
- Given an admitted local path whose directory (or `install.sh` / `devcontainer-feature.json`) is missing
- When features are fetched/loaded
- Then the CLI fails with a structured error naming the feature ref

#### Scenario: features must be an object
- Given `"features": ["ghcr.io/devcontainers/features/node:1"]`
- When config is validated
- Then the CLI fails with a structured error naming `features` and requiring an object map

---

### Requirement: Forever-reject docker-ood and privileged feature contributions

Independent of general Features support, the CLI MUST forever-reject:

1. **docker-outside-of-docker** — any feature reference whose id/path contains the segment or substring `docker-outside-of-docker` (case-sensitive match on the conventional id), regardless of registry host or tag (e.g. `ghcr.io/devcontainers/features/docker-outside-of-docker:1`, alternate registries, any version tag). Also forever-reject refs containing `docker-in-docker` or `docker-from-docker` (any registry/tag or local path).
2. **Privileged / securityOpt contributions** — after metadata resolve, any feature whose `devcontainer-feature.json` (or merged effective contribution) requires `privileged: true`, non-empty `securityOpt` / equivalent security-opt list, or an install posture that mandatorily needs them.
3. **Compose** — unchanged; Compose keys remain forever-rejected.

Errors MUST be structured and actionable: name the feature id, state the reject policy, and indicate what to remove. The CLI MUST NEVER silently skip docker-ood or privileged contributions.

#### Scenario: Reject docker-ood under any registry/tag
- Given `features` includes `ghcr.io/devcontainers/features/docker-outside-of-docker:1` (or another host/tag with `docker-outside-of-docker` in the ref)
- When config is validated (or at latest before fetch)
- Then the CLI fails with a structured error naming the feature and the forever-reject policy

#### Scenario: Reject privileged feature metadata
- Given an OCI feature whose resolved `devcontainer-feature.json` sets `privileged` to true (or requires `securityOpt`)
- When features are resolved for `up`
- Then the CLI fails with a structured error naming the feature and the privileged/securityOpt reject policy, and MUST NOT install features into a container for that set

#### Scenario: Non-ood feature is not rejected solely as features-unsupported
- Given only `ghcr.io/devcontainers/features/node:1` in `features` (no ood)
- When config is validated at the admission layer
- Then the CLI does **not** fail with the legacy “any features entry rejected / features runner post-MVP” policy

---

### Requirement: Feature metadata resolve and dependency order

For each admitted feature (OCI or local path), the runner MUST obtain and parse **`devcontainer-feature.json`** from the fetched/loaded feature package (standard Features metadata file at the package root or documented Features layout).

The runner MUST compute a simplified **correct install order** using:

- `dependsOn` (feature dependencies that must install first)
- `installsAfter` (ordering constraints relative to other selected features)

Dependency keys MUST match selected features by full ref, bare id, or last path segment (so `./x/sample-a` matches `dependsOn` of `…/sample-a:1`).

Direct declaration order in `devcontainer.json` MAY break ties when the Features spec leaves order unspecified. Cyclic dependencies MUST fail with a structured error naming the cycle participants.

Options from the config options object MUST be applied with standard Features option substitution into install environment / `install.sh` invocation as applicable (at minimum: export option values as environment variables consumed by `install.sh` per common Features practice).

#### Scenario: dependsOn orders install before dependent
- Given feature B `dependsOn` feature A, and both are selected
- When the runner computes install order
- Then A is ordered before B in the install plan

#### Scenario: dependsOn matches local path by feature id segment
- Given selected `./.devcontainer/features/sample-a` and `./.devcontainer/features/sample-b` where B `dependsOn` an OCI-style `…/sample-a:1`
- When the runner computes install order
- Then sample-a is ordered before sample-b

#### Scenario: installsAfter respected
- Given feature B declares `installsAfter` including feature A, and both are selected
- When the runner computes install order
- Then A is ordered before B

#### Scenario: Dependency cycle fails
- Given selected features form a dependsOn/installsAfter cycle
- When the runner resolves order
- Then the CLI fails with a structured error indicating a dependency cycle

#### Scenario: Missing devcontainer-feature.json fails
- Given a fetched artifact without parseable `devcontainer-feature.json`
- When metadata is resolved
- Then the CLI fails with a structured error naming the feature ref

---

### Requirement: Feature artifact fetch (OCI + local path)

The default fetcher MUST:

1. **Local path** refs → resolve relative to workspace root (or absolute/`file://`), validate package layout, and **copy** into the feature cache destination.
2. **OCI** refs → fetch feature content as **OCI artifacts** (feature layers/files), not as a plain application container image assumed runnable, via **HTTPS and/or registry API** logic **embedded in the product** (library code under `Sources/ADevContainerLib/`).

The product MUST NOT:

- Require users to install ORAS or another external feature-fetch CLI
- Assume Apple `container image pull` pulls feature artifacts correctly
- Invoke Node or `@devcontainers/cli` to fetch features

Fetch/load failures (missing local dir, missing install.sh/metadata, network, 401/403/404, malformed manifest) MUST surface as structured errors naming the feature ref and failure class. Unit tests MUST mock the OCI fetch boundary so the default suite needs no network; local path tests use fixtures under `Tests/Fixtures/features-sample/`.

#### Scenario: Fetch invokes embedded registry client not container pull for artifacts
- Given an admitted OCI feature ref
- When the runner fetches the feature
- Then fetch goes through the embedded Features fetch path (mockable), and tests can succeed without calling `container image pull` for the feature artifact

#### Scenario: Fetch 404 is structured failure
- Given a feature ref whose manifest does not exist
- When fetch runs
- Then `up` fails with a structured error naming the feature ref (and does not proceed to create/install)

#### Scenario: Unit tests mock fetch without network
- Given unit tests for the Features runner
- When the suite runs offline
- Then fetch is satisfied by a mock/fake and tests do not require live registry access

---

### Requirement: Derived image build (native arm64; no Rosetta)

When `features` is non-empty after admission, on a fresh create path the product MUST:

1. **Ensure native arm64 BuildKit** (see **build.rosetta consent** requirement) before fetch/build.
2. **Resolve + fetch** OCI feature artifacts (embedded client), compute install order, and collect runtime contributions (see other requirements).
3. **Pull** the config base image with **`--platform`** set to the host-native Linux platform:
   - `linux/arm64` when the host is arm64 / aarch64 (product default on Apple Silicon)
   - `linux/amd64` only when the host is x86_64
4. **Build** a derived image with Apple `container build` from a **generated Dockerfile** that `FROM`s the base image and `RUN`s each feature `install.sh` **as root** (options / `_REMOTE_USER` / `_CONTAINER_USER` env). Build argv MUST include the same host-native **`--platform`**.
5. **Tag** a deterministic local image as `adev-{base}:{hash12}`, where `base` is the same human base as container identity and `hash12` is a 12-character content hash of base image + features (unchanged material). If `base` is empty → `adevcontainer:{hash12}`. MUST NOT use an `adevcontainer/features:` prefix or a `/features` path segment. **Reuse** when that tag already exists locally (skip rebuild).
6. **Create** the workspace container **from the derived image** (not the raw config `image`) with the same **`--platform`**. Contributions that affect create flags (`init`, `capAdd`, env, mounts) MUST be merged **before** create.
7. **Start** the container, then run lifecycle hooks (onCreate → …) as today.

When `features` is absent or empty, create MUST continue to use the config `image` reference as written (no derived tag).

**MUST NOT** pass `--rosetta` on Features pull/build/create unless the user opted in via `runArgs`.

**MUST NOT** depend on Rosetta being installed: Features builds rely on `build.rosetta=false` (native arm64 BuildKit).

Reuse running / start stopped: MUST NOT re-fetch/rebuild features (already baked into the image on create). Config hash (including features) still drives recreate when features change.

#### Scenario: Create uses derived image after build
- Given a config with `image` and one OCI feature
- When the user runs `up` on a fresh create path (fetch/build available or mocked success)
- Then `container build` runs with `--platform linux/arm64` on arm64 hosts, create uses the derived tag `adev-{base}:{hash12}` (or `adevcontainer:{hash12}` when base is empty), and lifecycle hooks run after start

#### Scenario: Derived tag has no features path prefix
- Given a Features build with a non-empty human base
- When the derived image tag is computed
- Then the tag is `adev-{base}:{hash12}` and MUST NOT contain `adevcontainer/features` or a `/features` path segment

#### Scenario: Build and pull never pass --rosetta by default
- Given Features pull/build on the up path
- When argv is inspected
- Then neither pull nor build includes `--rosetta` unless the user opted in via runArgs

#### Scenario: Platform flag on pull, build, and create (arm64 host)
- Given host architecture arm64
- When pull, build, and create run for features
- Then argv includes `--platform linux/arm64` and does not include `--rosetta` unless the user opted in via runArgs

#### Scenario: Build failure does not create container
- Given `container build` exits non-zero
- When features build runs before create
- Then `up` fails with a structured feature-build error and no workspace container is created

#### Scenario: Reuse existing derived tag skips build
- Given the deterministic derived tag already exists locally
- When Features runner runs with the same base image + features identity
- Then no `container build` is invoked and create uses the existing tag

#### Scenario: Feature option change changes config identity
- Given the same feature ref but different options object
- When config hashes (and derived tags) are computed
- Then the hashes/tags differ (recreate path engages; no silent wrong-feature reuse)

---

### Requirement: build.rosetta consent (one-time, native arm64 BuildKit)

Before Features fetch/build on a create/recreate path, the product MUST ensure Apple container BuildKit is configured with **`build.rosetta=false`** so arm64 image builds do not require Rosetta ([apple/container#1825](https://github.com/apple/container/issues/1825)).

1. Read the **effective** value via `container system property list` (parse `[build]` / `rosetta`).
2. If already **`false`** → proceed **silently** (no prompt, no warning, no config write).
3. If **`true`** or **missing** (treat missing as default true for this gate):
   - On a TTY: print an English explanation and ask **once**:
     ```
     Apple container BuildKit is configured with build.rosetta=true, which requires
     Rosetta even for native arm64 image builds and can fail when Rosetta is unavailable.

     adevcontainer will set build.rosetta=false in <config-path>
     so feature image builds use native arm64 (closer to @devcontainers/cli behavior).

     Proceed? [Y/n]
     ```
   - Accept (empty / Y / yes): merge **only** `[build] rosetta = false` into the host Apple container config.toml (preserve all other keys/sections), restart the builder (`builder delete --force` / stop as needed; system stop+start **only if** the property still shows true after builder restart), emit `==> Configuring native arm64 builds (build.rosetta=false)` only when actually changing.
   - Decline: fail `up` with structured error `build_rosetta_config`; **do not** change config.
   - Non-interactive (no TTY / CI): fail with clear error unless env `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` auto-accepts without prompt.
4. **MUST NOT** restore `rosetta=true` later (user consented to leave it false).
5. **MUST NOT** install Rosetta.
6. Config path is the host Apple container config (typically `~/Library/Application Support/com.apple.container/config/config.toml`).

#### Scenario: Already false is silent
- Given effective `build.rosetta=false`
- When Features up create path starts
- Then no prompt and no config write

#### Scenario: User declines
- Given effective `build.rosetta=true` and interactive decline
- When Features up create path starts
- Then `up` fails with `build_rosetta_config` and config is unchanged

#### Scenario: Env auto-accept in CI
- Given non-interactive session and `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`
- When Features up needs to disable rosetta
- Then config is merged with `rosetta = false` without a prompt

---

### Requirement: Merge feature metadata into create and lifecycle

After features are resolved (and before create for flag contributions; lifecycle hooks from features run after start, with installs already baked into the derived image), the CLI MUST merge **runtime contributions** from feature metadata (and SHOULD merge from image `devcontainer.metadata` label when present) into the effective create/lifecycle request:

| Contribution | Merge behavior |
|--------------|----------------|
| `init` | Effective create includes `--init` (union with config `runArgs` `--init`) |
| `capAdd` | Each capability mapped via the existing **cap-add allowlist path**; disallowed names fail closed with structured error |
| `containerEnv` | Merged into effective env; **config `containerEnv` wins** on key conflict |
| mounts | Bind and volume only; sources normalized with **MountNormalizer** for file→dir promotion; incompatible mount types fail structured |
| lifecycle hooks contributed by features | Appended/merged into the create-path exec order after start (installs already in derived image); same string/argv forms and failure/delete-on-fail policy as config hooks for create-path failures |

Privileged / `securityOpt` contributions remain forever-rejected (see forever-reject requirement).

**SHOULD:** If the base or derived image inspect shows a `devcontainer.metadata` label with JSON metadata, parse and merge compatible fields into the effective model. Absence of the label MUST NOT fail `up`.

#### Scenario: Feature init merges to create --init
- Given feature metadata with `init: true` and config without `--init` in runArgs
- When create argv is built after feature resolve
- Then create includes `--init`

#### Scenario: Feature capAdd uses allowlist path
- Given feature metadata `capAdd: ["SYS_PTRACE"]`
- When create argv is built
- Then cap-add is applied through the same allowlisted mapping as runArgs cap-add

#### Scenario: Config containerEnv wins over feature env
- Given feature metadata `containerEnv.FOO=from-feature` and config `containerEnv.FOO=from-config`
- When effective env is computed
- Then `FOO` is `from-config`

#### Scenario: Feature lifecycle hooks run on fresh create via exec
- Given feature metadata contributing a post-create-style lifecycle command and a fresh create path
- When `up` succeeds through create
- Then the contributed hook runs via runtime exec after start (features already installed in the derived image), and non-zero exit fails `up` under create-path policy

#### Scenario: devcontainer.metadata label merge when present
- Given a base image with a parseable `devcontainer.metadata` label
- When features/metadata merge runs
- Then compatible fields are merged into the effective model and `up` is not failed solely because the label existed

#### Scenario: Missing devcontainer.metadata label is OK
- Given no `devcontainer.metadata` label on the image
- When `up` runs with features
- Then absence alone does not fail `up`

---

### Requirement: Features progress status lines

During Features work on `up`, the CLI MUST emit stderr progress status lines in the existing progress family (`==> …` / StatusPrinter), including at least:

- Resolving features
- Fetching feature \<ref or id\> (per feature or equivalent clear wording)
- Building features image \<tag\> (or Reusing features image \<tag\> when the tag exists)
- Configuring native arm64 builds (build.rosetta=false) — **only** when actually changing config

`ADEVCONTAINER_QUIET=1` MUST silence these status lines. Machine JSON on stdout MUST remain pure when `--json` (or equivalent) is used.

#### Scenario: Progress lines during feature up
- Given a features config and quiet mode unset
- When `up` runs the Features path (mocked fetch/build OK)
- Then stderr includes resolving/fetching/building (or reusing) status lines

#### Scenario: Quiet suppresses features progress
- Given `ADEVCONTAINER_QUIET=1`
- When `up` runs the Features path
- Then Features progress status lines are not printed

---

### Requirement: Features fixtures

The repository MUST provide:

| Path | Content |
|------|---------|
| `Tests/Fixtures/features-node.json` | Valid image-based config with **only** a non-ood OCI feature suitable for Node (e.g. `ghcr.io/devcontainers/features/node` with a pinned tag) and options if needed |
| `Tests/Fixtures/features-local.json` | Valid image-based config with local path features `./.devcontainer/features/sample-a` and `sample-b` (options as needed) |
| `Tests/Fixtures/features-sample/` | On-disk sample feature packages (`sample-a`, `sample-b`, `sample-privileged`) for unit + local E2E |

Fixtures MUST NOT include `docker-outside-of-docker`, privileged `runArgs`, device flags, or Compose keys (except `sample-privileged` metadata used only to assert forever-reject). OCI fixtures SHOULD remain usable for optional network integration tests. Local E2E copies `features-sample` into the temp workspace `.devcontainer/features/` before `up`.

#### Scenario: features-node fixture admits
- Given `Tests/Fixtures/features-node.json`
- When parsed and validated under Features admission rules (without requiring live fetch in pure admission tests)
- Then admission succeeds for the features object shape and does not hit docker-ood reject

#### Scenario: features-local fixture admits
- Given `Tests/Fixtures/features-local.json`
- When parsed and validated under Features admission rules
- Then admission succeeds for both local path keys

---

### Requirement: Features test strategy

- **Unit tests** MUST mock registry fetch and runtime `build` / image inspect / property list as needed; default `swift run adevcontainerTests` MUST pass without network and without requiring Rosetta installed. Local path load/order/privileged-reject tests use `features-sample` fixtures offline.
- **Integration tests** MAY exercise real OCI fetch + `container build` + `up` when network and Apple `container` are available; they MUST **skip** cleanly when network is unavailable or Apple `container` is missing. **Local path E2E** (`fixtureE2E_featuresLocal`) MUST run when Apple `container` is available **without** requiring `ADEVCONTAINER_FEATURES_E2E` or ghcr network (still uses rosetta-ensure env for non-interactive CI).
- Tests MUST NEVER require docker-ood or privileged features to succeed an install path.
- Features up-path tests MUST assert `container build` with host-native `--platform` and **no** `--rosetta` on the Features build path; create MUST use the derived image tag.

#### Scenario: Offline unit suite
- Given no network
- When `swift run adevcontainerTests` runs unit/command Features tests
- Then those tests pass via mocks and local fixtures

#### Scenario: Integration skips without network or runtime
- Given integration tests for OCI Features and no network or no Apple `container`
- When the integration section runs
- Then it skips without failing the suite solely for absence of network/runtime

#### Scenario: Local features E2E without ghcr gate
- Given Apple `container` available and local sample features copied into the workspace
- When `fixtureE2E_featuresLocal` runs
- Then `up` builds with sample-a then sample-b and smoke finds both in `/usr/local/etc/adev-features/installed.txt`
