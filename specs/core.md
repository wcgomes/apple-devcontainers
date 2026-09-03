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
| `${devcontainerId}` | Resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`). **Base** is the sanitized workspace folder basename (`up`) or git URL repo basename (`clone`) only — MUST NOT use config `name`. Hash material matches the product workspace volume (bind: workspace path + config path; volume: normalized git URL + config relative path). MUST NOT be the create `--name` / DNS hostname. Official meaning is unique + stable across rebuilds; this stem is that analogue. |

Unsupported substitution tokens MUST cause a structured error naming the token. Substitution MUST run before runtime admission and mount/port mapping.

**`${devcontainerId}` lifecycle — MUST**

- Feature metadata mounts (and config mounts) MAY embed `${devcontainerId}` in volume `source` (e.g. shell-history `source=${devcontainerId}-shellhistory`).
- When the resource identity stem is not yet known at config resolve, the token MAY remain unsubstituted through resolve.
- Before named-volume ensure and `container create`, the CLI MUST expand `${devcontainerId}` to the resource identity stem so Apple volume names match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`.
- Volume-mode config hash / `devcontainer.config_volumes` labels MUST use post-expansion mount sources so identity stays stable and purge sees real volume names.
- A rebuild that only changes config `name` (create name) MUST expand `${devcontainerId}` to the same stem as before so those volumes are reused.

#### Scenario: localEnv in mount source
- Given `containerEnv` or a mount `source` containing `${localEnv:HOME}/.kube/config` and `HOME` is set on the host
- When config is resolved
- Then the token is replaced with the host value

#### Scenario: devcontainerId in feature volume mount source
- Given a feature mount `source=${devcontainerId}-shellhistory` (type volume), workspace folder `foo`, `"name": "My App"`, and identity `hash12`
- When the container is created
- Then the volume name is `adev-foo-{hash12}-shellhistory` and volume create succeeds

#### Scenario: Unknown substitution token
- Given a string value containing `${unknownToken}`
- When config is resolved
- Then the CLI fails with a structured error naming `unknownToken`

---

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

The CLI MUST accept and honor the property surface below. Properties outside this surface follow **Unsupported property policy** and **Deterministic compatibility degradation reporting**. Truly unknown non-metadata top-level properties and blocked recognized semantics MUST hard-error. Parseable `customizations.vscode.extensions` / `settings` are **honored by apply**, not ignored, while still never failing parse solely for presence. Other benign editor metadata MAY be ignored per Unsupported property policy.

**Image & workspace**
- `$schema` — optional string parser/editor metadata; silent and hash-neutral
- `name` (optional; when non-empty after trim, drives the DNS-friendly create name and does not drive the resource base, per the live Deterministic identity and labels contract)
- `image` (required for image-based dev containers)
- `overrideCommand` — Boolean; true is a silent restatement of the existing keep-alive override and false is blocked
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
- `otherPortsAttributes` — object; empty is silent, non-empty is warn-ignored because default port actions are not applied

**Lifecycle**
- `initializeCommand` — string, argv array, or object map; host command per [lifecycle-hooks.md](lifecycle-hooks.md) **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and [vscode.md](vscode.md) **postAttachCommand policy (CLI-only)**
- `waitFor` — enum; default `updateContentCommand`; policy per **waitFor readiness**
- `userEnvProbe` — enum; default `loginInteractiveShell`; policy per **userEnvProbe merge**
- `shutdownAction` — enum; default `stopContainer` for this image/Dockerfile product; `stopCompose` fails closed; policy per **shutdownAction admission**

**Runtime options, runArgs, and hostRequirements**
- `init` — Boolean; true requests one effective `--init`, unioned and deduplicated with `runArgs` and Feature/image init contributions; false is an additive no-op
- `privileged` — Boolean; false is silent and true is warn-stripped without Apple virtualization semantics
- `capAdd` — array of validated capability names; translated through the typed capability path
- `securityOpt` — array of strings; empty is a silent no-op, non-empty is explicitly warn-skipped and never represented as enforced
- `runArgs` — allowlisted subset only; mapped on create
- `hostRequirements` — evaluated preflight (fail on capacity shortfall; map memory/cpus to create limits; fail on parse/unknown keys)

**Features**
- `features` — object map of OCI or local path feature ref → options; processed by the Features runner (see Features requirements)

**Editor customizations and recommendations (config-file, v1)**
- `customizations.vscode.extensions` — array of string extension IDs; retained and applied when `--vscode` is set (before open; not gated on open success) per apply requirements
- `customizations.vscode.settings` — JSON object; retained and merged into guest Machine settings on create-path (and repair on drift) per apply requirements
- Other `customizations` content remains admitted metadata and is not applied in v1
- `secrets` — object whose entries are recommendation objects; empty is silent and non-empty is warn-ignored without injection or disclosure

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

#### Scenario: Lifecycle runtime options runArgs and hostRequirements property set does not hard-error as unknown
- Given a config that includes only core supported keys plus the lifecycle properties in this requirement, valid `init` and `securityOpt`, allowlisted `runArgs`, and `hostRequirements`
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

#### Scenario: top-level init and securityOpt are on the supported surface
- Given a minimal image config with Boolean `init` and string-array `securityOpt`
- When config is validated
- Then validation does not reject either key as an unknown top-level property and their values follow **Top-level init and securityOpt behavior**

#### Scenario: Expanded low-risk property surface admits
- Given a valid image config containing `$schema`, `otherPortsAttributes`, `secrets`, Boolean `privileged`, `overrideCommand: true`, and valid top-level `capAdd`
- When config is admitted and resolved
- Then no key fails as unknown, each follows its exact/silent/degraded behavior, and only effective capability behavior reaches create/hash material

See also: [lifecycle-hooks.md](lifecycle-hooks.md), [runargs-host.md](runargs-host.md), [features.md](features.md), [vscode.md](vscode.md) for detailed property behavior; **Remote connection user resolution** and **Create process user** for the user chain and create `-u`.

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

Every top-level Dev Container input MUST be classified by known semantics:

| Class | Default behavior | Hash behavior |
|-------|------------------|---------------|
| Exact translation | Apply through a typed product/runtime mapping; no compatibility issue | Hash normalized effective behavior |
| Bounded emulation | Apply the documented substitute and emit one emulated issue | Hash delivered behavior |
| Harmless metadata/no-op | Admit silently without claiming runtime semantics | Hash-neutral |
| Known optional unsupported | Emit one ignored issue, strip from effective behavior, and continue | Hash-neutral |
| Blocked | Structured actionable error | No effective hash/result |

Hard rejection MUST be limited to malformed input or semantics whose omission would make execution incoherent, unsafe, destructive, or materially misleading. This includes unrepresentable configuration-source selectors (`build`/legacy Dockerfile and Compose until separately supported), custom workspace/process semantics that would run different content or commands, required host capabilities that are unmet or unverifiable, data/security-sensitive protections that cannot be preserved, unsupported substitutions, invalid Feature option/package requirements, and first-class runArg collisions. A recognized property MUST NOT be rejected merely because it lacks an implementation when its omission is registered as harmless or optional and reported as required.

Truly unknown non-metadata top-level keys MUST remain blocked because their semantic consequence cannot be classified. Object-shaped registered tool namespaces under `customizations` are metadata, not a precedent for arbitrary top-level acceptance. Unknown runArgs and raw Apple CLI passthrough remain blocked; only the typed runtime model and explicit runArgs allowlist may produce Apple arguments.

The existing known optional families remain warn-and-ignore in default mode: docker-* Features, privileged/device/security/runtime runArgs, Feature/image privileged or securityOpt metadata, top-level non-empty securityOpt, and other entries explicitly registered under this policy. Strict compatibility overrides continuation by failing on their compatibility issues.

**Registered warn-and-ignore inputs — continue in default mode with effective config stripped**

