# Change Spec: adevcontainer-core

## ADDED Requirements

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

### Requirement: Supported property surface (Phases 0–3)

The CLI MUST accept and honor only the MVP property surface below. Properties outside this surface that are forever-rejected or unknown-dangerous MUST hard-error (see Unsupported property policy). Benign editor metadata MAY be ignored per that policy.

**Phase 0**
- `name` (optional label; MAY be stored)
- `image` (required for MVP image-based workspaces)
- Implicit workspace bind: host workspace root → container workspace folder

**Phase 1**
- `containerEnv` (map of string → string, post-substitution)
- `remoteUser` and/or `containerUser` (non-root or named user when set)
- `workspaceFolder` (container cwd / remote workspace folder)

**Phase 2**
- `mounts` — bind and volume entries (string or object form consistent with devcontainers mount syntax subset)
- `forwardPorts` — published to the Apple container as port publish/mappings
- `portsAttributes` — retained and surfaced as metadata only (no IDE auto-forward semantics promised)

**Phase 3**
- `postCreateCommand` — string or argv array; executed via runtime exec after create/start; non-zero exit MUST fail `up`

#### Scenario: Phase 0 minimal config
- Given fixture `Tests/Fixtures/smoke.json` as the workspace config
- When the user runs a successful `up` then `exec`
- Then a container runs from the specified image with the workspace bound and an interactive or command exec succeeds

#### Scenario: Phase 1 env user folder
- Given fixture `Tests/Fixtures/env-user.json`
- When `up` succeeds
- Then container env includes configured `containerEnv`, process user matches `remoteUser`/`containerUser` policy, and default cwd is `workspaceFolder`

#### Scenario: Phase 2 mounts and ports
- Given fixture `Tests/Fixtures/mounts-ports.json`
- When `up` succeeds
- Then bind and volume mounts are applied, `forwardPorts` are published, and `portsAttributes` are available via `inspect` metadata without affecting publish success

#### Scenario: Phase 3 postCreate success
- Given fixture `Tests/Fixtures/lifecycle.json` with a `postCreateCommand` that exits 0
- When `up` runs
- Then postCreate runs via exec after the container is up and `up` reports success

#### Scenario: Phase 3 postCreate failure
- Given a config whose `postCreateCommand` exits non-zero
- When `up` runs
- Then `up` fails with a structured error including the exit code and MUST NOT report overall success

---

### Requirement: Unsupported property policy

The CLI MUST fail closed on unsupported or forever-rejected configuration. Errors MUST be structured and actionable: identify the property/flag, state that it is unsupported, and indicate what to remove or change. The CLI MUST NEVER silently ignore forever-rejected or unknown-dangerous entries.

**Forever reject (v1)**
- Feature id `ghcr.io/devcontainers/features/docker-outside-of-docker` (any tag/version suffix)
- Any `features` entry on the MVP path (features runner is post-MVP); docker-ood remains forever-reject even after features land
- `runArgs` containing `--privileged`
- `runArgs` containing `--device=…` (including `/dev/net/tun`)
- Unknown `runArgs` not on the explicit allowlist (MVP allowlist MAY be empty)
- Docker Compose keys / compose-file driven multi-service config (e.g. `dockerComposeFile`, `service`, and equivalent compose driver keys)

**May ignore or store as metadata (MUST NOT fail parse)**
- `customizations.vscode` (and nested extensions/settings)
- Other purely informational keys explicitly classified as metadata (e.g. optional `name` already in surface; `hostRequirements` MAY warn or ignore without failing MVP parse unless product later tightens)

**Unknown non-metadata properties**
- MUST hard-error with structured unsupported-property detail (fail closed).

#### Scenario: Reject docker-outside-of-docker
- Given a config with `features` including `ghcr.io/devcontainers/features/docker-outside-of-docker:1`
- When config is validated
- Then the CLI fails with a structured error naming the feature and the reject policy

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
- Given a config that is otherwise Phase-0-valid and includes `customizations.vscode.extensions`
- When config is parsed and validated
- Then validation succeeds and `up` is not blocked solely by `customizations.vscode`

#### Scenario: Unknown dangerous runArgs
- Given `runArgs` including a flag not on the allowlist (e.g. `--cap-add=NET_ADMIN`)
- When config is validated
- Then the CLI fails with a structured error naming that entry

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

On create, the CLI MUST assign a deterministic container name derived from workspace path and config identity, and MUST set labels:

| Label | Purpose |
|-------|---------|
| `devcontainer.local_folder` | Absolute workspace path |
| `devcontainer.config_file` | Absolute config file path used |
| App config hash label (stable key, e.g. `devcontainer.config_hash`) | Hash of resolved supporting config for drift detection |

Discovery and reuse MUST prefer deterministic name + inspect, NOT Docker-style `ps --filter label=` as the primary mechanism.

#### Scenario: Stable name across invocations
- Given the same workspace path and config content
- When `up` is invoked twice without delete
- Then the second invocation reuses the same container identity rather than creating a conflicting duplicate

#### Scenario: Labels present on inspect
- Given a container created by `up`
- When the user runs `adevcontainer inspect`
- Then local folder, config file, and config hash labels/fields are visible in the inspect output

---

### Requirement: Up lifecycle (create, start, reuse)

`adevcontainer up` MUST resolve config, admit properties, and ensure a running workspace container: create if missing, start if stopped, reuse if already running with matching identity. Workspace bind MUST mount the host workspace into the container workspace folder. `up` MUST support a machine-readable JSON result on success (and structured failure otherwise).

**Success JSON fields (required)**
- `outcome` — success indicator consistent with reference CLI style (e.g. `"success"`)
- `containerId` — runtime container id
- `remoteUser` — effective remote/container user (may be empty/default if unset)
- `remoteWorkspaceFolder` — absolute path inside the container used as workspace folder

Additional helpful fields (e.g. `containerName`) MAY be included.

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

### Requirement: Phase fixtures

The repository MUST provide pure JSON phase fixtures used by tests and docs:

| Path | Phase |
|------|-------|
| `Tests/Fixtures/smoke.json` | 0 |
| `Tests/Fixtures/env-user.json` | 1 |
| `Tests/Fixtures/mounts-ports.json` | 2 |
| `Tests/Fixtures/lifecycle.json` | 3 |

Fixtures MUST be valid for their phase (no forever-rejected props). They SHOULD align field styles with `reference/devcontainer.json` where applicable (image family, env keys, mount shapes, ports) while remaining Apple-container-runnable for MVP.

#### Scenario: Fixtures are parseable MVP configs
- Given each file under `Tests/Fixtures/`
- When parsed with JSONC/JSON rules and validated against MVP admission
- Then each fixture is admitted for its phase without unsupported-property errors
