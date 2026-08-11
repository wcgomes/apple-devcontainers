# adevcontainer — Core Specification

## Purpose

Core product identity, config discovery and admission, bind-mode identity and labels, `up` create/start/reuse lifecycle, AppleContainerRuntime boundary, and the capability fixture inventory. This is the foundation every other feature spec builds on.

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

The CLI MUST accept and honor the property surface below. Properties outside this surface that are forever-rejected or unknown-dangerous MUST hard-error (see Unsupported property policy). Parseable `customizations.vscode.extensions` / `settings` are **honored by apply**, not ignored, while still never failing parse solely for presence. Other benign editor metadata MAY be ignored per Unsupported property policy.

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

**Editor customizations (config-file, v1)**
- `customizations.vscode.extensions` — array of string extension IDs; retained and applied after successful `--vscode` open per apply requirements
- `customizations.vscode.settings` — JSON object; retained and merged into guest Machine settings on create-path (and repair on drift) per apply requirements
- Other `customizations` content remains admitted metadata and is not applied in v1

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

#### Scenario: property surface admits vscode extensions and settings
- Given a minimal image config that includes only well-formed `customizations.vscode.extensions` and `settings` beyond core image fields
- When config is resolved
- Then resolve succeeds and those fields are available to apply paths

See also: [lifecycle-hooks.md](lifecycle-hooks.md), [runargs-host.md](runargs-host.md), [features.md](features.md), [vscode.md](vscode.md) for detailed property behavior.

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
- Other benign editor metadata and other `customizations.*` namespaces that are not applied in v1 (MUST NOT fail parse). `customizations.vscode` is **no longer pure ignore** for apply purposes (see **No longer pure-ignore** below).

**Not pure metadata (identity-affecting)**
- Optional `name` — when non-empty after trim, MUST drive the human base of container name and Features derived tag (see Deterministic identity and labels); MUST NOT fail parse

**No longer pure-ignore**
- `hostRequirements` — MUST evaluate per **hostRequirements preflight** (not silent ignore)
- `customizations.vscode` — MUST still admit without failing parse when present as an object under object-shaped `customizations` (see existing scenario **customizations.vscode does not fail**). When nested `extensions` / `settings` are well-formed, the CLI MUST retain them and MUST apply per **Parse and retain customizations.vscode extensions and settings**, **Apply vscode settings on create-path (and repair on drift)**, **Apply vscode extensions after successful --vscode open**, and **Vscode customizations apply idempotency**. Malformed nested shapes soft-skip apply with warn rather than failing whole-config resolve when `customizations.vscode` is an object.

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

#### Scenario: parseable vscode customizations are applied per policy
- Given a valid config with well-formed `customizations.vscode.settings` and `extensions`
- When the user completes a fresh `up` create-path and later a successful `--vscode` open on a command that loads that config
- Then settings were attempted on create-path and extensions were attempted after open success per the apply requirements
- And apply soft-fail never fails lifecycle solely due to apply errors

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

On create, the CLI MUST assign a deterministic container name and MUST set labels. Apple `container create --name` MUST equal the container id used for later inspect/exec/stop/delete/start.

Sanitize MUST be DNS-safe: lowercase; replace each run of characters outside `[a-z0-9-]` with `-`; trim leading/trailing hyphens; clip the base to about 20 characters (same policy as the implementation).

When `features` is present, config hash material MUST include the selected feature refs, options, and ordered identity inputs. Changing features MUST change config hash so reuse and drift detection remain correct (recreate when features change).

`name` is not metadata-only: when set (non-empty after trim), it MUST drive the human base used for the container name and for Features derived image tags.

**Bind-mode (`up`) identity** MUST remain: `hash12` from workspace path + config path. On create, labels MUST include:

| Label | Requirement |
|-------|-------------|
| `devcontainer.managed` | MUST be `adevcontainer` |
| `devcontainer.workspace_mode` | MUST be `bind` |
| `devcontainer.local_folder` | Absolute host workspace path |
| `devcontainer.config_file` | Config path used |
| `devcontainer.config_hash` | Per existing drift/identity policy |
| `devcontainer.workspace_folder` | Container workspace folder |
| `devcontainer.remote_user` | Effective user or empty string |
| `devcontainer.config_volumes` | Comma-separated config `type=volume` sources when any; omit/empty otherwise |
| `devcontainer.git_url` / `devcontainer.workspace_volume` | MUST NOT be set (or empty; prune ignores missing ws vol) |

**Human base (bind-mode)**