- Feature refs containing `docker-outside-of-docker` / `docker-in-docker` / `docker-from-docker` (any registry/tag or local path) — drop from admitted features; report one ignored issue
- Feature/image metadata `privileged: true` or non-empty `securityOpt` — report one ignored issue; do not apply to create; the Feature may still install if admitted
- `runArgs` known-incompatible family (`--privileged`, `--device…`, `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime`, Docker-only `--network` modes) — skip the entry with one ignored issue; keep allowlisted siblings

**Blocked inputs — Features-aware**

- `runArgs` entries not on the runArgs allowlist and not in the registered warn-and-ignore family
- First-class smuggling via runArgs (`-e`, `-u`, `-w`, `-p`, `-v`, …)
- Docker Compose keys / compose-file driven multi-service config
- Unknown top-level dangerous properties; missing `image`; invalid Feature option shapes; hostRequirements shortfalls; unsupported substitutions

**Admitted behavior retained from the realized policy**

- Non-docker OCI `features` entries and local path Feature refs MUST enter the Features runner path rather than being rejected solely for being Features
- Other object-shaped editor metadata and `customizations.*` namespaces not applied in v1 MUST NOT fail parse; well-formed `customizations.vscode.extensions` and `settings` remain retained and applied under their realized requirements, while malformed nested shapes soft-skip apply with a warning when `customizations.vscode` itself is an object
- Optional non-empty `name` remains identity-affecting rather than pure metadata
- `hostRequirements` remains evaluated rather than silently ignored

#### Scenario: Truly unknown top-level property remains blocked

- Given an otherwise valid config containing an unregistered top-level property
- When admission runs
- Then the CLI returns a structured unsupported-property error naming the key rather than silently ignoring it or passing it through

#### Scenario: Recognized optional property no longer blocks default mode

- Given a structurally valid property registered as known optional unsupported
- When admission and resolution run in default mode
- Then the property is stripped, one compatibility warning describes the omission, and the remaining effective config MUST NOT fail solely because that property was ignored

#### Scenario: Malformed recognized property remains blocked

- Given a registered exact, harmless, emulated, or optional property with an invalid required shape
- When admission runs
- Then the CLI returns a property-specific structured validation error rather than treating the value as absent

#### Scenario: Unrepresentable source selector remains blocked

- Given a config selects Dockerfile build or Docker Compose without a separately supported translation
- When admission runs
- Then the CLI fails before choosing another image or creating a semantically unrelated container

#### Scenario: Material workspace or process mismatch remains blocked

- Given `workspaceMount`, `remoteEnv`, `overrideCommand: false`, or another registered behavior whose omission would mount different content or run different processes
- When no bounded implementation exists
- Then the CLI fails with an actionable property-specific error rather than warn-ignoring the behavior

#### Scenario: Required host or protection semantics remain blocking

- Given a required host capability is unmet/unverifiable or a requested data/security protection cannot be preserved
- When preflight classifies the requirement
- Then the command fails before the affected runtime or destructive action

#### Scenario: First-class runArg collision remains blocked

- Given runArgs attempts to set product-owned env, user, workdir, port, mount, name, label, entrypoint, or lifecycle flags
- When runArgs admission runs
- Then the CLI fails with the existing collision policy and does not passthrough the flag

#### Scenario: Existing Apple-incompatible optional inputs remain tolerant

- Given default mode with docker-* Features, privileged/device/security-family runArgs, or privileged/securityOpt metadata
- When the applicable admission or metadata boundary completes
- Then each omitted item produces a deterministic ignored compatibility issue and compatible siblings remain effective

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

Sanitize MUST be DNS-safe: lowercase; replace each run of characters outside `[a-z0-9-]` with `-`; collapse consecutive hyphens; trim leading/trailing hyphens.

`name` is not metadata-only: when set (non-empty after trim), it MUST drive the **create name** (DNS / human identification). It MUST NOT drive the resource base used for `${devcontainerId}`, Features derived image tags, or product workspace volumes.

When `features` is present, config hash material MUST include the selected feature refs, options, and ordered identity inputs. Changing features MUST change config hash so reuse and drift detection remain correct (a new create path runs when features change).

**Bind-mode (`up`) workspace identity** MUST remain: `hash12` from workspace path + config path is still the bind-mode identity hash for hashed sidecars that need it. Reuse and occupancy MUST key off labels (`devcontainer.local_folder` + `devcontainer.config_file`), not off embedding that hash in the create name. On create, labels MUST include:

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

**Resource base** (rebuild-stable sidecars only)

1. Sanitize the workspace folder basename (bind) or the git URL repo basename (volume). MUST NOT use config `name`.
2. Clip the resource base to about 20 characters.
3. Resource base is used for Features tags, the product workspace volume, and the `${devcontainerId}` stem only. An empty resource base after sanitize/clip MUST NOT invent a hashed create name; create-name emptiness is a structured failure (below). Features empty-base tag fallback `adevcontainer:{contentHash}` remains for the tag path. Empty resource base for the stem is `adev-{hash12}`.

**Create name (container id / DNS hostname)**

1. If `devcontainer.json` `name` is present and non-empty after trim → sanitize that value.
2. Else → sanitize the workspace folder basename (bind) or the git URL repo basename (volume).
3. MUST NOT prefix `adev-`. MUST NOT append an identity hash.
4. The create name MUST be ≤ 63 characters and MAY use the full 63-character budget. If the sanitized value exceeds 63, the product MUST clip to 63 characters and trim leading/trailing hyphens afterward.
5. If the create name is empty after sanitize (and clip/trim), the CLI MUST fail with a structured error that asks the user to set a DNS-safe `name` in `devcontainer.json`. MUST NOT fall back to `adev-{hash12}` or any other invented create name.
6. Occupancy of that create name MUST follow **Create-name occupancy classification**.

**Volume-mode (`clone`) identity** MUST use the volume-mode identity and labels requirements (git URL + config relative path; managed/volume labels; adapted `local_folder`). Bind and volume workspace hashes MUST stay distinct. Two invocations MAY still compute the same create name when sanitized `name` / fallback values match; that is a name occupancy, not a hash collision. Volume-mode create MUST stamp `devcontainer.remote_user` to the same **resolved remote connection user** (non-empty) as bind-mode.

On every successful managed create (`up` bind, `clone` volume, `rebuild` new container), the product MUST stamp `devcontainer.remote_user` to the resolved remote connection user from **Remote connection user resolution**.

Greenfield: existing containers with empty labels are out of scope for automatic repair; `exec` continues to honor whatever is stamped (empty → omit `-u` on exec as today). New creates MUST always stamp non-empty.

Discovery and reuse MUST prefer create name + inspect + managed labels, NOT Docker-style `ps --filter label=` as the primary mechanism. Discovery of managed containers for `list` / `start` / extended `stop` MUST filter client-side on `devcontainer.managed=adevcontainer` after machine JSON list (Apple `container` has no label filter API).

#### Scenario: Stable name across invocations
- Given the same workspace path, config `name`, and config content
- When `up` is invoked twice without delete
- Then the second invocation reuses the same create name and same-workspace occupant rather than creating a conflicting duplicate

#### Scenario: Container name uses config name when set
- Given a config with `"name": "My App"` and a workspace folder basename `foo`
- When the container name and resource stem are computed
- Then the create name is `my-app` (DNS-safe sanitize of `My App`) and the resource stem is `adev-foo-{hash12}` (not `adev-my-app-{hash12}`)

#### Scenario: Container name falls back to workspace basename
- Given a config with no `name` (or only whitespace) and workspace folder basename `other-folder`
- When the container name is computed
- Then the create name is the sanitized workspace folder basename (`other-folder` or equivalent sanitize result) with no `adev-` prefix and no identity hash

#### Scenario: Empty sanitize asks for a DNS-safe name
- Given a config whose `name` (or fallback basename, when `name` is omitted) sanitizes to empty
- When `up` or `clone` computes the create name
- Then the CLI fails with a structured error asking for a DNS-safe `name` and MUST NOT create a container named `adev-{hash12}`

