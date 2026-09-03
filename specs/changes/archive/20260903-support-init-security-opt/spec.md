# Change Spec: support-init-security-opt

## ADDED Requirements

### Requirement: Top-level init and securityOpt behavior

The CLI MUST admit top-level `init` when its value is a Boolean. `init: true` MUST request an init process for effective create behavior; `init: false` MUST contribute no init request. Effective init MUST be the Boolean union of top-level `init`, allowlisted `runArgs` `--init`, and compatible Feature/image metadata init contributions. The resulting Apple create argv MUST contain at most one `--init`. A false or absent top-level value MUST NOT veto an init request from another source.

The CLI MUST admit top-level `securityOpt` when its value is an array containing only strings. An empty array MUST have no effect and MUST NOT emit a warning. A non-empty array MUST emit exactly one stderr warning per config resolve stating that the property was ignored/not applied on Apple container; when the array includes `no-new-privileges`, the warning MUST explicitly state that `no-new-privileges` is not enforced. No top-level security option MUST reach effective runtime configuration or Apple create argv.

Invalid shapes MUST fail closed with a structured error naming the property: `init` values other than Boolean, `securityOpt` values other than an array, and any non-string `securityOpt` entry are invalid. Unknown top-level properties remain governed by the realized fail-closed policy.

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
- When the config is resolved and create argv is built
- Then resolution succeeds with exactly one stderr warning stating that the property was not applied and `no-new-privileges` is not enforced
- And no security option reaches effective runtime configuration, create argv, or config hash material

#### Scenario: Other securityOpt values warn and strip

- Given an image-based config with a non-empty string array such as `securityOpt: ["seccomp=profile.json"]`
- When the config is resolved and create argv is built
- Then resolution succeeds with exactly one stderr warning stating that the property was not applied on Apple container
- And no security option reaches effective runtime configuration, create argv, or config hash material

#### Scenario: Empty securityOpt is silent

- Given an image-based config with `securityOpt: []`
- When the config is resolved
- Then resolution succeeds without a securityOpt warning and the property contributes no effective behavior or hash material

#### Scenario: Invalid securityOpt fails closed

- Given an image-based config whose `securityOpt` is not an array or whose array contains a non-string entry
- When config admission or resolution runs
- Then the CLI fails with a structured error naming `securityOpt` and creates no container

#### Scenario: Ignored securityOpt is hash-neutral

- Given two otherwise identical valid configs, one omitting `securityOpt` and one containing a non-empty string array
- When both configs are resolved
- Then their effective runtime configurations and config hashes are equal, while the non-empty form emits its required warning

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

## MODIFIED Requirements

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

The CLI MUST accept and honor the property surface below. Properties outside this surface that are hard-error (Compose, unknown-dangerous) or unknown-dangerous MUST hard-error (see Unsupported property policy). Known optional Apple-incompatibles are warn-skip, not hard-error. Parseable `customizations.vscode.extensions` / `settings` are **honored by apply**, not ignored, while still never failing parse solely for presence. Other benign editor metadata MAY be ignored per Unsupported property policy.

**Image & workspace**
- `name` (optional; when non-empty after trim, drives the DNS-friendly create name and does not drive the resource base, per the live Deterministic identity and labels contract)
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
- `initializeCommand` — string, argv array, or object map; host command per [lifecycle-hooks.md](../../../lifecycle-hooks.md) **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and [vscode.md](../../../vscode.md) **postAttachCommand policy (CLI-only)**
- `waitFor` — enum; default `updateContentCommand`; policy per **waitFor readiness**
- `userEnvProbe` — enum; default `loginInteractiveShell`; policy per **userEnvProbe merge**
- `shutdownAction` — enum; default `stopContainer` for this image/Dockerfile product; `stopCompose` fails closed; policy per **shutdownAction admission**

**Runtime options, runArgs, and hostRequirements**
- `init` — Boolean; true requests one effective `--init`, unioned and deduplicated with `runArgs` and Feature/image init contributions; false is an additive no-op
- `securityOpt` — array of strings; empty is a silent no-op, non-empty is explicitly warn-skipped and never represented as enforced
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

See also: [lifecycle-hooks.md](../../../lifecycle-hooks.md), [runargs-host.md](../../../runargs-host.md), [features.md](../../../features.md), [vscode.md](../../../vscode.md) for detailed property behavior; **Remote connection user resolution** and **Create process user** for the user chain and create `-u`.