1. If `devcontainer.json` `name` is present and non-empty after trim → sanitize that value.
2. Else → sanitize the workspace folder basename.

**Container name (bind-mode)**

- Format: `adev-{base}-{hash12}` where `hash12` is a 12-character hash of workspace path + config path.
- If the human base is empty after sanitize → `adev-{hash12}`.
- The full name MUST be ≤ 63 characters.

**Volume-mode (`clone`) identity** MUST use the volume-mode identity and labels requirements (git URL + config relative path; managed/volume labels; adapted `local_folder`). The two modes MUST NOT collide solely because a temp path string matches a host workspace path.

Discovery and reuse MUST prefer deterministic name + inspect, NOT Docker-style `ps --filter label=` as the primary mechanism. Discovery of managed containers for `list` / `start` / extended `stop` MUST filter client-side on `devcontainer.managed=adevcontainer` after machine JSON list (Apple `container` has no label filter API).

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

#### Scenario: Bind and volume modes distinct hash inputs
- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`
- When identities are computed
- Then the hash inputs differ (path+config vs git URL+config relpath) so container names are not required to match and MUST follow each mode’s rules

#### Scenario: Up create stamps managed bind labels
- Given a successful `up` create
- When labels are inspected
- Then `devcontainer.managed=adevcontainer`, `workspace_mode=bind`, local_folder/config_file/config_hash/workspace_folder/remote_user are set, and git_url/workspace_volume are absent

See also: [clone.md](clone.md) for volume-mode identity, workspace volume names, and volume-mode labels.

---

### Requirement: Up lifecycle (create, start, reuse)

`adevcontainer up` MUST resolve config, admit properties, and ensure a running workspace container: create if missing, start if stopped, reuse if already running with matching identity. Workspace bind MUST mount the host workspace into the container workspace folder. `up` MUST support a machine-readable JSON result on success (and structured failure otherwise).

**Success JSON fields (required)**
- `outcome` — success indicator consistent with reference CLI style (e.g. `"success"`)
- `containerId` — runtime container id
- `remoteUser` — effective remote/container user (may be empty/default if unset)
- `remoteWorkspaceFolder` — absolute path inside the container used as workspace folder

Additional helpful fields (e.g. `containerName`) MAY be included.

**Recreate/drift policy**

`up` reuses a running or stopped container with matching identity. When the config/features hash drifts (stamped `devcontainer.config_hash` ≠ resolved hash), `up` MUST fail closed with structured `config_hash_mismatch` and MUST NOT delete or recreate; the error hint MUST point to `adevcontainer rebuild` (managed selection: `--name` or auto when applicable). There is no `up --recreate` flag; unknown `--recreate` MUST fail as an unknown option (usage). Equal-hash force recreate and volume-preserving forced recreate are **only** via `rebuild`: an **explicit user-forced recreate** that MUST NOT require hash drift and MUST preserve volumes — it reads the current config, completes resolution/preflight/Features work first, deletes the old container **only** (container-only delete), and creates the new container reusing the existing workspace volume and config named volumes. Hard post-delete create/start/create-path failures offer mode-split recovery (bind host-editor; clone-origin volume helper); see change archive and product docs for recovery detail.

**Create image selection (Features-aware)**

On paths that create a new container (fresh create or `rebuild`):

- **Before create**, if resolved `features` is non-empty: ensure **build.rosetta=false** (consent), then **resolve → fetch → order → contribution merge → Dockerfile generate → `container build`** (or reuse derived tag). Create uses the **derived image** with contributions merged and **`--platform`** host-native.
- Then start and lifecycle hooks (onCreate → updateContent → postCreate → postStart, etc.); feature-contributed hooks merge per the merge-feature-metadata requirement (installs are already in the derived image).
- If `features` is absent or empty: create uses config `image` as today (still with default platform); Features build path is not required.
- Reuse running / start stopped paths MUST NOT re-fetch/rebuild features. Config hash (including features) still drives `config_hash_mismatch` on `up` when features change; force recreate is `rebuild` only.

**Lifecycle hook matrix by path**

| Path | Lifecycle |
|------|-----------|
| Fresh create (missing) | onCreate → updateContent → postCreate → postStart; delete container if any of these fail |
| `rebuild <name>` (forced recreate after container-only delete of the old container) | full fresh create-path onCreate → updateContent → postCreate → postStart on the **new** container; delete-on-fail applies to the **new** container; the old container was already removed (status warning on post-delete failure); a clone-origin volume failure in create/start/create-path hooks additionally offers the volume recovery session; a bind-mode failure in the same set offers the bind host-editor recovery session; non-clone volume targets retain warning-only behavior |
| Reuse running (matching identity) | no hooks |
| Start stopped | postStart only; on failure fail `up`, do not delete container |
| Any path with postAttach present and `--vscode` absent | skip execute; one status line (no attach hook) |
| Any path with postAttach present, `--vscode` set, open soft-failed/skipped | skip execute; SHOULD status that attach open did not succeed |
| Any path with postAttach present, `--vscode` set, open success | after open: run config then feature postAttach via exec; on failure fail command, keep container |
| Any path with postAttach absent | no postAttach skip line; no postAttach exec |

postAttach gating applies on `up`, `start`, `clone`, and `rebuild` after the command’s own prior lifecycle steps succeed and (when `--vscode`) after the open attempt outcome is known. postAttach is **not** part of create-path delete-on-fail. Settings/open soft-fail and postAttach failure MUST NOT enter either recovery session.

| Path | Vscode customizations apply |
|------|-----------------------------|
| Fresh create-path `up`/`clone`/`rebuild` with well-formed settings | after create-path hooks: settings merge (soft-fail); marker/idempotency rules |
| Fresh create-path without settings (and no pending payload) | no settings apply required |
| Any path with well-formed extensions, `--vscode` absent | extensions not installed by CLI on that invocation |
| Any path with well-formed extensions, `--vscode` set, open soft-failed/skipped | extensions not installed on that invocation |
| Any path with well-formed extensions, `--vscode` set, open success, marker pending/drift | after open: extensions install (soft-fail), then postAttach per existing matrix |
| Any path with matching marker for full normalized payload | skip redundant settings+extensions apply |
| `start` / reuse with loadable config and marker drift | settings repair when applicable; extensions only if open success and still pending |

postAttach matrix rows and gating text above remain in force. Customizations apply is **not** part of create-path delete-on-fail and **not** folded into postAttach execution.

Create-path cleanup: if any create-path hook fails before `up` returns success, the CLI MUST delete the container before failing (extend core postCreate delete-on-fail to onCreate, updateContent, postCreate, and first-create postStart). On `rebuild`, delete-on-fail applies to the **new** container only (workspace/config volumes preserved); eligible hard post-delete failures then offer mode-split recovery.

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
- When the user runs `up` (matching hash, no rebuild)
- Then no feature fetch/build is required and lifecycle hooks are not re-run

#### Scenario: up hash mismatch hints rebuild
- Given a managed bind-mode container whose stamped `devcontainer.config_hash` does not match the resolved config hash
- When the user runs `adevcontainer up` for that workspace
- Then the CLI fails with `config_hash_mismatch` and does not delete the container
- And the error hint mentions `adevcontainer rebuild` and managed selection (`--name` or auto)
- And the hint does not mention `--recreate`

#### Scenario: up --recreate is unknown flag
- Given any `up` (or other) invocation that includes `--recreate`
- When the CLI parses global options
- Then the CLI fails with a structured **usage** error for unknown option `--recreate` (fail closed; no recreate path)

#### Scenario: rebuild hook matrix row applies
- Given a managed container being rebuilt with a config carrying all four create-path hooks
- When `rebuild` runs the fresh create-path on the new container
- Then onCreate → updateContent → postCreate → postStart execute in order on the new container, and a first-hook failure deletes only the new container

#### Scenario: rebuild does not require hash drift
- Given a managed container whose current config hash equals the stamped hash
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then rebuild recreates the container (no hash-mismatch precondition), unlike `up` reuse which would have kept the running container

See also: [lifecycle-hooks.md](lifecycle-hooks.md) for hook surface details; [vscode.md](vscode.md) for postAttach and vscode customizations apply gating; [features.md](features.md) for Features create-path build; [managed-lifecycle.md](managed-lifecycle.md) for rebuild selection.

---

### Requirement: AppleContainerRuntime boundary

All interaction with Apple `container` MUST go through a single **AppleContainerRuntime** module. No other module MAY shell out to `container`. The runtime MUST invoke the binary as a subprocess, prefer/require machine-readable JSON for parsed results, and MUST NOT scrape human TTY tables for control flow. Non-zero exits MUST map to structured CLI errors.

#### Scenario: Mockable runtime in tests
- Given unit tests for commands
- When tests run without a real Apple `container`
- Then commands can be exercised via a mock/fake process runner behind AppleContainerRuntime

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

See also: [runargs-host.md](runargs-host.md), [features.md](features.md), and [lifecycle-hooks.md](lifecycle-hooks.md) for domain-specific fixture requirements that reference this inventory.