#### Scenario: Create name may use 63 characters
- Given a sanitized create name of 63 `a-z0-9-` characters
- When the container is created
- Then Apple `create --name` equals that 63-character value

#### Scenario: Punctuation-heavy name collapses hyphens
- Given a config with `"name": "C# (.NET)"` and workspace folder basename `proj`
- When the create name and resource base are computed
- Then the create name is `c-net` (not `c----net`) and the resource base is the sanitized folder basename (`proj`), not `c-net`

#### Scenario: Labels present on inspect
- Given a container created by `up`
- When the user runs `adevcontainer inspect`
- Then local folder, config file, and config hash labels/fields are visible in the inspect output

#### Scenario: Features participate in identity hash
- Given two configs identical except for a feature option value
- When config hashes are computed
- Then the hashes differ

#### Scenario: Bind and volume modes distinct workspace hashes
- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`, both without an overriding `name`
- When identities are computed
- Then bind hash material (path+config) differs from volume hash material (git URL+config relpath) so workspace-volume names stay mode-specific
- And both create names are the sanitized `foo` (or equivalent); if that name is already taken by the other mode, occupancy classification applies

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

### Requirement: Git credential store seeded on create paths

On the create paths — `up` fresh create (bind mode) and `rebuild` replacement create (bind and volume mode) — the CLI MUST seed the resolved remote connection user's git credential store in the container BEFORE any create-path lifecycle hook (onCreateCommand, updateContentCommand, postCreateCommand, postStartCommand) runs. Seeding MUST run after the create-path ownership steps.

Seeding MUST write a POSIX-sh credential helper script to the connection user's home directory in the container (e.g. `$HOME/.adevcontainer/git-credential-adev`) with mode 0700, owned by the connection user. Seeding MUST configure the helper at `--global` scope via `git config --global --add credential.helper <absolute-path>`; the configuration MUST append and MUST NOT replace pre-existing credential helpers. Seeding MUST add one credential entry per unique (protocol, host, username) triple via `git credential approve`, which routes through the configured helper whose store mode persists the entry. Entries MUST NOT include a path component, so sibling repositories on the same host are covered without knowing their paths. Matching uses the URL scheme (protocol), host, and username; SSH remotes MUST NOT be seeded.

The helper MUST implement `get`, `store`, and `erase`. On `get`, the helper MUST match the persisted store by (protocol, host) IGNORING the queried username, and MUST return the queried username (or the stored username when the query carries none) together with the stored password; when no entry matches, the helper MUST exit 0 with no output so git falls through to remaining helpers, askpass, or prompt. On `store`, the helper MUST persist the entry, deduping by (protocol, host, username), to its own store file (e.g. `$HOME/.adevcontainer/git-credentials`) with mode 0600, owned by the connection user; the helper MAY use git's store file format with percent-encoding or its own simple line format, and persisted values MUST round-trip raw username and password values (including `@` and `:` characters) without corruption. `erase` MUST be a no-op. Secrets MUST NOT be echoed to stdout or stderr outside the credential protocol and MUST NOT appear in argv.

Credentials MUST be acquired on the HOST through the shared acquisition contract declared by **In-container full clone populate (auth by URL scheme)** ([clone.md](clone.md)): `git credential fill` (protocol/host/path from URL) with `GIT_TERMINAL_PROMPT=0`, optional `ADEVCONTAINER_GIT_TOKEN`, and the `gh auth token` fallback — the existing `HostGitCredential.fillHTTPS` path. When fill returns nil for a URL, the CLI MUST skip that URL silently.

Remote discovery MUST be:

- Bind mode (`up` fresh create, `rebuild` bind): the unique fetch remote URLs of the host workspace via `git -C <hostWorkspace> remote -v`.
- Rebuild volume mode: the stamped `devcontainer.git_url` label of the rebuilt container; a missing or empty label MUST skip seeding silently.

Silent skip — no warning and no failure — MUST apply when host git is missing, when the host workspace is not a git repository or has no remotes, or when fill returns nil. `up` MUST NOT gain a host-git prerequisite.

Seeding failures (for example missing in-container git or an exec failure) MUST soft-fail: a warning on stderr and the create path continues. Seeding MUST NOT delete the container and MUST NOT enter bring-up recovery. Hook failure remains the hook's own failure under existing create-path policy.

Secrets MUST NEVER appear in success JSON, labels, StatusPrinter progress lines, or logged errors; errors MUST redact URL userinfo and credential material (same redaction as the clone flow).

Non-create paths MUST NOT seed: `up` reuse of a running matching container, `up` start-stopped, and bare `start` MUST NOT run seeding.

`clone` is covered-by-design: the product MUST NOT add a second seeding mechanism on `clone`; clone's populate already configures `credential.helper store` + approve before hooks, and regression coverage MUST prove the store outcome is delivered without a seeding call.

#### Scenario: up bind fresh create seeds the store before hooks

- Given a bind-mode `up` fresh create whose host workspace has an HTTPS fetch remote `https://dev.azure.com/plantsuite/PlantSuite/_git/GitOps` and host `git credential fill` returns credentials
- When the create path runs after start and before create-path hooks
- Then the CLI acquires credentials on the host and runs an in-container exec as the connection user that writes the credential helper script, configures `credential.helper --add` with its absolute path at `--global` scope, and approves an entry for (https, dev.azure.com, plantsuite) BEFORE the first create-path hook exec

#### Scenario: sibling repositories on the same host are covered

- Given the same bind-mode `up` and a workspace whose remotes include `https://dev.azure.com/plantsuite/PlantSuite/_git/GitOps` and `https://dev.azure.com/plantsuite/PlantSuite/_git/Other`
- When seeding runs
- Then one approve entry per unique (protocol, host, username) is applied and the entries contain no path component

#### Scenario: duplicate remote lines dedupe to one entry

- Given `git -C <hostWorkspace> remote -v` lists the same fetch URL more than once
- When seeding runs
- Then only one approve entry per (protocol, host, username) is applied

#### Scenario: no host credentials skip silently

- Given a public HTTPS remote and host credential fill returns nothing
- When seeding runs
- Then the CLI skips silently (no warning, no failure) and the create path continues

#### Scenario: workspace without a git repo or remotes skips silently

- Given a bind workspace that is not a git repository, or a git repository with no remotes
- When `up` fresh create runs
- Then no seeding exec runs and `up` succeeds

#### Scenario: missing host git skips silently

- Given host git is not installed
- When bind-mode `up` fresh create runs
- Then no seeding runs, no warning is required, and `up` succeeds without a host-git prerequisite

#### Scenario: rebuild bind seeds from host remotes

- Given a bind-mode `rebuild` replacement create whose host workspace has an HTTPS remote and host fill returns credentials
- When the rebuild create path runs after start and before create-path hooks
- Then seeding runs before the first create-path hook exec and the rebuild succeeds

#### Scenario: rebuild volume seeds from the stamped git URL

- Given a volume-mode `rebuild` of a managed container whose `devcontainer.git_url` label is `https://github.com/org/repo`
- When the rebuild create path runs (no host workspace remote enumeration)
- Then seeding acquires credentials for that URL and approves an entry before the first create-path hook exec

#### Scenario: rebuild volume without a stamped git URL skips silently

- Given a volume-mode rebuild whose stamped `devcontainer.git_url` label is missing or empty
- When the rebuild create path runs
- Then no seeding runs and the rebuild succeeds

#### Scenario: seeding failure soft-fails

- Given a create path whose seeding exec fails (for example in-container git is missing or the exec errors)
- When seeding runs
- Then stderr carries a warning, the create path continues through hooks and succeeds absent other failures, the container is NOT deleted, and bring-up recovery is NOT entered

#### Scenario: non-create paths never seed

- Given a matching running bind-mode container, a stopped bind-mode container, or a bare `start` target
- When `up` reuses the running container, `up` starts the stopped one, or `start` runs
- Then no seeding exec runs

