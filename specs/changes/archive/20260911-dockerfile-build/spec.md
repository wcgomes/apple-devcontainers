# Change Spec: dockerfile-build

## ADDED Requirements

### Requirement: Nested build xor image admission

The CLI MUST admit exactly one configuration source selector: top-level `image` **or** nested `build`, never both and never neither. Nested `build` MUST be an object. `build.dockerfile` MUST be a non-empty string. `build.context` MAY be omitted and MUST then default to `"."`. `build.args` MAY be omitted; when present it MUST be a map of string keys to string values, and those values MUST receive the existing substitution subset. `build.target` MAY be omitted; when present it MUST be a string.

Any other nested `build.*` key, including `options`, `cacheFrom`, and `cacheTo`, MUST fail closed with a structured error naming property `build` and the unknown key. Top-level `dockerFile`, `dockerfile`, and `context` MUST remain blocked even when nested `build` is present. Docker Compose keys remain blocked.

A config that sets both `image` and nested `build`, or that sets neither, MUST fail closed before create. Invalid shapes (non-object `build`, non-string `dockerfile` / `context` / `target`, non-string `args` values) MUST fail closed with a structured error naming property `build`.

#### Scenario: Nested build without image admits

- Given a config whose only source selector is nested `build` with `dockerfile` set and no top-level `image`
- When config is admitted and resolved
- Then admission succeeds and the resolved model carries dockerfile, context (default `"."` when omitted), optional args, and optional target

#### Scenario: Image and nested build together fail

- Given a config that sets both top-level `image` and nested `build`
- When admission runs
- Then the CLI fails with a structured error naming property `build` and creates no container

#### Scenario: Neither image nor nested build fails

- Given a config that sets neither top-level `image` nor nested `build`
- When admission runs
- Then the CLI fails with a structured error and creates no container

#### Scenario: Top-level dockerfile selectors remain blocked

- Given an otherwise valid config that sets top-level `dockerFile`, `dockerfile`, or `context`
- When admission runs
- Then the CLI fails with a structured unsupported-property error naming that top-level key

#### Scenario: Unknown nested build key fails closed

- Given nested `build` that includes `options`, `cacheFrom`, `cacheTo`, or another key other than `dockerfile`, `context`, `args`, and `target`
- When admission runs
- Then the CLI fails with a structured error naming property `build` and the unknown key

#### Scenario: Missing build.dockerfile fails

- Given nested `build` without a non-empty `dockerfile` string
- When admission runs
- Then the CLI fails with a structured error naming property `build`

#### Scenario: Omitted build.context defaults to dot

- Given nested `build` with `dockerfile` set and `context` omitted
- When config is resolved
- Then the effective context is `"."`

#### Scenario: Non-string build.args or target fails closed

- Given nested `build` whose `args` is not a string map or whose `target` is not a string
- When admission runs
- Then the CLI fails with a structured error naming property `build`

#### Scenario: build.args receive substitution

- Given nested `build.args` whose values contain `${localWorkspaceFolder}` or `${localEnv:VAR}`
- When config is resolved
- Then those tokens are replaced per the existing substitution subset

---

### Requirement: Dockerfile image build on create paths

On `up` fresh create and `clone` create, when nested `build` is admitted, the product MUST build or reuse a local image from the user Dockerfile **before** Features work and **before** create. On `rebuild` replacement, when nested `build` is admitted, the product MUST invoke `container build` for that image **before** Features work and **before** create.

Dockerfile and context paths MUST be resolved against the config-file directory. On `clone`, both paths MUST resolve inside the config-file directory; a `..` segment that escapes that directory MUST fail closed. Root `.devcontainer.json` with a sibling `Dockerfile` and context `"."` MUST be allowed. Bind-mode `up` and `rebuild` MAY use `context: ".."`. Clone's config-only fetch MUST materialize the admitted dockerfile and context paths when they resolve inside the config-file directory.

Missing dockerfile file or missing context directory MUST fail with a structured error naming property `build` before create. The product MUST NOT substitute a different image.

