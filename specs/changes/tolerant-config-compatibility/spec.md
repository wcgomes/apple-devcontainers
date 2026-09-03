# Change Spec: tolerant-config-compatibility

## ADDED Requirements

### Requirement: Deterministic compatibility degradation reporting

Merge target: [core.md](../../core.md).

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

Merge target: [core.md](../../core.md).

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

Merge target: [core.md](../../core.md).

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

### Requirement: Top-level capAdd translation

Merge target: [runargs-host.md](../../runargs-host.md).

The CLI MUST admit top-level `capAdd` only as an array of non-empty capability-name strings accepted by the existing `--cap-add` validation. Valid entries MUST normalize into the same typed effective capability representation and Apple create tokens used by allowlisted `runArgs --cap-add` and Feature/image `capAdd` contributions. The product MUST NOT pass raw array entries directly to Apple `container`.

Top-level and runArgs capability declarations MUST deduplicate by normalized capability name while preserving deterministic order. Equivalent config-time declarations through top-level `capAdd` and `runArgs --cap-add` MUST produce equivalent effective config hash material. Feature references/options remain their existing identity inputs even when a Feature capability contribution deduplicates against config-time capability behavior.

An omitted or empty top-level array MUST be a silent no-op. A non-array value, non-string entry, empty name, name beginning with `-`, or otherwise invalid capability name MUST fail with a structured error naming `capAdd` before create.

#### Scenario: Top-level capAdd maps through the typed create path

- Given a config with `capAdd: ["SYS_PTRACE", "NET_ADMIN"]`
- When the config is resolved and create argv is built
- Then effective capabilities contain both names and argv contains typed `--cap-add` pairs without raw passthrough

#### Scenario: Top-level and runArgs capAdd deduplicate

- Given otherwise identical configs where one declares `SYS_PTRACE` top-level and the other through allowlisted runArgs, including a config declaring both
- When effective config and hash material are produced
- Then all forms contain one normalized capability entry, equivalent config-time forms hash equally, and create argv contains one token pair

#### Scenario: Feature capability still preserves Feature identity

- Given top-level `capAdd` and an admitted Feature both contribute the same capability
- When Feature contributions merge
- Then create argv contains one capability token pair while the Feature ref/options remain in existing config and derived-image identity material

#### Scenario: Empty capAdd is silent

- Given `capAdd: []`
- When the config is resolved in default or strict mode
- Then resolution succeeds without a compatibility issue and no capability token is added

#### Scenario: Invalid capAdd blocks before create

- Given top-level `capAdd` is not an array or contains a non-string, empty, dash-prefixed, or invalid capability name
- When admission runs
- Then the CLI fails with a structured error naming `capAdd` and creates no container

## MODIFIED Requirements

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

Merge target: [core.md](../../core.md).

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
- `initializeCommand` — string, argv array, or object map; host command per [lifecycle-hooks.md](../../lifecycle-hooks.md) **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and [vscode.md](../../vscode.md) **postAttachCommand policy (CLI-only)**
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

See also: [lifecycle-hooks.md](../../lifecycle-hooks.md), [runargs-host.md](../../runargs-host.md), [features.md](../../features.md), [vscode.md](../../vscode.md) for detailed property behavior; **Remote connection user resolution** and **Create process user** for the user chain and create `-u`.

---

### Requirement: Unsupported property policy

Merge target: [core.md](../../core.md).

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

### Requirement: Top-level init and securityOpt behavior

Merge target: [core.md](../../core.md).

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

## REMOVED Requirements

None.