#### Scenario: secrets are redacted on the seeding error path

- Given host fill returned username/password for a remote and the seeding exec fails
- When the warning or error is emitted
- Then the warning or error contains no credential material and no URL userinfo

#### Scenario: SSH remotes are not seeded

- Given a bind workspace whose remotes are SSH URLs (`git@host:path`)
- When `up` fresh create runs
- Then no seeding exec runs

#### Scenario: seeding runs as the resolved connection user

- Given a create path whose resolved connection user is `alice` (non-root) or `root`
- When the seeding exec runs
- Then the exec runs as that user and the store lands in that user's home directory

#### Scenario: S15: username-agnostic get serves URL-forced usernames

- Given a seeded store entry for (https, dev.azure.com, X) and a create-path hook whose URL forces username Y (X ≠ Y) on the same protocol and host
- When the hook's git performs credential lookup in the non-interactive hook environment
- Then the helper's get returns the stored password with the QUERIED username Y and the hook's git authenticates

#### Scenario: S16: unseeded hosts receive no credentials

- Given a seeded store containing entries only for one (protocol, host, username) triple
- When git queries the helper for a host absent from the store
- Then the helper exits 0 with no output, no credentials are returned, and git falls through to remaining helpers, askpass, or prompt

#### Scenario: S17: helper and store files are private and secrets stay out of argv and logs

- Given a create path that seeded the helper
- When seeding completes and the hook environment runs
- Then the helper script (0700) and the store file (0600) are owned by the connection user, are not world-readable, and no password material appears in argv, success JSON, labels, progress lines, or logged errors

#### Scenario: S18: pre-existing global credential helpers are preserved

- Given a container whose global git config already configures one or more credential helpers
- When seeding appends its helper via `git config --global --add credential.helper <absolute-path>`
- Then the pre-existing helpers remain configured and are consulted before the seeded helper

---

### Requirement: Rebuild rehydrates global author identity from the existing workspace repository

On an ordinary `adevcontainer rebuild` of an existing managed workspace, in both bind and volume modes, the CLI MUST capture `user.name` and `user.email` from the existing workspace repository's local configuration before replacement begins and before the old container is deleted. Bind mode MAY read the host workspace, but volume mode MUST read the existing workspace inside the old container, or another source that remains valid before old-container deletion, and MUST NOT use a host GitClient path. The captured local pair is the sole source of truth for rebuild synchronization. The CLI MUST use only a complete local pair for synchronization and MUST NOT use global configuration, labels, credential files, or invented values as the source. After the replacement container starts, the CLI MUST complete the existing ownership preparation, credential-forwarding work, and `[DIAG]` work before writing the captured pair to the new container's resolved connection user's global Git config at that user's current `$HOME/.gitconfig`; this write MUST occur before any create-path lifecycle hook runs. Existing global values in the replacement container MUST be updated to match the workspace-local pair. Rebuild MUST NOT rewrite or remove the workspace repository's local identity as part of this synchronization.

#### Scenario: Bind rebuild rehydrates local identity before hooks

- Given an existing bind-mode workspace repository has complete local identity `Ada Lovelace` / `ada@example.com`, and the replacement resolves connection user `alice`
- When ordinary rebuild captures the identity, deletes the old container, creates and starts the replacement, and reaches the create path
- Then capture completed before old-container deletion, the replacement user's `$HOME/.gitconfig` contains the workspace-local pair before the first create-path hook runs, and a hook cloning a sibling repository as `alice` inherits that pair

#### Scenario: Volume rebuild rehydrates local identity before hooks

- Given an existing volume-mode workspace repository has complete local identity `Ada Lovelace` / `ada@example.com` in its retained workspace volume
- When ordinary rebuild reads that repository from the old container before deleting it and starts the replacement
- Then the replacement connection user's global Git config contains the same pair before the first create-path hook runs, without using a host GitClient path, re-cloning, or changing the retained workspace volume

#### Scenario: Rebuild global synchronization follows existing pre-hook work

- Given a replacement container has started and the existing ownership, credential-forwarding, and `[DIAG]` work has run
- When rebuild synchronizes a complete captured local identity
- Then the global write occurs after those existing steps and before the first create-path lifecycle hook

#### Scenario: Rebuild writes to the replacement HOME

- Given the old container's global Git config is absent or has different values and the replacement container has a different, non-persisted HOME
- When rebuild synchronizes a complete local identity
- Then the replacement connection user's current `$HOME/.gitconfig` is written with the local pair, and synchronization does not depend on copying or retaining the old container HOME

#### Scenario: Manual local changes are reflected on the next rebuild

- Given a user manually changes both local author keys in an existing bind or volume workspace repository after its previous container was created
- When the user runs the next ordinary rebuild
- Then the new container's connection-user global author keys match the manually changed local pair rather than the previous global values

#### Scenario: Missing or incomplete local identity skips rebuild synchronization

- Given an existing workspace repository has a missing or incomplete local `user.name`/`user.email` pair and the replacement container has existing global author values
- When ordinary rebuild runs
- Then rebuild does not prompt, invent, partially synchronize, or alter the existing global values, and it emits at most the existing-style warning while continuing with the normal rebuild path

#### Scenario: Rebuild global synchronization failure is warning-and-continue

- Given rebuild reads a complete local pair but writing the replacement connection user's global Git config fails
- When rebuild reaches the pre-hook identity step
- Then rebuild emits only the global-write warning and continues through the existing replacement flow and create-path hooks, does not delete the new container or workspace volume, and does not invoke bring-up recovery, create or use a recovery helper, or prompt solely because global synchronization failed; the ordinary old-container deletion remains the only expected rebuild deletion

---

### Requirement: Author identity scope and credential non-regression

Author synchronization MUST affect only the resolved connection user in the created or replacement container. It MUST NOT modify global Git configuration for other container users, any host Git configuration, labels, or credential files. This change MUST NOT alter credential-helper behavior, current credential seeding, current `[DIAG]` work, or existing clone/rebuild hook failure cleanup and recovery semantics. Explicit populate, author-write, hook-failure, recovery, and successful-hook regressions MUST preserve those existing outcomes. `up` fresh-create is outside this change and MUST NOT gain this author synchronization behavior.

#### Scenario: Connection-user isolation and host config remain untouched

- Given a complete local identity, a replacement connection user `alice`, another container user `bob`, and host Git configuration containing different author values
- When clone or rebuild synchronizes the identity
- Then only `alice`'s container global Git config changes, `bob`'s global config and the host Git config remain unchanged, and no label or credential file contains the author identity

#### Scenario: Credential forwarding remains separate

- Given a clone or rebuild also exercises the existing HTTPS credential acquisition/seeding path and its current `[DIAG]` instrumentation
- When author identity synchronization runs
- Then credential-helper configuration, credential seeding, `[DIAG]` output/work, and their existing ordering remain unchanged, and on rebuild the author global write follows those existing steps and precedes the first create-path hook

#### Scenario: Clone populate failure retains cleanup and recovery

- Given clone has created its container and workspace volume but in-container populate or `.git` verification fails
- When clone returns the structured failure
- Then clone deletes the created container and workspace volume, does not report success, and retains the existing eligibility and behavior of clone recovery

#### Scenario: Clone author-write failure does not trigger unrelated cleanup

- Given clone populate succeeds, a local or global author write reports failure, and a create-path hook is configured to succeed
- When clone continues after the author-write warning
- Then clone does not delete the container or workspace volume, does not enter recovery solely for the author failure, and the hook runs

#### Scenario: Clone hook failure after identity work retains cleanup

- Given clone has completed its identity work and a create-path hook fails
- When clone handles the hook failure
- Then clone applies the existing container and workspace-volume cleanup and existing recovery eligibility for hook failure, without a new author-specific cleanup path

#### Scenario: Clone author failure does not bypass later cleanup

- Given clone reports a local or global author-write warning and a later create-path hook fails
- When clone handles the hook failure
- Then clone still applies the existing container and workspace-volume cleanup and existing recovery eligibility, without treating the earlier author warning as a reason to skip cleanup