On clone-origin / volume-mode `rebuild`, the product MUST stage the **config-file directory** (not the whole workspace) so the product tag hash uses **real Dockerfile file bytes** (not empty) and `container build` can run. Typical `.devcontainer/devcontainer.json` plus a sibling Dockerfile with context `"."` uses that directory. Root `.devcontainer.json` plus a sibling `Dockerfile` with context `"."` MUST stage files at that config-file directory level (root files and same-level siblings), MUST NOT skip `context: "."`, and MUST NOT require `src/` or other unfetched workspace trees as context. Clone still forbids `..`. Bind-mode `up` and `rebuild` keep the host workspace as context. If that dockerfile or context material is missing, the product MUST fail with a structured error code `dockerfile_build` naming property `build` **before** deleting the old container.

The build MUST use Apple `container build` with `--platform linux/arm64` on Apple Silicon (same host-native platform as Features). The product MUST apply the same `build.rosetta=false` consent gate as Features before this build, and MUST NOT pass `--rosetta` unless the user opted in via `runArgs`. When both nested `build` and Features run on one create path, the consent gate MUST run at most once.

When `build.args` is present, the product MUST pass each pair to `container build` as `--build-arg`. When `build.target` is present, the product MUST pass it as `--target`. If Apple `container build` does not accept `--build-arg` or `--target`, the product MUST fail closed with a structured error naming that key (`args` or `target`) and MUST NOT invent a workaround.

The product-built tag MUST be `adev-{base}-df:{hash12}` (empty resource base → `adevcontainer-df:{hash12}`), distinct from Features `adev-{base}:{hash12}`. Tag hash material MUST be Dockerfile file bytes + context path + args + target. When that tag already exists locally, `up` and `clone` MUST reuse it and MUST NOT invoke `container build`. `rebuild` MUST invoke `container build` even when that tag already exists (the same tag name is allowed) so unhashed COPY sources are picked up. `--skip-pull` MUST NOT skip this local Dockerfile build or that `up`/`clone` reuse; it remains a skip of the product's explicit image-pull step only.

Progress MUST emit `==> Building image` when `container build` runs and `==> Reusing image` when the product tag is reused (StatusPrinter family; `ADEVCONTAINER_QUIET=1` silences these as other phase lines). Build and dockerfile-path failures MUST use error code `dockerfile_build` and property `build`, and MUST NOT use Features-branded codes or properties.

When Features are also admitted, the product MUST obtain the user Dockerfile tag first (`up`/`clone` build or reuse; `rebuild` always `container build`), then run Features with that tag as the `FROM` base (same effective-image swap as today). On `rebuild` with nested `build` and Features, the product MUST invoke Features `container build` even when the Features derived tag already exists (the same tag name is allowed), so the force-rebuilt product Dockerfile tag becomes the Features `FROM` base. `up` and `clone` MUST still reuse an existing Features derived tag. The operator MUST NOT be required to delete images for that Features rebuild. When Features are absent, create MUST use the product Dockerfile tag. Reuse-running and start-stopped paths MUST NOT rebuild the Dockerfile.

#### Scenario: Fresh up builds and creates from the product Dockerfile tag

- Given a bind-mode workspace whose config has nested `build` and no `features`, and the product tag does not exist locally
- When the user runs `adevcontainer up` on a fresh create path
- Then `container build` runs with `--platform linux/arm64` and no `--rosetta` unless opted in via `runArgs`
- And create uses tag `adev-{base}-df:{hash12}` (or `adevcontainer-df:{hash12}` when base is empty)

#### Scenario: Existing product Dockerfile tag is reused

- Given the deterministic product Dockerfile tag already exists locally for the same Dockerfile bytes, context path, args, and target
- When `up` or `clone` runs the Dockerfile path
- Then no `container build` is invoked and create uses the existing tag
- And stderr includes `==> Reusing image` when quiet mode is unset

#### Scenario: skip-pull does not skip local Dockerfile build

- Given nested `build` and `--skip-pull`, and the product tag does not exist locally
- When `up`, `clone`, or `rebuild` runs
- Then the local Dockerfile build still runs (or fails as a dockerfile build), and `--skip-pull` does not skip it

#### Scenario: build.args map to --build-arg or fail naming args

- Given nested `build.args` as a string map
- When the Dockerfile build runs
- Then each pair is passed to `container build` as `--build-arg`
- And if the runtime does not accept `--build-arg`, the command fails structured naming `args` and does not invent a workaround

#### Scenario: build.target maps to --target or fail naming target

