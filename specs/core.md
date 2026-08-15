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
| `${devcontainerId}` | Managed container name used at create (`adev-{base}-{hash12}` / create `--name`). Same identity for bind-mode `up` and volume-mode `clone`/`rebuild` (reused name). |

Unsupported substitution tokens MUST cause a structured error naming the token. Substitution MUST run before runtime admission and mount/port mapping.

**`${devcontainerId}` lifecycle — MUST**

- Feature metadata mounts (and config mounts) MAY embed `${devcontainerId}` in volume `source` (e.g. shell-history `source=${devcontainerId}-shellhistory`).
- When the create name is not yet known at config resolve (common for feature mounts; clone volume-mode name differs from bind-mode path identity), the token MAY remain unsubstituted through resolve.
- Before named-volume ensure and `container create`, the CLI MUST expand `${devcontainerId}` to the create `--name` value so Apple volume names match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`.
- Volume-mode config hash / `devcontainer.config_volumes` labels MUST use post-expansion mount sources so identity stays stable and purge sees real volume names.

#### Scenario: localEnv in mount source
- Given `containerEnv` or a mount `source` containing `${localEnv:HOME}/.kube/config` and `HOME` is set on the host
- When config is resolved
- Then the token is replaced with the host value

#### Scenario: devcontainerId in feature volume mount source
- Given a feature mount `source=${devcontainerId}-shellhistory` (type volume) and create name `adev-proj-abc123def456`
- When the container is created
- Then the volume name is `adev-proj-abc123def456-shellhistory` and volume create succeeds

#### Scenario: Unknown substitution token
- Given a string value containing `${unknownToken}`
- When config is resolved
- Then the CLI fails with a structured error naming `unknownToken`

---

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

The CLI MUST accept and honor the property surface below. Properties outside this surface that are hard-error (Compose, unknown-dangerous) or unknown-dangerous MUST hard-error (see Unsupported property policy). Known optional Apple-incompatibles are warn-skip, not hard-error. Parseable `customizations.vscode.extensions` / `settings` are **honored by apply**, not ignored, while still never failing parse solely for presence. Other benign editor metadata MAY be ignored per Unsupported property policy.

**Image & workspace**
- `name` (optional; when non-empty after trim, drives the human base of deterministic container/image identity — see Deterministic identity and labels)
- `image` (required for image-based dev containers)
- Implicit workspace bind: host workspace root → container workspace folder

**Env & user**
- `containerEnv` (map of string → string, post-substitution)
- `remoteUser` — remote connection / exec / attach user when set (feeds the **Remote connection user resolution** chain; also create `-u` when `containerUser` is unset and the value is non-root — see **Create process user**)
- `containerUser` — explicit container create process user when set (wins create `-u` over connection user)
- When both are set, create process user is `containerUser` and remote connection user is `remoteUser`
- When only one is set, that value participates in the chain per **Remote connection user resolution** and **Create process user**
- `workspaceFolder` (container cwd / remote workspace folder)

**Mounts & ports**
- `mounts` — bind and volume entries (string or object form consistent with devcontainers mount syntax subset)
- `forwardPorts` — published to the Apple container as port publish/mappings
- `portsAttributes` — retained and surfaced as metadata only (no IDE auto-forward semantics promised)

**Lifecycle**
- `initializeCommand` — string, argv array, or object map; host command per [lifecycle-hooks.md](lifecycle-hooks.md) **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and [vscode.md](vscode.md) **postAttachCommand policy (CLI-only)**
- `waitFor` — enum; default `updateContentCommand`; policy per **waitFor readiness**
- `userEnvProbe` — enum; default `loginInteractiveShell`; policy per **userEnvProbe merge**
- `shutdownAction` — enum; default `stopContainer` for this image/Dockerfile product; `stopCompose` fails closed; policy per **shutdownAction admission**

**runArgs + hostRequirements**
- `runArgs` — allowlisted subset only; mapped on create
- `hostRequirements` — evaluated preflight (fail on capacity shortfall; map memory/cpus to create limits; fail on parse/unknown keys)

**Features**
- `features` — object map of OCI or local path feature ref → options; processed by the Features runner (see Features requirements)

**Editor customizations (config-file, v1)**
- `customizations.vscode.extensions` — array of string extension IDs; retained and applied when `--vscode` is set (before open; not gated on open success) per apply requirements
- `customizations.vscode.settings` — JSON object; retained and merged into guest Machine settings on create-path (and repair on drift) per apply requirements
- Other `customizations` content remains admitted metadata and is not applied in v1

#### Scenario: Minimal image config
- Given fixture `Tests/Fixtures/smoke.json` as the workspace config
- When the user runs a successful `up` then `exec`
- Then a container runs from the specified image with the workspace bound and an interactive or command exec succeeds

#### Scenario: Env user folder (connection vs create)
- Given fixture `Tests/Fixtures/env-user.json` (`remoteUser` and `containerUser` both `vscode`)
- When `up` succeeds
- Then container env includes configured `containerEnv`, create uses `-u vscode`, default cwd is `workspaceFolder`, and stamped `devcontainer.remote_user` / success-JSON `remoteUser` are `vscode`

#### Scenario: remoteUser without containerUser sets create -u
- Given a config with only `remoteUser` `alice` (no `containerUser`)
- When `up` succeeds
- Then create includes `-u` `alice`, `devcontainer.remote_user` is `alice`, and `exec` runs as `alice`

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
- Given a config that includes only core supported keys plus the lifecycle properties in this requirement, allowlisted `runArgs`, and `hostRequirements`
- When config is validated
- Then validation does not fail with unsupported-property for those keys

#### Scenario: initializeCommand waitFor userEnvProbe shutdownAction admit
- Given a minimal image config that also sets valid `initializeCommand`, `waitFor`, `userEnvProbe`, and `shutdownAction` `stopContainer`
- When config is resolved
- Then resolve succeeds and those fields are available to lifecycle paths

#### Scenario: features is on the supported surface
- Given a config that includes only previously supported keys plus an OCI `features` map without warn-skipped docker-* markers
- When config is validated
- Then validation does not fail with unsupported-property for `features`

#### Scenario: property surface admits vscode extensions and settings
- Given a minimal image config that includes only well-formed `customizations.vscode.extensions` and `settings` beyond core image fields
- When config is resolved
- Then resolve succeeds and those fields are available to apply paths

See also: [lifecycle-hooks.md](lifecycle-hooks.md), [runargs-host.md](runargs-host.md), [features.md](features.md), [vscode.md](vscode.md) for detailed property behavior; **Remote connection user resolution** and **Create process user** below for user chain and create `-u`.

---

### Requirement: Remote connection user resolution

The product MUST resolve a **remote connection user** for every managed create path (`up`, `clone`, `rebuild`) and MUST use that value for connection-oriented consumers (labels, `exec`, lifecycle hook exec, VS Code nameConfig / customizations / postAttach, and success-JSON `remoteUser`).

**Precedence (MUST, first non-empty after trim wins):**

1. Config `remoteUser` when non-empty after trim (local `devcontainer.json`)
2. Else config `containerUser` when non-empty after trim (local)
3. Else image label `devcontainer.metadata` `remoteUser` when non-empty after trim (see **Image metadata users** below)
4. Else image label `devcontainer.metadata` `containerUser` when non-empty after trim
5. Else the **final OCI image `USER`** of the image that will run the managed dev container (config base image when Features are absent; **derived** image when Features produce one), obtained from runtime image inspect
6. Else the literal `root`

Local config wins when set: steps 1–2 always beat metadata. Create process user follows **Create process user** below (explicit `containerUser`, else non-root connection user — so metadata `remoteUser` such as `vscode` becomes create `-u` when local `containerUser` is unset).

**Image metadata users (MUST):**

- When present, the image label `devcontainer.metadata` (JSON object or array of fragment objects) MUST contribute `remoteUser` / `containerUser` into the connection-user chain above.
- Across an array of fragments, **last non-empty after trim wins** per field.
- Absence or unparseable metadata MUST be treated as no metadata users (never fails resolution alone).
- On Features paths, metadata MUST be read from the **base** image (derived tags may not carry the base label).

**Inspect failure (MUST NOT invent root at the OCI tier):**

- When steps 1–4 do not yield a user, the product MUST obtain OCI `USER` via image inspect.
- If image inspect **fails** (runtime error, unparseable payload, or missing inspect path) while steps 1–4 are empty, the product MUST fail the create path with a structured error naming image inspect / user resolution — it MUST **not** treat inspect failure as “OCI USER is `root`” and MUST **not** silently fall through to `root` solely because inspect failed.
- When inspect **succeeds** and the image has no usable `USER` (absent, empty, or whitespace-only), the product MUST continue to step 6 (`root`).

**No hardcoded product usernames (MUST):**

- Resolution MUST NOT hardcode editor-oriented names (e.g. `vscode`) or any other fixed username outside the precedence chain above.
- The terminal `root` fallback is only step 6 after a **successful** empty-USER inspect (or after an explicit non-empty config value of `root`).

**Create vs connection (MUST):**

- Create process user is governed by **Create process user** below. Connection user still drives labels/exec/nameConfig/VS Code; when both keys are set, create uses `containerUser` and connection uses `remoteUser`.

#### Scenario: remoteUser wins over containerUser and OCI USER
- Given a config with `remoteUser` `alice`, `containerUser` `bob`, and an image whose OCI `USER` is `carol`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `alice`

#### Scenario: containerUser used when remoteUser unset
- Given a config with no `remoteUser` (or empty), `containerUser` `bob`, and any OCI `USER`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `bob`

#### Scenario: OCI USER used when both config keys unset
- Given a config with neither `remoteUser` nor `containerUser` set (or both empty), and image inspect returns OCI `USER` `node`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `node`

#### Scenario: root only after successful empty OCI USER
- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect **succeeds** with no usable `USER`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `root`

#### Scenario: inspect failure does not become root
- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect **fails**
- When create runs
- Then the command fails with a structured user-resolution / image-inspect error
- And the product MUST NOT stamp `devcontainer.remote_user=root` solely due to that failure
- And no managed container is left created from that failed resolution

#### Scenario: no hardcoded vscode default
- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect succeeds with OCI `USER` `app`
- When remote connection user is resolved
- Then the result is `app` and MUST NOT be replaced by `vscode` or any other hardcoded product username

#### Scenario: metadata remoteUser when config users empty
- Given a config with neither `remoteUser` nor `containerUser` set, image OCI `USER` `root`, and image `devcontainer.metadata` `{"remoteUser":"vscode"}`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `vscode`
- And create MUST include `-u` `vscode` (non-root connection user; Apple attach uses container default user)

#### Scenario: local config wins over metadata remoteUser
- Given a config with `remoteUser` `alice` and image metadata `remoteUser` `vscode`
- When remote connection user is resolved
- Then the result is `alice`

#### Scenario: metadata array last non-empty wins
- Given image `devcontainer.metadata` is an array of fragments with successive `remoteUser` values
- When metadata users are parsed
- Then the last non-empty `remoteUser` fragment wins

---

### Requirement: Create process user

On managed create (`up`, `clone`, `rebuild`), the product MUST set create `-u` as follows (first match wins):

1. When config `containerUser` is non-empty after trim → create MUST include `-u <containerUser>` (post-substitution value).
2. Else when the **resolved remote connection user** is non-empty after trim and is **not** the literal `root` → create MUST include `-u <connectionUser>`.
3. Else create MUST **omit** `-u` (connection user is `root` or empty; image default applies).

Rationale (Apple-first): Apple Remote Containers attach does **not** pass exec `-u`; the integrated terminal uses the container’s default (create) user. nameConfig `remoteUser` alone does not change the terminal user. Applying the non-root connection user at create keeps VS Code terminal aligned with `remoteUser` / metadata `vscode` without requiring local `containerUser`.

Connection/exec/nameConfig/VS Code consumers continue to use the connection-user chain unchanged. When `remoteUser` is `alice` and `containerUser` is `bob`, create is still `-u bob` and connection remains `alice`.

#### Scenario: create -u from remoteUser when containerUser unset
- Given a config with `remoteUser` `alice` and no `containerUser`
- When create argv is built
- Then create MUST include `-u` `alice`
- And the stamped remote connection user for labels/exec remains `alice`

#### Scenario: create -u when containerUser set
- Given a config with `containerUser` `bob` (with or without `remoteUser`)
- When create argv is built
- Then create MUST include `-u` `bob`
- And when `remoteUser` is also `alice`, connection/stamp/exec remain `alice`

#### Scenario: non-root OCI connection user sets create -u
- Given a config with neither `remoteUser` nor `containerUser` set and OCI `USER` `node`
- When create argv is built
- Then create MUST include `-u` `node`
- And `devcontainer.remote_user` is stamped `node`

#### Scenario: connection root omits create -u
- Given neither config user set and successful empty OCI USER (connection resolves to `root`)
- When create argv is built
- Then create MUST omit `-u`
- And `devcontainer.remote_user` is stamped `root`

#### Scenario: metadata vscode sets create -u (Apple terminal)
- Given neither local user key set, OCI `USER` `root`, metadata `remoteUser` `vscode`
- When create argv is built
- Then create MUST include `-u` `vscode`
- And connection/stamp/nameConfig remain `vscode`

---

### Requirement: Unsupported property policy

The CLI MUST fail closed on unsupported or unknown-dangerous configuration. Errors MUST be structured and actionable: identify the property/flag, state that it is unsupported, and indicate what to remove or change. Known Apple-incompatible **optional** bits MUST warn-and-skip (never silent ignore). The CLI MUST NEVER silently ignore unknown-dangerous entries.

**Warn-skip (v1) — continue `up` with effective config stripped**

- Feature refs containing `docker-outside-of-docker` / `docker-in-docker` / `docker-from-docker` (any registry/tag or local path) — drop from admitted features; warn
- Feature/image metadata `privileged: true` or non-empty `securityOpt` — warn; do not apply to create; feature may still install if admitted
- `runArgs` known-incompatible family (`--privileged`, `--device…`, `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`, Docker-only `--network` modes) — skip entry with warn; keep allowlisted siblings

**Hard-error (v1) — Features-aware**

- `runArgs` entries not on the runArgs allowlist (and not in the warn-skip family)
- First-class smuggling via runArgs (`-e`, `-u`, `-w`, `-p`, `-v`, …)
- Docker Compose keys / compose-file driven multi-service config
- Unknown top-level dangerous properties; missing `image`; invalid feature option shapes; hostRequirements shortfalls; unsupported substitutions

**No longer reject**

- Non-ood OCI `features` entries solely for being features — they MUST enter the Features runner path
- Local path feature refs — they MUST enter the Features runner path (load from disk relative to workspace)
- Presence of docker-* features or privileged/device runArgs alone — warn-skip instead of failing whole config

**May ignore or store as metadata (MUST NOT fail parse)**
- Other benign editor metadata and other `customizations.*` namespaces that are not applied in v1 (MUST NOT fail parse). `customizations.vscode` is **no longer pure ignore** for apply purposes (see **No longer pure-ignore** below).

**Not pure metadata (identity-affecting)**
- Optional `name` — when non-empty after trim, MUST drive the human base of container name and Features derived tag (see Deterministic identity and labels); MUST NOT fail parse

**No longer pure-ignore**
- `hostRequirements` — MUST evaluate per **hostRequirements preflight** (not silent ignore)
- `customizations.vscode` — MUST still admit without failing parse when present as an object under object-shaped `customizations` (see existing scenario **customizations.vscode does not fail**). When nested `extensions` / `settings` are well-formed, the CLI MUST retain them and MUST apply per **Parse and retain customizations.vscode extensions and settings**, **Apply vscode settings on create-path (and repair on drift)**, **Apply vscode extensions when --vscode is set (before open)**, and **Vscode customizations apply idempotency**. Malformed nested shapes soft-skip apply with warn rather than failing whole-config resolve when `customizations.vscode` is an object.

**Unknown non-metadata top-level properties**
- MUST hard-error (fail closed), except keys explicitly supported in core plus lifecycle hooks, allowlisted `runArgs`, `hostRequirements`, and **`features`**.

#### Scenario: Warn-skip docker-outside-of-docker
- Given a config with `features` including a docker-outside-of-docker ref (optionally plus a non-docker feature)
- When config is validated
- Then admission succeeds; the docker-* ref is absent from admitted features; stderr warns naming the feature

#### Scenario: Non-ood features no longer rejected as blanket-unsupported
- Given `features` with only `ghcr.io/devcontainers/features/node:1`
- When config is validated at admission
- Then the CLI does not fail with a blanket “features are not supported” error

#### Scenario: Warn-skip privileged runArgs
- Given `runArgs` including `--privileged` and an allowlisted flag (e.g. `--init`)
- When config is validated
- Then admission succeeds; `--privileged` is absent from effective runArgs; stderr warns

#### Scenario: Warn-skip device runArgs
- Given `runArgs` including `--device=/dev/net/tun:/dev/net/tun`
- When config is validated
- Then admission succeeds; the device entry is absent from effective runArgs; stderr warns

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
- Then settings were attempted on create-path and extensions were attempted under the `--vscode` flag gate (before open; not gated on open success) per the apply requirements
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

When `features` is present, config hash material MUST include the selected feature refs, options, and ordered identity inputs. Changing features MUST change config hash so reuse and drift detection remain correct (a new create path runs when features change).

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
| `devcontainer.remote_user` | MUST be the **resolved remote connection user** (non-empty). MUST NOT be stamped empty on a successful create. |
| `devcontainer.config_volumes` | Comma-separated config `type=volume` sources when any; omit/empty otherwise |
| `devcontainer.git_url` / `devcontainer.workspace_volume` | MUST NOT be set (or empty; purge ignores missing ws vol) |

**Human base (bind-mode)**

1. If `devcontainer.json` `name` is present and non-empty after trim → sanitize that value.
2. Else → sanitize the workspace folder basename.

**Container name (bind-mode)**

- Format: `adev-{base}-{hash12}` where `hash12` is a 12-character hash of workspace path + config path.
- If the human base is empty after sanitize → `adev-{hash12}`.
- The full name MUST be ≤ 63 characters.

**Volume-mode (`clone`) identity** MUST use the volume-mode identity and labels requirements (git URL + config relative path; managed/volume labels; adapted `local_folder`). The two modes MUST NOT collide solely because a temp path string matches a host workspace path. Volume-mode create MUST stamp `devcontainer.remote_user` to the same **resolved remote connection user** (non-empty) as bind-mode.

On every successful managed create (`up` bind, `clone` volume, `rebuild` new container), the product MUST stamp `devcontainer.remote_user` to the resolved remote connection user from **Remote connection user resolution**.

Greenfield: existing containers with empty labels are out of scope for automatic repair; `exec` continues to honor whatever is stamped (empty → omit `-u` on exec as today). New creates MUST always stamp non-empty.

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

#### Scenario: Up create stamps non-empty remote_user from resolution
- Given a successful `up` create with neither config user set and OCI `USER` `node`
- When labels are inspected
- Then `devcontainer.remote_user` equals `node` (non-empty)

#### Scenario: Clone create stamps remoteUser when set
- Given a successful `clone` create with `remoteUser` `alice`
- When labels are inspected
- Then `devcontainer.remote_user` equals `alice`

#### Scenario: Rebuild refreshes remote_user to newly resolved connection user
- Given a managed container whose edited config changes `remoteUser` from `alice` to `bob`
- When the user runs `adevcontainer rebuild --name <that-name>` successfully
- Then the new container’s `devcontainer.remote_user` is `bob`

See also: [clone.md](clone.md) for volume-mode identity, workspace volume names, and volume-mode labels; **Remote connection user resolution** for the stamp value.

---

### Requirement: Up lifecycle (create, start, reuse)

`adevcontainer up` MUST resolve config, admit properties, and ensure a running managed dev container: create if missing, start if stopped, reuse if already running with matching identity. Workspace bind MUST mount the host workspace into the container workspace folder. `up` MUST support a machine-readable JSON result on success (and structured failure otherwise).

**Success JSON fields (required)**
- `outcome` — success indicator consistent with reference CLI style (e.g. `"success"`)
- `containerId` — runtime container id
- `remoteUser` — MUST be the **resolved remote connection user** (non-empty after successful create). MUST NOT be empty solely because config omitted both user keys when resolution yielded OCI `USER` or `root`. The same non-empty resolved value MUST apply to `clone` and `rebuild` success JSON `remoteUser` fields.
- `remoteWorkspaceFolder` — absolute path inside the container used as workspace folder

Additional helpful fields (e.g. `containerName`) MAY be included.

**Drift policy**

`up` reuses a running or stopped container with matching identity. When the config/features hash drifts (stamped `devcontainer.config_hash` ≠ resolved hash), `up` MUST fail closed with structured `config_hash_mismatch` and MUST NOT delete or replace; the error hint MUST point to `adevcontainer rebuild` (managed selection: `--name` or auto when applicable). Equal-hash forced rebuild and volume-preserving forced rebuild are **only** via `rebuild`: it MUST NOT require hash drift and MUST preserve volumes — it reads the current config, completes resolution/preflight/Features work first, deletes the old container **only** (container-only delete), and creates the new container reusing the existing workspace volume and config named volumes. Hard post-delete create/start/create-path failures offer mode-split recovery (bind host-editor; clone-origin volume helper); see change archive and product docs for recovery detail.

**Create image selection (Features-aware)**

On paths that create a new container (fresh create or `rebuild`):

- **Before create**, if resolved `features` is non-empty: ensure **build.rosetta=false** (consent), then **resolve → fetch → order → contribution merge → Dockerfile generate → `container build`** (or reuse derived tag). Create uses the **derived image** with contributions merged and **`--platform`** host-native.
- Then start and lifecycle hooks (onCreate → updateContent → postCreate → postStart, etc.); feature-contributed hooks merge per the merge-feature-metadata requirement (installs are already in the derived image).
- If `features` is absent or empty: create uses config `image` as today (still with default platform); Features build path is not required.
- Reuse running / start stopped paths MUST NOT re-fetch/rebuild features. Config hash (including features) still drives `config_hash_mismatch` on `up` when features change; forced rebuild is available via `rebuild` only.

**Lifecycle hook matrix by path**

| Path | Lifecycle |
|------|-----------|
| Fresh create (missing) | Host initialize (when a host workspace exists) → onCreate → updateContent → postCreate → postStart; delete container if any create-path hook (onCreate / updateContent / postCreate / first postStart) fails; Ready / open / postAttach wait for `waitFor` (default updateContent) |
| `rebuild <name>` (forced rebuild after container-only delete of the old container) | Same fresh create-path on the **new** container, including host initialize (volume-mode / clone-origin with no usable host workspace: initialize still runs on a temporary workspace root that contains the guest config directory/files; temp removed after the hook); delete-on-fail applies to the **new** container; the old container was already removed (status warning on post-delete failure); recovery offer rules unchanged |
| Reuse running (matching identity) | No onCreate / updateContent / postCreate / postStart; host initialize MUST run when a host workspace exists; postAttach runs as CLI attach |
| Start stopped (`up` or bare `start`) | Host initialize when a host workspace exists; postStart (config then remelted feature postStart); on failure fail the command, do not delete; Ready / open / postAttach follow [lifecycle-hooks.md](lifecycle-hooks.md) **waitFor readiness** (this invocation’s postStart only when `waitFor` is `postStartCommand`); postAttach runs as CLI attach |
| Already-running `start` | No initialize / postStart; postAttach only after successful `--vscode` open |
| CLI-attach path (`up` / `clone` / `rebuild` / real `start`) with postAttach present | After waitFor: run config then feature postAttach; `--vscode` open soft-fail MUST NOT skip; on failure fail command, keep container |
| Already-running `start` with postAttach present and no successful `--vscode` open | skip execute; one status line |
| Any path with postAttach absent | no postAttach skip line; no postAttach exec |

postAttach is **not** part of create-path delete-on-fail. Settings/open soft-fail and postAttach failure MUST NOT enter either recovery session. Customizations apply remains **not** part of create-path delete-on-fail, **not** folded into postAttach, and **not** run on `start`.

| Path | Vscode customizations apply |
|------|-----------------------------|
| Fresh create-path `up`/`clone`/`rebuild` with well-formed settings | after create-path hooks: settings merge (soft-fail); marker/idempotency rules |
| Fresh create-path without settings (and no pending payload) | no settings apply required |
| Any path with well-formed extensions, `--vscode` absent | extensions not installed by CLI on that invocation |
| Any path with well-formed extensions, `--vscode` set, marker pending/drift | before open: extensions install (soft-fail; flag gate only — runs even if open later soft-fails); then open; then postAttach only on open success per existing matrix |
| Any path with matching marker for full normalized payload | skip redundant settings+extensions apply |
| `start` / reuse with loadable config and marker drift | settings repair when applicable; extensions only when `--vscode` is set and still pending (not gated on open success) |

postAttach matrix rows and gating text above remain in force. Customizations apply is **not** part of create-path delete-on-fail and **not** folded into postAttach execution.

Create-path cleanup is unchanged: if any create-path hook fails before the command returns success, the CLI MUST delete the new/created container (extend to onCreate, updateContent, postCreate, and first-create postStart). On `rebuild`, delete-on-fail applies to the **new** container only (workspace/config volumes preserved); eligible hard post-delete failures then offer mode-split recovery.

#### Scenario: Create then reuse
- Given no existing container for the workspace
- When the user runs `up` twice with the same config
- Then the first run creates and starts a container and prints success JSON including `containerId` and `remoteWorkspaceFolder`, and the second run reuses the running container without error

#### Scenario: Start stopped container
- Given a container previously created by `up` that is stopped
- When the user runs `up`
- Then the container is started, resume hooks run, and success JSON is emitted

#### Scenario: Up JSON shape
- Given a successful `up`
- When the machine-readable result is parsed
- Then it includes `outcome`, `containerId`, `remoteUser`, and `remoteWorkspaceFolder`

#### Scenario: success JSON remoteUser reflects OCI fallback
- Given neither config user key set and OCI `USER` `node`
- When `up` succeeds with `--json`
- Then JSON `remoteUser` is `node`

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
- Then no feature fetch/build is required and onCreate / updateContent / postCreate / postStart are not re-run

#### Scenario: up hash mismatch hints rebuild
- Given a managed bind-mode container whose stamped `devcontainer.config_hash` does not match the resolved config hash
- When the user runs `adevcontainer up` for that workspace
- Then the CLI fails with `config_hash_mismatch` and does not delete the container
- And the error hint mentions `adevcontainer rebuild` and managed selection (`--name` or auto)
#### Scenario: rebuild hook matrix row applies
- Given a managed container being rebuilt with a config carrying initialize plus the four create-path hooks
- When `rebuild` runs the fresh create-path on the new container
- Then initialize runs on the host, then onCreate → updateContent → postCreate → postStart execute on the new container, and a first create-path hook failure deletes only the new container

#### Scenario: rebuild does not require hash drift
- Given a managed container whose current config hash equals the stamped hash
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then rebuild creates a new container (no hash-mismatch precondition), unlike `up` reuse which would have kept the running container

See also: [lifecycle-hooks.md](lifecycle-hooks.md) for hook surface details; [vscode.md](vscode.md) for postAttach and vscode customizations apply gating; [features.md](features.md) for Features create-path build; [managed-lifecycle.md](managed-lifecycle.md) for rebuild selection.

---

### Requirement: AppleContainerRuntime boundary

All interaction with Apple `container` MUST go through a single **AppleContainerRuntime** module. No other module MAY shell out to `container`. The runtime MUST invoke the binary as a subprocess, prefer/require machine-readable JSON for parsed results, and MUST NOT scrape human TTY tables for control flow. Non-zero exits MUST map to structured CLI errors.

#### Scenario: Mockable runtime in tests
- Given unit tests for commands
- When tests run without a real Apple `container`
- Then commands can be exercised via a mock/fake process runner behind AppleContainerRuntime

---

### Requirement: OCI image USER on image inspect

Runtime image inspect MUST expose the image’s final OCI `USER` when the inspect payload provides it.

- The inspect result MUST carry a user field (name or empty) derived from the machine-readable image inspect JSON.
- Absence of a usable `USER` in a **successful** inspect MUST be represented as empty/absent user — not as a fabricated `root` inside the inspect result.
- Consumers that need a default after empty USER MUST apply the remote connection user chain (step 6 `root`) themselves; inspect MUST NOT pretreat failure or emptiness as `root`.

#### Scenario: inspect exposes OCI USER
- Given a local image whose inspect JSON reports final `USER` `node`
- When the product inspects that image
- Then the inspect result exposes user `node`

#### Scenario: successful inspect with no USER is empty not root
- Given a local image whose inspect JSON has no usable `USER`
- When the product inspects that image successfully
- Then the inspect result’s user is empty/absent
- And the inspect API itself MUST NOT coerce that to `root`

#### Scenario: inspect failure is distinct from empty USER
- Given image inspect fails for a reference
- When the product attempts inspect
- Then the call fails with a structured runtime/inspect error
- And callers MUST NOT interpret that failure as user `root`

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

Fixtures MUST be valid for their capability (no hard-error props such as Compose). They MAY include warn-skip surface when testing that path; ordinary fixtures SHOULD remain free of docker-* / privileged noise. They SHOULD align field styles with `reference/devcontainer.json` where applicable (image family, env keys, mount shapes, ports) while remaining Apple-container-runnable after warn-skips. Existing core fixtures MUST remain valid under lifecycle / runArgs / hostRequirements / Features-aware admission (configs without `features` behave as today).

#### Scenario: Fixtures are parseable configs
- Given each file under `Tests/Fixtures/`
- When parsed with JSONC/JSON rules and validated against admission
- Then each fixture is admitted for its capability without unsupported-property errors

#### Scenario: All listed fixtures still admit for their capability
- Given each file under `Tests/Fixtures/` listed in the capability table including `features-node.json` and `features-local.json`
- When parsed and validated against admission
- Then each fixture is admitted for its capability without unexpected unsupported-property errors

See also: [runargs-host.md](runargs-host.md), [features.md](features.md), and [lifecycle-hooks.md](lifecycle-hooks.md) for domain-specific fixture requirements that reference this inventory.