#### Scenario: Clone successful hooks continue after identity work

- Given clone has a complete identity and one or more create-path hooks that succeed
- When clone completes local and global identity writes
- Then the existing create-path hooks run in their existing order and clone succeeds without cleanup

#### Scenario: Rebuild hook failure retains mode-specific cleanup and recovery

- Given rebuild has synchronized identity in the replacement and a create-path hook fails
- When rebuild handles the hook failure
- Then the failed replacement container is handled by the existing rebuild hook-failure cleanup, bind-mode recovery/retention and volume-mode recovery/retained-workspace semantics remain unchanged, and identity synchronization does not invoke a separate recovery path or delete/repopulate the retained workspace volume

#### Scenario: Rebuild successful hooks continue after identity work

- Given rebuild has captured a complete local identity, synchronized it successfully, and its create-path hooks succeed
- When the replacement create path completes
- Then the existing hooks run in their existing order and rebuild succeeds without deleting the replacement container or retained workspace

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

---

### Requirement: Top-level init and securityOpt behavior

The CLI MUST admit top-level `init` when its value is a Boolean. `init: true` MUST request an init process for effective create behavior; `init: false` MUST contribute no init request. Effective init MUST be the Boolean union of top-level `init`, allowlisted `runArgs` `--init`, and compatible Feature/image metadata init contributions. The resulting Apple create argv MUST contain at most one `--init`. A false or absent top-level value MUST NOT veto an init request from another source.

The CLI MUST admit top-level `securityOpt` when its value is an array containing only strings. An empty array MUST have no effect and MUST NOT emit a compatibility issue. In default tolerant mode, a non-empty array MUST emit exactly one ignored compatibility issue per config resolve stating that the property was ignored/not applied on Apple container; when the array includes `no-new-privileges`, the issue MUST explicitly state that `no-new-privileges` is not enforced. No top-level security option MUST reach effective runtime configuration or Apple create argv. In strict compatibility mode, that same issue MUST cause `compatibility_degraded` before the affected runtime action.

Invalid shapes MUST fail closed with a structured error naming the property: `init` values other than Boolean, `securityOpt` values other than an array, and any non-string `securityOpt` entry are invalid. Unknown top-level properties remain governed by **Unsupported property policy**.

For these properties, config hash material MUST represent normalized config-time effective behavior: one effective init request contributes one init entry regardless of duplicate top-level and `runArgs` declarations; false and absent top-level init are equivalent when no other config-time source requests init; and warn-stripped `securityOpt` contributes no hash material. Existing Feature refs/options remain hash inputs under the realized Features identity contract, while Feature init merge MUST still avoid duplicate create tokens.

#### Scenario: Top-level init true maps to create

- Given two otherwise identical image-based configs with no other init source, one with `init: true` and one omitting `init`
- When both configs are resolved and create argv is built
- Then the true form requests init and produces exactly one `--init`, the omitted form produces no `--init`, and their config hashes differ

#### Scenario: Top-level init false is an additive no-op

- Given two otherwise identical configs, one omitting `init` and one setting `init: false`, with no other init source
- When both configs are resolved
- Then neither effective config requests init, neither create argv contains `--init`, and their config hashes are equal

#### Scenario: Top-level and runArgs init deduplicate

- Given two otherwise identical configs whose `runArgs` contain `--init`, one also setting top-level `init: true` and one omitting top-level `init`
- When both configs are resolved and create argv is built
- Then both effective configs produce exactly one `--init` and their config hashes are equal

#### Scenario: Feature and image metadata init union with config init

- Given configs whose top-level `init` is respectively true and false, and each compatible contribution source in turn—Feature metadata and image metadata—requests init
- When each contribution is merged before create
- Then every resulting create argv contains exactly one `--init`: true is deduplicated and false does not veto the metadata request

#### Scenario: Invalid init fails closed

- Given an image-based config whose top-level `init` is a string, number, object, array, or null
- When config admission or resolution runs
- Then the CLI fails with a structured error naming `init` and creates no container

#### Scenario: Non-empty securityOpt warns without enforcement

- Given an image-based config with `securityOpt: ["no-new-privileges"]`
- When the config is resolved and create argv is built in default tolerant mode
- Then resolution succeeds with exactly one ignored compatibility issue stating that the property was not applied and `no-new-privileges` is not enforced
- And no security option reaches effective runtime configuration, create argv, or config hash material

#### Scenario: Other securityOpt values warn and strip

- Given an image-based config with a non-empty string array such as `securityOpt: ["seccomp=profile.json"]`
- When the config is resolved and create argv is built in default tolerant mode
- Then resolution succeeds with exactly one ignored compatibility issue stating that the property was not applied on Apple container
- And no security option reaches effective runtime configuration, create argv, or config hash material

#### Scenario: Empty securityOpt is silent

- Given an image-based config with `securityOpt: []`
- When the config is resolved
- Then resolution succeeds without a securityOpt compatibility issue and the property contributes no effective behavior or hash material

#### Scenario: Invalid securityOpt fails closed

- Given an image-based config whose `securityOpt` is not an array or whose array contains a non-string entry
- When config admission or resolution runs
- Then the CLI fails with a structured error naming `securityOpt` and creates no container

#### Scenario: Ignored securityOpt is hash-neutral

- Given two otherwise identical valid configs, one omitting `securityOpt` and one containing a non-empty string array
- When both configs are resolved in default tolerant mode
- Then their effective runtime configurations and config hashes are equal, while the non-empty form emits its required compatibility issue

#### Scenario: Strict securityOpt blocks before runtime

- Given the same config with `ADEVCONTAINER_STRICT_COMPATIBILITY=1`
- When config is resolved for a runtime command
- Then the command fails with `compatibility_degraded` before the affected create, start, reuse-success, build, or destructive action

---

### Requirement: Bare template compatibility fixtures

The repository MUST retain representative post-template-application fixtures for the active property shapes used by the eleven public Bare Dev Container templates inventoried at `bare-devcontainer/templates@b6a41219`. The fixtures MUST use concrete image tags rather than unresolved `${templateOption:*}` tokens and MUST cover these equivalence classes:

| Fixture class | Required coverage |
|---------------|-------------------|
| Debian | Common baseline: name, image, non-root remoteUser, `runArgs` cap-drop ALL, non-empty securityOpt, and init true |
| uv | Common baseline plus containerEnv, one `${devcontainerId}` named cache volume, and VS Code extensions/settings |
| Go | Common baseline plus multiple `${devcontainerId}` named cache volumes and deeply nested VS Code settings |

All three fixtures MUST resolve without an unsupported-property failure after this change. Each MUST preserve its already-supported effective fields, request exactly one init create token, and warn without claiming enforcement for non-empty securityOpt. This compatibility requirement does not guarantee direct consumption of upstream template source files or actual `no-new-privileges` enforcement.

#### Scenario: Bare Debian baseline resolves

- Given the representative applied Bare Debian fixture
- When the fixture is admitted, resolved, and mapped to create argv
- Then its common baseline fields remain effective, argv includes cap-drop ALL and exactly one `--init`, and securityOpt is warn-stripped without enforcement

#### Scenario: Bare uv rich single-volume profile resolves

- Given the representative applied Bare uv fixture
- When the fixture is resolved
- Then its environment value, `${devcontainerId}` cache volume, and VS Code extensions/settings are retained under their existing contracts, while init and securityOpt follow this change

#### Scenario: Bare Go multi-volume profile resolves

- Given the representative applied Bare Go fixture
- When the fixture is resolved
- Then both cache volumes and nested VS Code settings are retained under their existing contracts, while create argv contains cap-drop ALL and exactly one `--init` and does not contain a security option

---

### Requirement: Deterministic compatibility degradation reporting