- Given nested `build.target` as a string
- When the Dockerfile build runs
- Then `container build` includes `--target` with that value
- And if the runtime does not accept `--target`, the command fails structured naming `target` and does not invent a workaround

#### Scenario: Missing dockerfile file fails structured

- Given nested `build.dockerfile` that does not exist on disk after resolve
- When a create path runs
- Then the CLI fails with a structured `dockerfile_build` error naming property `build` and creates no container

#### Scenario: Missing context directory fails structured

- Given nested `build.context` that does not exist as a directory after resolve
- When a create path runs
- Then the CLI fails with a structured `dockerfile_build` error naming property `build` and creates no container

#### Scenario: Progress Building image during dockerfile build

- Given nested `build`, quiet mode unset, and the product tag missing
- When the Dockerfile build runs
- Then stderr includes `==> Building image` in the StatusPrinter family

#### Scenario: Dockerfile build failure is not Features-branded

- Given `container build` of the user Dockerfile exits non-zero
- When the Dockerfile path runs
- Then the CLI fails with code `dockerfile_build` and property `build`
- And the error is not Features-branded (`feature_build` / property `features`)
- And no managed dev container is created

#### Scenario: build.rosetta gate runs before dockerfile build

- Given nested `build` on a create path and effective `build.rosetta` is not already `false`
- When the Dockerfile path starts
- Then the same `build.rosetta=false` consent gate as Features runs before `container build`
- And when Features also run on that path, the gate runs at most once

#### Scenario: Clone in-directory dockerfile builds

- Given clone config `.devcontainer.json` at the repo root with sibling `Dockerfile` and `build.context` `"."` (or `.devcontainer/devcontainer.json` with dockerfile and context inside that directory)
- When the user runs `adevcontainer clone <git-url>`
- Then clone materializes those files, the Dockerfile path runs, and create uses the product Dockerfile tag (then Features when admitted)

#### Scenario: Clone context parent is rejected

- Given a clone config whose `build.context` or dockerfile path resolves outside the config-file directory via `..`
- When clone resolve or the Dockerfile path runs
- Then the CLI fails closed with a structured error naming property `build` and does not create a container

#### Scenario: Bind up may use context parent

- Given bind-mode `.devcontainer/devcontainer.json` with nested `build.context` `".."` whose resolved context is the workspace root
- When the user runs `adevcontainer up`
- Then admission does not fail solely because context is `".."`, and the Dockerfile path uses that context

#### Scenario: Rebuild takes the dockerfile path

- Given a managed container whose current config has nested `build`, and the deterministic product Dockerfile tag already exists locally
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then `container build` is invoked (the same tag name is allowed) so unhashed COPY sources are picked up
- And the replacement create path uses the product Dockerfile tag before create (and before old-container delete on the Features pre-delete gate when Features are also present)
- And stderr includes `==> Building image` when quiet mode is unset

#### Scenario: Volume-mode rebuild uses real Dockerfile bytes

- Given a clone-origin / volume-mode managed container whose current config has nested `build`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the product stages the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes (not empty) and `container build` can run

#### Scenario: Volume-mode rebuild root-sibling context stages config-dir siblings

- Given a clone-origin / volume-mode managed container whose config is root `.devcontainer.json` with a sibling `Dockerfile` and `build.context` `"."`
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then staged context includes files at that config-file directory level (root files and same-level siblings), not only the Dockerfile file
- And `src/` and other unfetched workspace trees are not required as context
- And `context: "."` is not skipped

#### Scenario: Volume-mode rebuild missing dockerfile material fails before delete

- Given a clone-origin / volume-mode managed container whose current config has nested `build`, and the stamped guest dockerfile or context is missing
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then the CLI fails with a structured `dockerfile_build` error naming property `build`
- And the old container is not deleted

#### Scenario: Features FROM the dockerfile tag when both are present

- Given a config with nested `build` and a non-empty admitted `features` map
- When `up`, `clone`, or `rebuild` runs a fresh create path
- Then the user Dockerfile is built or reused first on `up`/`clone`, and `container build` runs first on `rebuild`
- And Features `FROM`s that product Dockerfile tag (not a config `image`)
- And create uses the Features derived tag

#### Scenario: Rebuild with nested build rebuilds Features even when derived tag exists