The CLI MUST represent every recognized bounded-emulation or warn-and-ignore decision as a compatibility issue with a stable code, property path, disposition (`emulated` or `ignored`), and actionable message describing the effective behavior or omitted semantics. Compatibility issue messages MUST NOT expose secret metadata keys/values, credentials, or other values protected by existing redaction rules.

Within each completed compatibility evaluation boundary, issues MUST be deduplicated by stable code, property path, and safe subject identity, then ordered by property path, code, and safe subject identity. Pre-substitution and post-substitution admission MUST NOT emit duplicate issues for the same input. Each resulting issue MUST emit exactly one `warning: ` line through the existing stderr warning channel in default mode; QUIET MUST NOT suppress it, and warnings MUST NOT contaminate JSON stdout.

Exact translations and explicitly harmless metadata MUST NOT produce compatibility issues. Malformed input and blocked semantics MUST retain specific structured errors rather than being relabeled as degradation.

The first compatibility slice MUST expose these stable issue codes; property path and safe subject identity distinguish individual occurrences:

| Stable code | Registered degradation |
|-------------|------------------------|
| `config_other_ports_attributes_ignored` | Non-empty top-level `otherPortsAttributes` |
| `config_secrets_ignored` | Non-empty top-level `secrets` recommendation metadata |
| `config_privileged_ignored` | Top-level `privileged: true` |
| `config_security_opt_ignored` | Non-empty top-level `securityOpt` |
| `run_arg_ignored` | Each registered Apple-incompatible runArgs entry |
| `docker_feature_ignored` | Each docker-in/outside/from-docker Feature omitted at admission |
| `feature_privileged_ignored` | Feature metadata privilege request omitted |
| `feature_security_opt_ignored` | Feature metadata security options omitted |
| `image_privileged_ignored` | Image metadata privilege request omitted |
| `image_security_opt_ignored` | Image metadata security options omitted |
| `mount_file_bind_promoted` | File-bind source promoted to the documented directory substitute |

This change's compatibility issue vocabulary is exactly the codes in the table. Existing sidecar notices that are not those classification decisions — including the extra NET_ADMIN contextual warning after skipped privileged/device runArgs, `hostRequirements.gpu`, and vscode apply soft-skip warnings — MUST keep their realized default-mode behavior and MUST NOT alone raise `compatibility_degraded`.

Compatibility issue data and presentation text MUST NOT participate in config hash material. Ignored and harmless properties MUST be hash-neutral. Exact translations MUST hash their normalized effective behavior; bounded emulations MUST hash the behavior actually delivered rather than unsupported raw syntax.

#### Scenario: Default mode reports known degradation once

- Given a valid config containing the same known optional unsupported item observed during both admission passes
- When configuration resolution completes in default mode
- Then exactly one compatibility warning with a stable code, property path, ignored disposition, and omitted-semantics explanation is emitted

#### Scenario: Compatibility warnings are deterministic

- Given a config that produces multiple compatibility issues in an evaluation boundary
- When the same config is resolved repeatedly
- Then issue order is stable by property path, code, and safe subject identity and duplicate observations do not add warnings

#### Scenario: Exact and harmless inputs do not warn

- Given a config containing only exact translations and harmless metadata
- When compatibility classification completes
- Then no compatibility degradation warning is emitted

#### Scenario: Compatibility warnings preserve terminal channels

- Given default compatibility mode with `ADEVCONTAINER_QUIET=1` and JSON command output
- When a known optional property is ignored
- Then stderr contains its `warning: ` compatibility issue and stdout remains pure JSON

#### Scenario: Ignored input is hash-neutral

- Given otherwise identical configs where one adds only a known ignored optional property
- When their effective config hashes are computed
- Then the hashes are equal and the config containing the property reports degradation

#### Scenario: Emulation hashes delivered behavior

- Given a supported bounded emulation such as file-bind promotion
- When effective config hash material is produced
- Then the normalized delivered mount behavior participates in the hash and unsupported raw options do not

#### Scenario: Sidecar notices stay outside the issue vocabulary

- Given default or strict mode with `hostRequirements.gpu`, skipped privileged/device runArgs that also produce the extra NET_ADMIN contextual warning, or a vscode apply soft-skip
- When compatibility classification completes
- Then those notices are not compatibility issues, do not use a table code, and do not alone cause `compatibility_degraded`

---

### Requirement: Strict compatibility automation

The environment value `ADEVCONTAINER_STRICT_COMPATIBILITY=1` MUST enable strict compatibility for `up`, `clone`, `rebuild`, `start`, and `exec` when those commands resolve or load Dev Container configuration. Other values and absence MUST select default tolerant mode. Other commands that do not resolve workspace configuration for a runtime action remain unchanged.

In strict mode, any compatibility issue with disposition `ignored` or `emulated` MUST fail the command with structured code `compatibility_degraded`, identify the first deterministically ordered property, and summarize all issue codes without exposing protected values. The gate MUST occur before the affected container create, start, reuse-success, derived-image build, old-container delete, or other destructive lifecycle action. Read-only parse, image inspection, and Feature artifact retrieval needed to classify compatibility MAY occur before the gate.

Strict mode MUST NOT fail solely for harmless metadata or exact translations and MUST NOT alter effective config hash material. Independently malformed or blocked input MUST keep its more specific error instead of becoming `compatibility_degraded`.

#### Scenario: Default tolerant mode continues

- Given a structurally valid config with a known optional ignored property and strict compatibility unset
- When `up`, `clone`, or `rebuild` resolves the config
- Then the command emits the compatibility warning, retains only effective behavior, and MUST NOT fail solely because that property was ignored

#### Scenario: Strict mode blocks degradation before runtime effects

- Given the same config with `ADEVCONTAINER_STRICT_COMPATIBILITY=1`
- When `up`, `clone`, `rebuild`, `start`, or `exec` resolves all compatibility needed for its next runtime action
- Then it fails with `compatibility_degraded` before create, start, reuse-success, user exec, derived-image build, or old-container deletion

#### Scenario: Strict error aggregation is deterministic and redacted

- Given strict mode and multiple ignored or emulated issues including secrets metadata
- When the strict gate fails
- Then the error property is the first deterministic property, its summary lists stable issue codes, and no secret key or value is emitted

#### Scenario: Strict mode accepts exact and harmless inputs

- Given strict mode and a config whose registered properties are exact translations or harmless metadata only
- When the config is resolved
- Then strict compatibility does not fail the command

#### Scenario: Malformed input keeps its specific error

- Given strict mode and a recognized property with an invalid JSON shape
- When admission runs
- Then the command fails with the property-specific structured validation error rather than `compatibility_degraded`

---

### Requirement: Low-risk standard metadata and no-op compatibility

The supported top-level registry MUST admit these standard properties with exact shape validation:

| Property | Shape | Default-mode behavior |
|----------|-------|-----------------------|
| `$schema` | string | Harmless parser/editor metadata; silently ignore; hash-neutral |
| `otherPortsAttributes` | object | Empty object is silent; non-empty object emits one ignored compatibility issue stating that default port UI/auto-forward actions are not applied; hash-neutral |
| `secrets` | object whose entries are objects | Empty object is silent; non-empty object emits one ignored compatibility issue stating that recommendations are not injected or validated; never print entry names or values; hash-neutral |
| `privileged` | Boolean | false is silent; true emits one ignored compatibility issue and contributes no privilege flag or Apple virtualization behavior; hash-neutral |
| `overrideCommand` | Boolean | true is a silent harmless restatement of the product default keep-alive override (hash-neutral; no distinct effective behavior); false remains blocked because the image command is not preserved |

Wrong top-level or required nested shapes MUST fail with a structured error naming the property. These admissions MUST NOT create a generic extension mechanism for arbitrary top-level keys.

#### Scenario: Schema metadata is silent

- Given a valid image config with string `$schema`
- When the config is resolved in default or strict mode
- Then resolution does not fail or warn solely for `$schema`, and its value does not affect the config hash

#### Scenario: Non-empty otherPortsAttributes degrades visibly

- Given a valid config with non-empty object `otherPortsAttributes`
- When the config is resolved in default mode
- Then resolution emits exactly one ignored compatibility issue stating that its port actions are not applied and the property does not affect effective config or hash

#### Scenario: Secrets recommendations are not exposed

- Given a valid config with non-empty object `secrets` containing named recommendation metadata
- When the config is resolved in default or strict mode
- Then default mode emits one property-level ignored issue without secret names or values, strict mode fails with the redacted issue, and neither mode injects secrets

#### Scenario: Privileged true is warn-stripped

- Given a valid config with `privileged: true`
- When create behavior is resolved in default mode
- Then one ignored compatibility issue is emitted and no privileged or virtualization token reaches effective config or Apple create argv

#### Scenario: Harmless false and empty forms are silent

- Given a valid config with `privileged: false`, empty `otherPortsAttributes`, empty `secrets`, and `overrideCommand: true`
- When the config is resolved in default or strict mode
- Then these values emit no compatibility issue and do not affect the config hash

#### Scenario: Override command false remains blocking

- Given a valid image config with `overrideCommand: false`
- When config admission runs
- Then the CLI fails with a structured error explaining that preserving the image command is unsupported

#### Scenario: Invalid metadata shapes remain blocking

- Given `$schema` is not a string, `otherPortsAttributes` or `secrets` is not an object, a secrets entry is not an object, or `privileged`/`overrideCommand` is not Boolean
- When admission runs
- Then the CLI fails with a structured error naming the malformed property

---

### Requirement: Create-name occupancy classification

Before `up` or `clone` creates a container, the CLI MUST classify any existing container whose runtime name equals the desired create name, and MUST classify any existing managed container for the same workspace under a different runtime name.

**Same workspace** means the occupant’s managed labels match this invocation:

| Mode | Matching labels |
|------|-----------------|
| Bind (`up`) | `devcontainer.local_folder` + `devcontainer.config_file` equal this workspace path and config path |
| Volume (`clone`) | `devcontainer.git_url` + config identity (`devcontainer.config_file` / repo-relative config path) equal this normalized git URL and config relative path |

**Classification — MUST**

| Occupant | Command | Outcome |
|----------|---------|---------|
| Same workspace, same create name, managed | `up` | Existing reuse, start-stopped, or `config_hash_mismatch` → hint `rebuild`. MUST NOT offer a rename-to-duplicate path. |
| Same workspace, same create name, managed | `clone` | Fail closed with a structured error naming the existing container. MUST NOT silently reuse, replace, attach, or offer rename-to-duplicate. |
| Same workspace, different runtime name (managed or not) | `up` / `clone` | Fail with a structured error and a delete-hint. MUST NOT offer the foreign-name rename prompt. MUST NOT silently reuse, rename, or attach. |
| Desired create name taken by a different workspace identity, or by an unmanaged container | `up` / `clone` | Foreign occupant — see **Foreign create-name collision offer**. |
| No occupant of the desired create name, and no same-workspace container under another name | `up` / `clone` | Create under the desired create name. |

`start` MUST NOT apply this classification as a create-name collision trigger. `rebuild` MUST NOT use this `up`/`clone` leftover delete-hint; it is the rename / naming-migration path — see **Rebuild replacement create name**.

Idle containers (no `rebuild` or delete) MUST keep their runtime names. `up`/`clone` MUST NOT auto-rename an existing `adev-*` occupant.

#### Scenario: up reuses same-workspace same-name occupant

- Given a managed bind-mode container whose create name equals the desired create name and whose `local_folder`+`config_file` match this workspace
- When the user runs `up` and the stamped config hash matches
- Then the CLI reuses or starts that container and MUST NOT prompt to rename

#### Scenario: up hash mismatch on same-workspace same-name occupant

- Given a managed bind-mode container whose create name equals the desired create name and whose workspace labels match, but stamped `devcontainer.config_hash` differs
- When the user runs `up`
- Then the CLI fails with `config_hash_mismatch`, does not delete the occupant, and does not offer the foreign-name rename prompt

#### Scenario: clone fails closed on same-workspace same-name occupant

- Given a managed volume-mode container whose create name equals the desired create name and whose git URL + config identity match this clone
- When the user runs `clone` for that identity
- Then the CLI fails with a structured error naming the existing container and MUST NOT create, start, populate, or offer rename-to-duplicate

#### Scenario: same-workspace occupant under a different name is a delete-hint

- Given a managed container for this workspace already exists under a different runtime name (including a leftover `adev-*` name)
- When the user runs `up` or `clone` for that workspace
- Then the CLI fails with a structured error that hints to delete the existing container and MUST NOT present the foreign-name rename prompt

#### Scenario: start does not offer create-name collision

- Given a managed container selectable by `--name` or the managed picker, and some other container already uses a name that would collide with a sanitized config `name`
- When the user runs `start`
- Then start does not classify or offer a create-name collision rename prompt

#### Scenario: no idle migration of existing containers

- Given an existing managed container whose runtime name is `adev-{base}-{hash12}`
- When the user does not delete or rebuild it
- Then that container keeps its runtime name and `up`/`clone` do not rename it

---

### Requirement: Rebuild replacement create name

`rebuild` MUST create the replacement container under the **current** computed create name from the live config (sanitized `name` when set, else the mode fallback), not under `selected.name`, when those values differ.

The product MUST NOT delete the selected (old) container until that replacement create name is known and occupiable. If the computed name is taken by a **foreign** occupant, `rebuild` MUST follow **Foreign create-name collision offer** and MUST leave the selected container in place.

When the replacement is created, `rebuild` MUST:

- Reuse the existing product workspace volume `adev-{base}-{hash12}-ws` (volume mode) with its data. MUST NOT rename, delete, or re-populate that volume.
- Reuse user-literal volume `source` strings as written (same attach/reuse as today’s rebuild).
- Expand `${devcontainerId}` in mounts to the **same** resource identity stem as before the rebuild (`adev-{base}-{hash12}`, empty resource base → `adev-{hash12}`), not to the new create name, so those volumes are reused. Config `name` MUST NOT change that stem.

When the computed create name equals the selected name, `rebuild` MUST keep today’s same-name replacement behavior (container-only delete then create under that name).

#### Scenario: rebuild after editing name uses the new create name

- Given a managed container whose live config `name` was edited so the computed create name differs from the selected runtime name
- When the user runs `rebuild` for that selected container and the new name is occupiable
- Then the replacement is created under the new computed create name, the old container is gone, the product `*-ws` volume is reused with its data, and user-literal volume sources remain attached as written

#### Scenario: rebuild migrates an adev-* name to the short computed name

- Given a managed container named `adev-myapp-abc123def456` whose live config `name` still sanitizes to `myapp`
- When the user runs `rebuild` for that selected container and `myapp` is occupiable
- Then the replacement is named `myapp`, the old `adev-myapp-abc123def456` container is gone, and the product `*-ws` volume is reused

#### Scenario: rebuild same computed name is unchanged

- Given a managed container whose selected runtime name already equals the live computed create name
- When the user runs `rebuild` for that container
- Then the replacement is created under that same name (today’s same-name rebuild)

#### Scenario: rebuild foreign occupant does not delete the selected container

- Given a managed container selected for rebuild whose computed create name is taken by a foreign occupant
- When the user runs `rebuild`
- Then the CLI MUST NOT delete the selected container and MUST follow **Foreign create-name collision offer** (TTY change-name prompt, or non-TTY/`--json` structured fail + hint)

#### Scenario: rebuild keeps the same devcontainerId stem when create name changes

- Given a bind workspace folder `foo` (or volume-mode repo basename `foo`) whose identity stem is `adev-foo-{hash12}`, a volume mount `source=${devcontainerId}-shellhistory`, and a rebuild that only changes config `name` so the create name becomes `myapp`
- When the replacement is created
- Then that mount source is still `adev-foo-{hash12}-shellhistory` and the shell-history volume is reused