- Given a config with nested `build` and admitted Features, and the Features derived tag already exists locally
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then Features `container build` is invoked even though that derived tag exists (the same tag name is allowed)
- And Features `FROM`s the product Dockerfile tag
- And the operator is not required to delete images

#### Scenario: Dockerfile-only create does not require Features build

- Given nested `build` and no `features` key (or empty features)
- When a fresh create path runs
- Then create uses the product Dockerfile tag and the Features build path is not required

---

### Requirement: Dockerfile hash material and product tag identity

Config hash material MUST include the resolved dockerfile path, context, args, target, and the Dockerfile file bytes. Changing any of those MUST change the config hash so `up` drift detection (`config_hash_mismatch`) and rebuild identity remain correct.

The build-context tree (COPY sources other than the Dockerfile file itself) MUST NOT be hashed. Changing only those files MUST NOT by itself change the config hash or the product tag; the operator runs `rebuild` to pick up those changes.

The product Dockerfile tag hash12 MUST be computed from Dockerfile file bytes + context path + args + target only, and MUST NOT use the Features derived-tag format `adev-{base}:{hash12}` or Features `recipeVersion` material.

#### Scenario: Dockerfile bytes and build fields change config hash

- Given two configs that differ only in dockerfile path, context, args, target, or Dockerfile file bytes
- When config hashes are computed
- Then the hashes differ

#### Scenario: Context tree is not hashed

- Given two workspaces with identical dockerfile path, context path, args, target, and Dockerfile file bytes, but different other files under the context directory
- When config hashes and product Dockerfile tags are computed
- Then the hashes and tags are equal

#### Scenario: Product Dockerfile tag is distinct from Features tag

- Given a dockerfile-only build with a non-empty human base
- When the product Dockerfile tag is computed
- Then the tag is `adev-{base}-df:{hash12}` and MUST NOT equal Features `adev-{base}:{hash12}` or contain a `/features` path segment

---

### Requirement: Dockerfile reference example

The repository MUST provide `references/dockerfile/` containing `.devcontainer.json` (nested `build`, no top-level `image`) and a sibling `Dockerfile` whose `FROM` is a small image and which does not require privileged or Docker-in-Docker. `references/README.md` MUST mention this example. The example MUST admit under this change.

#### Scenario: dockerfile reference admits

- Given `references/dockerfile/.devcontainer.json` and its sibling `Dockerfile`
- When the example is admitted and resolved
- Then nested `build` admits, no Compose or privileged/DinD requirement is present, and validation does not fail solely because `image` is omitted

## MODIFIED Requirements

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

The CLI MUST accept and honor the property surface below. Properties outside this surface follow **Unsupported property policy** and **Deterministic compatibility degradation reporting**. Truly unknown non-metadata top-level properties and blocked recognized semantics MUST hard-error. Parseable `customizations.vscode.extensions` / `settings` are **honored by apply**, not ignored, while still never failing parse solely for presence. Other benign editor metadata MAY be ignored per Unsupported property policy.

**Image & workspace**
- `$schema` — optional string parser/editor metadata; silent and hash-neutral
- `name` (optional; when non-empty after trim, drives the DNS-friendly create name and does not drive the resource base, per the live Deterministic identity and labels contract)
- `image` **xor** nested `build` — exactly one source selector is required
- nested `build` — object with required `dockerfile` (string); optional `context` (string, default `"."`); optional `args` (string map, substitution applied); optional `target` (string); other `build.*` keys fail closed. Behavior per **Nested build xor image admission** and **Dockerfile image build on create paths**
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
- `initializeCommand` — string, argv array, or object map; host command per [lifecycle-hooks.md](../../../lifecycle-hooks.md) **initializeCommand host execution**
- `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` — string, argv array, or object map; object-map entries run concurrently; policy per **Lifecycle hook surface** and [vscode.md](../../../vscode.md) **postAttachCommand policy (CLI-only)**
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

#### Scenario: nested build is on the supported surface
- Given a config that includes nested `build` with required `dockerfile` and no top-level `image`, plus only otherwise supported keys
- When config is validated
- Then validation does not fail with unsupported-property for `build` and does not require `image`

See also: [lifecycle-hooks.md](../../../lifecycle-hooks.md), [runargs-host.md](../../../runargs-host.md), [features.md](../../../features.md), [vscode.md](../../../vscode.md) for detailed property behavior; **Remote connection user resolution** and **Create process user** for the user chain and create `-u`.

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

Hard rejection MUST be limited to malformed input or semantics whose omission would make execution incoherent, unsafe, destructive, or materially misleading. This includes unrepresentable configuration-source selectors (legacy top-level `dockerFile` / `dockerfile` / `context`, and Compose), nested `build` keys outside the v1 translation, custom workspace/process semantics that would run different content or commands, required host capabilities that are unmet or unverifiable, data/security-sensitive protections that cannot be preserved, unsupported substitutions, invalid Feature option/package requirements, and first-class runArg collisions. Nested `build` with the translation in **Nested build xor image admission** is representable and MUST NOT be rejected as an unrepresentable source selector. A recognized property MUST NOT be rejected merely because it lacks an implementation when its omission is registered as harmless or optional and reported as required.

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
- Unknown top-level dangerous properties; neither `image` nor nested `build`, or both together; invalid Feature option shapes; hostRequirements shortfalls; unsupported substitutions
- Top-level `dockerFile` / `dockerfile` / `context`

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

- Given a config selects Docker Compose, or top-level `dockerFile` / `dockerfile` / `context`, without a separately supported translation
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

### Requirement: Up lifecycle (create, start, reuse)

`adevcontainer up` MUST resolve config, admit properties, and ensure a running managed dev container: create if missing, start if stopped, reuse if already running with matching identity. Workspace bind MUST mount the host workspace into the container workspace folder. `up` MUST support a machine-readable JSON result on success (and structured failure otherwise).

Success JSON fields, drift policy, lifecycle hook matrix, vscode customizations apply matrix, and create-path cleanup remain as in [core.md](../../../core.md) **Up lifecycle (create, start, reuse)** except **Create image selection** below.

**Create image selection (Features-aware and Dockerfile-aware)**

On paths that create a new container (fresh create or `rebuild`):

- **Before create**, if nested `build` is admitted: ensure **build.rosetta=false** (same consent as Features; at most once per create path), then obtain the product Dockerfile tag per **Dockerfile image build on create paths** (`up`/`clone` build or reuse; `rebuild` always `container build`).
- **Before create**, if resolved `features` is non-empty: ensure **build.rosetta=false** (consent; skipped if already ensured for nested `build`), then **resolve → fetch → order → contribution merge → Dockerfile generate → `container build`** (reuse derived tag on `up`/`clone` when it exists; on `rebuild` with nested `build`, always `container build` even when that tag exists; image-based `rebuild` keeps the realized reuse clause) with `FROM` equal to the product Dockerfile tag when nested `build` was used, otherwise config `image`. Create uses the **derived image** with contributions merged and **`--platform`** host-native.
- Then start and lifecycle hooks (onCreate → updateContent → postCreate → postStart, etc.); feature-contributed hooks merge per the merge-feature-metadata requirement (installs are already in the derived image).
- If `features` is absent or empty and nested `build` is admitted: create uses the product Dockerfile tag; Features build path is not required.
- If `features` is absent or empty and nested `build` is not admitted: create uses config `image` as today (still with default platform); Features build path is not required.
- Reuse running / start stopped paths MUST NOT re-fetch/rebuild features or rebuild the user Dockerfile. Config hash (including features and Dockerfile hash material) still drives `config_hash_mismatch` on `up` when those inputs change; forced rebuild is available via `rebuild` only.

#### Scenario: Up with features builds then hooks
- Given fixture-equivalent config with OCI node feature
- When the user runs `up` (fresh create) with fetch/build available or mocked success
- Then resolve/fetch/build run before create, create uses the derived image, then lifecycle hooks

#### Scenario: Up without features unchanged image path
- Given a config with no `features` key and no nested `build`
- When the user runs `up` fresh create
- Then create uses config `image` and neither the Features nor Dockerfile build path is required

#### Scenario: Reuse running does not re-fetch features
- Given a matching container already running with features identity satisfied
- When the user runs `up` (matching hash, no rebuild)
- Then no feature fetch/build is required and onCreate / updateContent / postCreate / postStart are not re-run