---

### Requirement: Foreign create-name collision offer

When occupancy classification yields a **foreign occupant** of the desired create name on `up`, `clone`, or `rebuild`, the CLI MUST warn that the name is in use and is not the same workspace, and MUST NOT delete, replace, or attach to that occupant. On `rebuild`, the selected container MUST remain until the replacement create name is known and occupiable. The CLI MUST NOT open bring-up recovery or any editor on this path, MUST NOT offer a suffix-append choice, and MUST NOT present a two-option recovery list.

**TTY (stdin is a TTY and `--json` is absent) — MUST**

1. Emit the warning with that reason.
2. Ask whether the user wants to change the name (Y/n) on stderr. This prompt is interactive and MUST remain usable under QUIET (not a silenced progress line).
3. On yes: prompt for the new **full** name (not a suffix appended to the current base). Sanitize with the same DNS-safe rules as create-name identity (no `adev-` prefix, no identity hash, ≤ 63 characters). Persist that sanitized value into the editable config `name` (`up`: host `devcontainer.json`; `clone`: retained checkout; `rebuild`: the live config this rebuild is reading) so the next `up`/`clone`/`rebuild` of this config is stable, then retry MUST re-resolve. MUST NOT delete the occupant (on `rebuild`, MUST NOT delete the selected container).
4. A name that is empty after sanitize, or that is not a DNS-safe name of at most 63 characters, MUST re-prompt for the new name without persisting.
5. If the name after persist is still a foreign occupant (or otherwise still collides), the CLI MUST re-ask (warn that this name is also in use, then Y/n again).
6. Decline, cancel, or EOF at the Y/n prompt or the name prompt MUST fail with the original structured name-in-use error. The occupant MUST remain untouched.
7. A successful `clone` retry after a persisted `name` MUST leave that `name` in the workspace `devcontainer.json` after populate, matching **Clone recovery persists edited config into workspace**. Bind `up` remains host-edit only.

**Non-TTY or `--json` — MUST**

- Never prompt, never open an editor, never collect a new name.
- Fail with a structured error plus an edit/retry hint (`up`: host config path; `clone`: retained checkout and exact retry command when retention applies; `rebuild`: hint to free or change `name` and retry `rebuild --name` of the still-present selected container).
- Leave the occupant untouched. On `rebuild`, the selected container MUST still exist.

`start` MUST NOT offer this rename prompt. `rebuild` MUST offer it when the computed replacement name is a foreign occupant.

#### Scenario: TTY asks whether to change the name

- Given the desired create name is already used by a container for a different workspace (or an unmanaged container), and stdin is a TTY without `--json`
- When the user runs `up`, `clone`, or `rebuild`
- Then the CLI warns that the name is in use and not the same workspace, and asks whether to change the name (Y/n) on stderr
- And the CLI MUST NOT open an editor or present an editor-or-suffix list

#### Scenario: yes prompts for the new full name and persists it

- Given a TTY foreign-name offer
- When the user affirms and types `My App 2` (or `my-app-2`)
- Then the product persists `name` as `my-app-2` (or the equivalent sanitized result) into the editable config, retries from a re-resolve, and creates under that name when it is free
- And the foreign occupant still exists unchanged

#### Scenario: successful clone rename retry leaves name in the workspace config

- Given a TTY foreign-name offer on `clone`, a persisted new `name`, and a successful retry through populate
- When the workspace `devcontainer.json` is read inside the new container
- Then `name` is the persisted create name, not the original git-populated value

#### Scenario: empty or invalid name re-prompts

- Given a TTY foreign-name offer and the user affirmed the change-name question
- When the user types a name that sanitizes to empty or is not DNS-safe within 63 characters
- Then the CLI does not persist `name` and re-prompts for the new name

#### Scenario: still-colliding name re-asks

- Given a TTY foreign-name offer and the user types a new name that is also occupied by a foreign occupant
- When that name would be persisted
- Then the CLI does not delete either occupant and re-asks whether to change the name

#### Scenario: decline leaves the occupant untouched

- Given a TTY foreign-name offer
- When the user declines, cancels, or sends EOF
- Then the CLI fails with the original name-in-use error and the occupant is unchanged

#### Scenario: non-TTY and json never prompt

- Given the same foreign occupant and a non-TTY stdin or `--json`
- When the user runs `up`, `clone`, or `rebuild`
- Then the CLI never prompts or opens an editor, fails with a structured error plus an edit/retry hint, and leaves the occupant untouched
- And on `rebuild` the selected container is still present

#### Scenario: rename prompts remain usable under QUIET

- Given `ADEVCONTAINER_QUIET=1` and a TTY foreign-name offer
- When the Y/n or new-name prompt is presented
- Then those prompts and the warning remain usable on stderr (not classified as silenced progress)

---

### Requirement: Hashed sidecar names and literal volume sources stay

This change MUST NOT use config `name` as the **base** of product-generated Features tags, product workspace volumes, or `${devcontainerId}`. Those stay hashed `adev-{base}:…` / `adev-{base}-{hash12}-ws` / `adev-{base}-{hash12}` where **base** is the workspace/repo basename only. User-literal volume `source` strings stay as written.

- Features derived tags MUST remain `adev-{base}:{contentHash}` where `base` is the resource base (about-20-character clip of the workspace folder basename on `up`, or git URL repo basename on `clone`) and `contentHash` is the Features content hash including `recipeVersion`. Empty resource base MUST still map to `adevcontainer:{contentHash}`. MUST NOT use sanitized config `name` or the short create name as the tag, and MUST NOT drop the `adev-` tag prefix.
- Volume-mode product workspace volumes MUST remain `adev-{base}-{hash12}-ws` using that same resource base and the volume-mode identity `hash12` (normalized git URL + config relative path). MUST NOT rename the workspace volume to the short create name or to sanitized config `name`.
- A config or feature mount `source` that is a user-written literal (no unsubstituted `${devcontainerId}` token) MUST be used as written. The product MUST NOT rewrite that literal to include the create name, an `adev-` prefix, or an identity hash.
- `${devcontainerId}` MUST expand to the resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`), using the same hash material and the same resource base as the product workspace volume. It MUST NOT expand to the create `--name` / DNS hostname and MUST NOT include sanitized config `name` in the stem. This is not a rewrite of a user-literal source.

#### Scenario: Features tag keeps hashed adev- form

- Given a Features build in workspace folder `foo` with `"name": "My App"`
- When the derived image tag is computed
- Then the tag is `adev-foo:{contentHash}` and is not `adev-my-app:{contentHash}` or `my-app:{contentHash}`

#### Scenario: workspace volume keeps hashed adev- form

- Given a clone whose git URL repo basename is `foo`, config `"name": "My App"`, and identity `hash12`
- When the workspace volume name is computed
- Then the volume name is `adev-foo-{hash12}-ws` and is not `adev-my-app-{hash12}-ws` or `my-app-ws`

#### Scenario: user-literal volume source is not rewritten

- Given a config `type=volume` mount whose `source` is the literal `team-cache`
- When the container is created or rebuilt under create name `my-app`
- Then the volume source remains `team-cache` and is not rewritten to `my-app-team-cache` or `adev-my-app-{hash}-team-cache`

#### Scenario: devcontainerId token expands to the resource identity stem

- Given a feature mount `source=${devcontainerId}-shellhistory`, config `"name": "My App"`, workspace folder basename `foo`, and identity `hash12`
- When the container is created
- Then the create name is `my-app` and the volume name is `adev-foo-{hash12}-shellhistory` (not `adev-my-app-{hash12}-shellhistory` or `my-app-shellhistory`)

#### Scenario: bind and volume devcontainerId stems stay distinct

- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`, both without an overriding `name`
- When `${devcontainerId}` is expanded
- Then the bind stem uses path+config `hash12` and the volume stem uses git URL+config relpath `hash12`, matching each mode’s `*-ws` material, so the stems are not required to match

---

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

---

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