All other scenarios of [core.md](../../../core.md) **Up lifecycle (create, start, reuse)** remain in force unchanged.

---

### Requirement: Derived image build (native arm64; no Rosetta)

When `features` is non-empty after admission, on a fresh create path the product MUST use as Features `FROM` base:

- the product Dockerfile tag when nested `build` was admitted and built or reused, otherwise
- the config `image` reference as written

When nested `build` is admitted, `rebuild` MUST invoke Features `container build` even when the Features derived tag already exists (the same tag name is allowed). `up` and `clone` still reuse that derived tag when it exists. Image-based Features (no nested `build`) keep the realized rebuild reuse clause.

All other Derived image build steps (native arm64 BuildKit, fetch/order, generated Features Dockerfile, tag `adev-{base}:{hash12}`, reuse on `up`/`clone`, create from derived image, `--platform`, no `--rosetta` by default) remain as in [features.md](../../../features.md) **Derived image build (native arm64; no Rosetta)**. The realized **Rebuild reuse clause** MUST NOT apply when nested `build` is admitted.

When `features` is absent or empty, create MUST use the product Dockerfile tag when nested `build` was admitted, otherwise the config `image` reference as written (no Features derived tag).

#### Scenario: Create uses derived image after build
- Given a config with `image` and one OCI feature
- When the user runs `up` on a fresh create path (fetch/build available or mocked success)
- Then `container build` runs with `--platform linux/arm64` on arm64 hosts, create uses the derived tag `adev-{base}:{hash12}` (or `adevcontainer:{hash12}` when base is empty), and lifecycle hooks run after start

#### Scenario: Features FROM dockerfile tag when nested build is present
- Given a config with nested `build` and one OCI feature (no top-level `image`)
- When Features build runs on a fresh create path
- Then the Features generated Dockerfile `FROM`s the product Dockerfile tag `adev-{base}-df:{hash12}` (or `adevcontainer-df:{hash12}` when base is empty), not a config `image`

#### Scenario: Rebuild with nested build does not reuse Features derived tag
- Given a managed container created from nested `build` plus Features, and the Features derived tag already exists locally for the same Features material
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then Features `container build` is invoked (the same tag name is allowed) and create uses that Features derived tag after the build

All other scenarios of [features.md](../../../features.md) **Derived image build (native arm64; no Rosetta)** remain in force unchanged except **rebuild with unchanged features material reuses derived tag**, which MUST NOT apply when nested `build` is admitted.

---

### Requirement: Purge command

`adevcontainer purge` MUST remove:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`) via `devcontainer.config_volumes` label | Yes, **only when unreferenced** after target container delete (see volume attachment gate) |
| Config `image` reference (from runtime inspect) | Yes |
| Product-built Dockerfile tag for dockerfile-only creates | Yes — stamped identity includes that tag so dockerfile-only purge can delete it |
| **Workspace volume for volume-mode** (`devcontainer.workspace_volume` / deterministic `*-ws` name) | **Yes, only when unreferenced** after target container delete |
| Derived Features tags | No (unless equal to config `image`) |
| Bind-mount host paths | No |
| Global volume/image prune | No |

Identity, ordering, volume attachment gate, attachment-inspection failure, volume-delete runtime failure, recovery-helper skip, and exit summary remain as in [managed-lifecycle.md](../../../managed-lifecycle.md) **Purge command**. Features-derived tags keep that existing purge policy. Dockerfile-only creates MUST stamp the product Dockerfile tag so purge can treat it as the config image to delete.

#### Scenario: Purge dockerfile-only deletes the product Dockerfile tag

- Given a dockerfile-only managed container whose create image is the product Dockerfile tag `adev-{base}-df:{hash12}` (or `adevcontainer-df:{hash12}`)
- When the user runs `adevcontainer purge --name <that-name>`
- Then the container is gone and that product Dockerfile tag is removed as the config image

#### Scenario: Purge does not delete Features-derived tags solely because dockerfile was used

- Given a managed container created from nested `build` plus Features, whose running image is a Features derived tag
- When the user runs `adevcontainer purge --name <that-name>`
- Then Features-derived tags are not removed unless they equal the config `image` under the existing purge policy

All other scenarios of [managed-lifecycle.md](../../../managed-lifecycle.md) **Purge command** remain in force unchanged.
