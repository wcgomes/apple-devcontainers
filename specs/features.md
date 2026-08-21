# adevcontainer — Features Runner Specification

## Purpose

OCI and local-path Features runner: admission, warn-skip for Apple-incompatible optional bits, metadata resolve and dependency order, artifact fetch, derived image build on native arm64, build.rosetta consent, contribution merge, progress status, fixtures, and test strategy.

## Requirements

### Requirement: Features object admission (OCI + local path)

The CLI MUST admit a top-level `features` property when it is an **object** (map). Each map key is a feature reference string; each value MUST be an object of option key → JSON value, or an empty object. A missing `features` key or empty object `{}` MUST be treated as no features (no-op for the runner).

**Supported reference forms (v1):**

1. **OCI** feature references resolvable over HTTP(S) registry APIs, including optional tag/version suffix, e.g. `ghcr.io/devcontainers/features/node:1`.
2. **Local path** feature keys: relative (`./…`, `../…`), absolute (`/…`), and `file://…` URIs. Relative paths resolve, in order, until a directory containing both `devcontainer-feature.json` and `install.sh` exists: (a) the directory containing the config file + the ref (official; typically `.devcontainer/`); (b) `workspace/.devcontainer/` + the ref when that path is distinct; (c) workspace root + the ref. Absolute and `file://` use their own path only. The package is copied into the feature cache. Missing directory / metadata / install script → structured `featureFetch`/`featureMetadata` error naming the ref (not OCI/network, not a silent skip). The error hint MUST mention the workspace root and the `.devcontainer` / config directory.

Options object MAY supply feature options (e.g. `"version": "lts"`).

**Not supported (v1) — structured hard error:**

- Non-object `features` value (array, string, number, boolean).
- Non-object option values for a feature entry (unless the entry value is explicitly empty object).

**Warn-skip (v1) — continue without admitting:**

- Docker-* feature markers (see warn-skip requirement) even when expressed as a local path — emit stderr warning and omit from the admitted list (do not hard-error solely for these).

Error messages MUST name the feature key (when applicable) and indicate supported OCI and/or local path forms.

Omitted `features` MUST NOT fail validation solely for absence.

**Hash material (v1):** local path refs participate via the path string (and options); content changes under the same path MAY NOT invalidate the derived tag until the path or options change — acceptable for v1. Derived-tag material also includes product `recipeVersion` (install Dockerfile semantics epoch); path/content under a fixed local path still does not auto-invalidate without a path/options/`recipeVersion` change.

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

#### Scenario: Local path under .devcontainer subdirectory loads
- Given `"features": { "./features/kubesecret": {} }` and a valid package at `<workspace>/.devcontainer/features/kubesecret`
- When features are fetched/loaded
- Then the package loads from that directory (not OCI)

#### Scenario: Local path beside the config file loads
- Given `"features": { "./kubesecret": {} }` and a valid package at `<workspace>/.devcontainer/kubesecret` (beside `devcontainer.json`)
- When features are fetched/loaded
- Then the package loads from that directory (not OCI)

#### Scenario: Local path workspace-root fixture still loads
- Given `"features": { "./.devcontainer/features/sample-a": { "greeting": "local" } }` and a valid package at `<workspace>/.devcontainer/features/sample-a`
- When features are fetched/loaded
- Then the package loads via the workspace-root candidate

#### Scenario: Local path missing package fails at load
- Given an admitted local path whose directory (or `install.sh` / `devcontainer-feature.json`) is missing at every resolve candidate
- When features are fetched/loaded
- Then the CLI fails with a structured `featureFetch`/`featureMetadata` error naming the feature ref (never OCI/network); the hint mentions the workspace root and the `.devcontainer` / config directory

#### Scenario: features must be an object
- Given `"features": ["ghcr.io/devcontainers/features/node:1"]`
- When config is validated
- Then the CLI fails with a structured error naming `features` and requiring an object map

---

### Requirement: Warn-skip docker-* features and privileged/securityOpt contributions

Independent of general Features support, the CLI MUST **warn-and-skip** (not hard-error) these Apple-incompatible optional bits so multi-platform configs can still `up`:

1. **docker-outside-of-docker / docker-in-docker / docker-from-docker** — any feature reference whose id/path contains the substring `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (case-sensitive; any registry/tag or local path). Emit a stderr warning naming the feature and that it is incompatible with Apple container (no Docker socket / DinD path); **omit** the ref from the admitted features list; continue. Other non-matching features in the same map MUST remain admitted. When every feature is skipped this way, treat as empty features (no Features runner work) and still succeed admission/`up` when otherwise valid.
2. **Privileged / securityOpt contributions** — after metadata resolve, when a feature’s `devcontainer-feature.json` (or image `devcontainer.metadata` label) sets `privileged: true` or non-empty `securityOpt`, emit a stderr warning naming the feature/image and that the contribution is ignored/not applied on Apple container; **do not** apply privileged or securityOpt to create; **do** allow the feature to install if it was admitted. Do **not** map privileged → `--virtualization`.
3. **Compose** — unchanged; Compose keys remain hard-error.

Warnings MUST be actionable via `StatusPrinter.warning` (or equivalent stderr pattern): name the item, say ignored/disabled/skipped, brief why. The CLI MUST NEVER silently skip these items. Config hash / identity MUST use the **effective** admitted config after skips (skipped docker-* features MUST NOT appear in hash material).

#### Scenario: Warn-skip docker-ood under any registry/tag
- Given `features` includes `ghcr.io/devcontainers/features/docker-outside-of-docker:1` (or another host/tag with `docker-outside-of-docker` in the ref) plus a non-docker feature (e.g. node)
- When config is validated
- Then admission succeeds; the docker-* ref is absent from the admitted list; the non-docker feature remains; stderr warns naming the skipped feature

#### Scenario: Warn-strip privileged feature metadata
- Given an admitted feature whose resolved `devcontainer-feature.json` sets `privileged` to true (or requires `securityOpt`)
- When features are resolved for `up`
- Then the CLI does **not** fail solely for privileged/securityOpt; emits a warning; does not apply privileged/securityOpt to create; and MAY still install the feature

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

1. **Local path** refs → resolve relative candidates in order until a directory containing both `devcontainer-feature.json` and `install.sh` exists: config-file parent, then `workspace/.devcontainer` if distinct, then workspace root; absolute/`file://` use their own path only. Validate package layout and **copy** into the feature cache destination. A miss is a structured `featureFetch`/`featureMetadata` error naming the ref, not an OCI/network failure.
2. **OCI** refs → fetch feature content as **OCI artifacts** (feature layers/files), not as a plain application container image assumed runnable, via **HTTPS and/or registry API** logic **embedded in the product** (library code under `Sources/ADevContainerLib/`).

The product MUST NOT:

- Require users to install ORAS or another external feature-fetch CLI
- Assume Apple `container image pull` pulls feature artifacts correctly
- Invoke Node or `@devcontainers/cli` to fetch features

Fetch/load failures (missing local dir, missing install.sh/metadata, network, 401/403/404, malformed manifest) MUST surface as structured errors naming the feature ref and failure class. Unit tests MUST mock the OCI fetch boundary so the default suite needs no network; local path tests use fixtures under `Tests/Fixtures/features-sample/`.

`clone` MUST sparse-checkout the whole `.devcontainer/` tree (including `features/<id>`) and load local-path refs via `DefaultFeatureFetcher` (workspace = checkout, configDirectory = config parent) — never raw `OCIFeatureClient`. Bind `rebuild` MUST load local-path refs via `DefaultFeatureFetcher` from the stamped host workspace. Volume `rebuild` MUST NOT use raw `OCIFeatureClient` when any admitted feature is a local path: stage the guest `.devcontainer/` (and root `.devcontainer.json` when that is the config) onto a host temp via `exec tar cf -` (not `container cp`) before Features/delete, point `DefaultFeatureFetcher` at that staged root + config directory, and remove the temp. Staging or load failure is a structured pre-delete error (old container kept). Mixed OCI + local in one config: local via the loader, OCI via the embedded client.

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

#### Scenario: Clone loads local-path Features from sparse checkout
- Given a repo with `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `clone` fetches config and runs Features
- Then the sparse checkout materializes the `.devcontainer/` tree (including `features/kubesecret`) and the package loads via `DefaultFeatureFetcher` (not OCI)

#### Scenario: Clone missing local-path package fails structured not OCI
- Given a clone config with a local-path feature whose package is absent from the checkout
- When Features load
- Then the CLI fails with a structured `featureFetch`/`featureMetadata` error naming the ref (never OCI/network)

#### Scenario: Bind rebuild loads local-path Features from stamped workspace
- Given a bind-mode container whose stamped host workspace has `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `rebuild` runs Features
- Then the package loads via `DefaultFeatureFetcher` from the stamped workspace (not OCI)

#### Scenario: Volume rebuild loads local-path Features from staged guest .devcontainer
- Given a volume-mode container whose guest workspace has `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `rebuild` runs Features
- Then the guest `.devcontainer/` tree is staged to a host temp via `exec tar` (not `container cp`) before Features/delete, `DefaultFeatureFetcher` loads the package from that staged root (not raw `OCIFeatureClient`), and the temp is removed

#### Scenario: Volume rebuild missing local-path package fails before delete
- Given a volume-mode rebuild whose admitted features include a local-path ref whose package is missing after staging
- When Features load
- Then the CLI fails with a structured `featureFetch`/`featureMetadata` error naming the ref (never OCI/network) and the old container is not deleted

---

### Requirement: Derived image build (native arm64; no Rosetta)

When `features` is non-empty after admission, on a fresh create path the product MUST:

1. **Ensure native arm64 BuildKit** (see **build.rosetta consent** requirement) before fetch/build.
2. **Resolve + fetch** OCI feature artifacts (embedded client), compute install order, and collect runtime contributions (see other requirements).
3. **Pull** the config base image with **`--platform`** set to the host-native Linux platform:
   - `linux/arm64` when the host is arm64 / aarch64 (product default on Apple Silicon)
   - `linux/amd64` only when the host is x86_64
  4. **Build** a derived image with Apple `container build` from a **generated Dockerfile** that `FROM`s the base image and, per feature, `COPY`s the package then `RUN`s recursive `chmod -R 0755` on the package directory **before** `./install.sh` **as root** so scripts `install.sh` copies into bare-path lifecycle hooks remain executable (ref CLI parity; avoids exit 126). After **all** feature install layers, the generated Dockerfile MUST restore the **base image’s** final OCI `USER` per **Features install as root then restore base image USER**. Install remains as root; the Dockerfile MUST NOT leave the derived image’s final default user as root solely because install ran as root when the base image USER was non-root. Callers MUST fail closed on base inspect failure before fabricating install-env users. Build argv MUST include the same host-native **`--platform`**.

     **Install env composition (MUST)** — for **each** feature install layer, make that feature’s declared metadata `containerEnv` (from `devcontainer-feature.json`) available to that feature’s `./install.sh` during the install `RUN` (parity with `@devcontainers/cli` ENV-before-install intent):

     1. Feature metadata **`containerEnv`** key/value pairs declared for that feature, emitted as Dockerfile **`ENV` lines before** that feature’s install `RUN`. Values MUST preserve `$VAR` / `${VAR}` for BuildKit/Docker ENV expansion and MUST NOT be shell single-quoted (single-quoting blocks expansion and can replace `PATH` with a literal `$PATH:…` string).
     2. Feature **options** (resolved user options over metadata defaults), mapped to install env names as today, on the install `RUN` export prefix.
     3. **`_REMOTE_USER` / `_CONTAINER_USER`** (and homes) per existing Features install user-env contract (config users → base image USER → `root`; no hardcoded editor usernames), on the install `RUN` export prefix so they win over `ENV` for the install process on key collision. `_REMOTE_USER` / `_CONTAINER_USER` install env MUST be derived from config `remoteUser` / `containerUser` without inventing editor usernames; when both unset, install env MUST use the inspected base image USER when non-empty, else `root` — MUST NOT hardcode `vscode`.

     **Empty metadata (MUST):** When a feature’s `containerEnv` is absent or empty, install env MUST still include options and user keys; no extra feature `ENV` lines are required.

     **Scope of availability (MUST):** Each feature’s `containerEnv` MUST be visible to **that** feature’s `install.sh`. The product MUST NOT omit a non-empty declared key solely because runtime merge also applies the same key later.

     **Unchanged (MUST NOT regress):** Runtime merge of feature `containerEnv` into effective create/exec env remains **config `containerEnv` wins** on key conflict (see **Merge feature metadata into create and lifecycle**). Config-file `containerEnv` is **not** required in the install Dockerfile; install-time source is feature metadata only.

  5. **Tag** a deterministic local image as `adev-{base}:{hash12}`, where `base` is the same human base as container identity and `hash12` is a 12-character content hash of base image + features + a product **`recipeVersion`** constant (install Dockerfile semantics epoch). If `base` is empty → `adevcontainer:{hash12}`. MUST NOT use an `adevcontainer/features:` prefix or a `/features` path segment. **Reuse** when that tag already exists locally (skip rebuild). Current Features `recipeVersion` is **`"5"`** (ENV-before-RUN feature `containerEnv` with expandable `$VAR`/`${VAR}`; prior epoch `"4"` was RUN-prefix containerEnv without expandable `$` refs). When generator install-layer semantics change (e.g. chmod recipe, final-`USER` restore, install-env composition), the product MUST bump `recipeVersion` so existing tags miss and rebuild.
6. **Create** the managed dev container **from the derived image** (not the raw config `image`) with the same **`--platform`**. Contributions that affect create flags (`init`, `capAdd`, env, mounts) MUST be merged **before** create.
7. **Start** the container, then run lifecycle hooks (onCreate → …) as today.

When `features` is absent or empty, create MUST continue to use the config `image` reference as written (no derived tag).

**MUST NOT** pass `--rosetta` on Features pull/build/create unless the user opted in via `runArgs`.

**MUST NOT** depend on Rosetta being installed: Features builds rely on `build.rosetta=false` (native arm64 BuildKit).

Reuse running / start stopped: MUST NOT re-fetch/rebuild features (already baked into the image on create). Config hash (including features) still drives `config_hash_mismatch` on `up` when features change; forced rebuild is available via `rebuild` only.

**Rebuild reuse clause**

On `rebuild`, the same derived-tag identity material applies: when the rebuilt config's base image + features + `recipeVersion` material is **unchanged**, the existing derived tag `adev-{base}:{hash12}` MUST be reused (no `container build`), making the unchanged config cheap; when the material **changed**, the derived image MUST be built before the old container is deleted (pre-delete ordering gate). Feature option changes and product `recipeVersion` bumps alter the material and MUST produce a different derived tag, engaging the build path.

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
- Then `up` fails with a structured feature-build error and no managed dev container is created

#### Scenario: Reuse existing derived tag skips build
- Given the deterministic derived tag already exists locally
- When Features runner runs with the same base image + features identity
- Then no `container build` is invoked and create uses the existing tag

#### Scenario: Feature option change changes config identity
- Given the same feature ref but different options object
- When config hashes (and derived tags) are computed
- Then the hashes/tags differ (`up` hash-mismatch / `rebuild` build path; no silent wrong-feature reuse)

#### Scenario: recipeVersion change changes derived tag
- Given the same base image + feature refs/options
- When derived tags are computed with different product `recipeVersion` values
- Then the tags differ (stale images built under the prior install recipe are not reused)

#### Scenario: same recipeVersion keeps derived tag stable
- Given the same base image + feature refs/options + `recipeVersion`
- When derived tags are computed twice
- Then the tags are identical

#### Scenario: rebuild with unchanged features material reuses derived tag
- Given a managed container created from a config with OCI features and an existing derived tag `adev-{base}:{hash12}` for the same material
- When the user runs `adevcontainer rebuild --name <that-name>` without changing feature material
- Then no `container build` is invoked and the new container is created from the existing derived tag

#### Scenario: rebuild with changed features material builds before delete
- Given a managed container whose edited config changes a feature ref or option
- When the user runs `adevcontainer rebuild --name <that-name>`
- Then a new derived image is built (new tag material), the build completes **before** the old container is deleted, and the new container is created from the new derived image

#### Scenario: derived image default user matches base after Features
- Given base image USER `node` and a successful Features-derived create
- When the derived image default user is observed
- Then it matches `node` (not forced root)

#### Scenario: Features install env uses base USER when config users empty
- Given config omits both user keys and base image USER is `node`
- When the Features Dockerfile install env is generated
- Then `_REMOTE_USER` and `_CONTAINER_USER` are `node` (not unconditional `root`, not `vscode`)

#### Scenario: install sees feature containerEnv
- Given a feature whose metadata declares `containerEnv.DOTNET_ROOT=/usr/share/dotnet` (or equivalent non-empty map)
- When the Features Dockerfile install layer for that feature is generated
- Then the generated Dockerfile includes `ENV DOTNET_ROOT=/usr/share/dotnet` (or equivalent non-single-quoted ENV form) before that feature’s install `RUN`
- And that feature’s `./install.sh` install environment includes `DOTNET_ROOT` with value `/usr/share/dotnet`

#### Scenario: containerEnv PATH dollar-refs expand (no single-quote wipe)
- Given a feature whose metadata declares `containerEnv.DOTNET_ROOT=/usr/share/dotnet` and `containerEnv.PATH=$PATH:$DOTNET_ROOT` (or `${PATH}:$DOTNET_ROOT`)
- When the Features Dockerfile install layer for that feature is generated
- Then the Dockerfile contains an `ENV` assignment for `PATH` whose value still includes expandable `$PATH` / `${PATH}` (e.g. `ENV PATH=$PATH:$DOTNET_ROOT`)
- And the Dockerfile does **not** contain a shell single-quoted PATH value such as `PATH='$PATH:$DOTNET_ROOT'`
- And `DOTNET_ROOT` is still available to `install.sh` (via `ENV` or equivalent)
- And system utilities on the base image PATH (e.g. `dirname`) remain reachable during install because PATH is not replaced by the literal string `$PATH:…`

#### Scenario: empty containerEnv unchanged
- Given a feature with absent or empty metadata `containerEnv`
- When the Features Dockerfile install layer for that feature is generated
- Then install env still includes resolved option keys and `_REMOTE_USER` / `_CONTAINER_USER` (and homes)
- And no extra feature `containerEnv` keys are required

#### Scenario: install env still has options and user keys
- Given a feature with options and non-empty metadata `containerEnv`, and config/base user inputs that resolve install users
- When the Features Dockerfile install layer is generated
- Then install env includes option-derived keys, the feature’s `containerEnv` keys, and `_REMOTE_USER` / `_CONTAINER_USER` (and homes)
- And option/user keys remain on the RUN export prefix (not forced into `ENV` solely by this change)

#### Scenario: recipeVersion bump invalidates derived tags (epoch 4 vs 5)
- Given the same base image + feature refs/options
- When derived tags are computed with product `recipeVersion` `"4"` vs `"5"`
- Then the tags differ (stale images built under the prior install recipe are not reused)

#### Scenario: runtime merge still config-wins (no change from install-time containerEnv)
- Given feature metadata `containerEnv.FOO=from-feature` and config `containerEnv.FOO=from-config`
- When effective **runtime** env is computed for create/exec
- Then `FOO` is `from-config`
- And this conflict policy is unchanged by install-time `containerEnv` availability

---

### Requirement: Features install as root then restore base image USER

When the Features runner generates a derived-image Dockerfile, it MUST:

1. Run each feature install layer as **root** (`USER root` before install `RUN`), unchanged in intent from today.
2. After **all** feature install layers, emit a final instruction that restores the **base image’s** final OCI `USER` as obtained from image inspect of the Features `FROM` base (the config base image before feature layers).
3. When base inspect succeeds and base `USER` is non-empty, the final image default user MUST match that base `USER`.
4. When base inspect succeeds and base `USER` is empty/absent, the Dockerfile MUST restore an equivalent default (no lingering forced `USER root` as the final image user solely because install ran as root) — final default MUST be `root` only when that matches empty-USER / default image semantics after successful inspect.
5. When base image inspect **fails**, Features build MUST fail structured — MUST NOT hardcode a final `USER root` restore solely because inspect failed.
6. Changing this final-`USER` restore semantics MUST bump Features `recipeVersion` so derived tags rebuild.

#### Scenario: Features Dockerfile ends with base USER not root
- Given a base image with OCI `USER` `node` and at least one admitted feature
- When the Features Dockerfile is generated
- Then install layers run as root
- And the Dockerfile’s final user directive restores `node`
- And the Dockerfile MUST NOT end on `USER root` when base `USER` is `node`

#### Scenario: Features restore fails closed on base inspect failure
- Given Features build needs base USER restore and base image inspect fails
- When Features build runs
- Then build fails with a structured error
- And no derived image is produced that silently ends as root solely due to inspect failure

---

### Requirement: build.rosetta consent (one-time, native arm64 BuildKit)

Before Features fetch/build on a create or rebuild path, the product MUST ensure Apple container BuildKit is configured with **`build.rosetta=false`** so arm64 image builds do not require Rosetta ([apple/container#1825](https://github.com/apple/container/issues/1825)).

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
| `containerEnv` | Merged into effective **runtime** create/exec env; **config `containerEnv` wins** on key conflict. Install-time availability of feature `containerEnv` is governed solely by **Derived image build** and MUST NOT reverse or weaken config-wins at runtime |
| mounts | Bind and volume only; sources normalized with **MountNormalizer** for file→dir promotion; incompatible mount types fail structured |
| lifecycle hooks contributed by features | Appended/merged into the create-path exec order after start (installs already in derived image); same string/argv/object-map forms and failure/delete-on-fail policy as config hooks for create-path failures. Feature `postStart` (and feature `postAttach` when postAttach runs) MUST remelt on resume per **Feature postStart remelt on resume** and [vscode.md](vscode.md) **postAttachCommand policy (CLI-only)**. Feature onCreate / updateContent / postCreate MUST NOT run on resume. |

Privileged / `securityOpt` contributions are warn-stripped and not applied to create (see warn-skip requirement); other contributions still merge.

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

#### Scenario: Feature postStart remelts on start
- Given feature metadata contributing `postStart` and a stopped managed container from a prior successful create
- When the user runs `adevcontainer start` or `up` start-stopped
- Then the contributed postStart runs via runtime exec on this start

#### Scenario: start with unreadable config still runs metadata postStart
- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postStart`
- When the user runs `adevcontainer start --name <that-name>`
- Then after the container starts, feature-only postStart runs via container exec (`failKeepContainer`)
- And onCreate / updateContent / postCreate do not run
- And vscode customizations are not applied

#### Scenario: start with unreadable config still runs metadata postAttach on CLI attach
- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postAttach`
- When the user runs a real `adevcontainer start` (CLI-attach gate)
- Then feature-only postAttach runs via container exec (`failKeepContainer`)

#### Scenario: derived-image LABEL includes base-image postStart/postAttach after Features build
- Given a base image whose `devcontainer.metadata` contributes `postStart` / `postAttach` and a feature that also contributes those hooks
- When Features builds a derived image
- Then the derived `LABEL devcontainer.metadata` includes both the base-image and feature hooks

#### Scenario: no-features up runs image-metadata postCreate/postStart
- Given a config with empty `features` and a base image whose `devcontainer.metadata` contributes `onCreate` / `updateContent` / `postCreate` / `postStart` / `postAttach`
- When the user runs a fresh `up`
- Then those image-metadata hooks run via container exec on the create path (and postAttach as CLI attach)
- And Features `container build` does not run

#### Scenario: up finish still has base-image postAttach after remelt
- Given Features apply already unioned base-image `postAttach` into the create config
- When `up` finish remelts feature postAttach from image metadata that is features-only
- Then the base-image postAttach still runs (remelt unions, does not replace-away)

#### Scenario: devcontainer.metadata label merge when present
- Given a base image with a parseable `devcontainer.metadata` label
- When features/metadata merge runs
- Then compatible fields are merged into the effective model and `up` is not failed solely because the label existed

#### Scenario: Missing devcontainer.metadata label is OK
- Given no `devcontainer.metadata` label on the image
- When `up` runs with features
- Then absence alone does not fail `up`

### Requirement: Feature postStart remelt on resume

On every path that MUST run `postStartCommand` after a successful start of a previously stopped container (`up` start-stopped and bare `adevcontainer start` in bind and volume modes), the CLI MUST remelt feature-contributed `postStart` commands for that invocation. The CLI MUST run the config `postStartCommand` when present, then feature-contributed postStart commands, in the same merge/order spirit as create-path feature lifecycle hooks.

Resume MUST NOT drop feature-contributed postStart solely because the container was created earlier. Feature onCreate / updateContent / postCreate MUST remain create-path only. A non-zero remelted feature postStart on resume MUST fail the command and MUST NOT delete the container.

When `start` recovery delegates to `rebuild`, the rebuild create-path already includes config and feature postStart. That recovery MUST NOT run an additional postStart after rebuild returns.

#### Scenario: volume-mode start remelts feature postStart
- Given a stopped volume-mode managed container created with a feature that contributed `postStart` (and optional config `postStartCommand`)
- When the user runs `adevcontainer start --name <that-name>`
- Then after the container starts, config postStart (when present) then the feature postStart run via container exec
- And the command succeeds if those commands exit 0

#### Scenario: up start-stopped remelts feature postStart
- Given a matching stopped bind-mode container and remeltable feature postStart
- When the user runs `adevcontainer up`
- Then feature postStart runs on this start (not only the original create)
- And onCreate / updateContent / postCreate do not run

#### Scenario: start recovery via rebuild does not double-run postStart
- Given `start` fails and recovery delegates to `rebuild` for that container
- When rebuild’s create-path runs `postStartCommand` (config and features) on the new container
- Then the user-visible start-recovery path does not run `postStartCommand` a second time after rebuild returns

---

### Requirement: Features progress status lines

During Features work on `up` (and other create paths that run Features), the CLI MUST emit stderr progress status lines in the progress family (`==> …` / StatusPrinter), including at least:

- Resolving features
- Fetching feature \<ref or id\> (per feature or equivalent clear wording)
- Building features image \<tag\> (or Reusing features image \<tag\> when the tag exists)
- Configuring native arm64 builds (build.rosetta=false) — **only** when actually changing config

Presentation MAY use colors and phase section spacing per [terminal-output.md](terminal-output.md). The monochrome text family of these status lines MUST remain greppable (`==> …` with the same message intent).

When Features build (or other Features tool steps) live-tee subprocess output to host stderr, those body lines MUST use **internal tool output framing** per [terminal-output.md](terminal-output.md); status lines remain product phase lines.

`ADEVCONTAINER_QUIET=1` MUST silence these status lines (progress only). Policy warn-skip warnings MUST still emit under QUIET. Machine JSON on stdout MUST remain pure when `--json` (or equivalent) is used. Tool body tees MUST still emit under QUIET.

#### Scenario: Progress lines during feature up
- Given a features config and quiet mode unset
- When `up` runs the Features path (mocked fetch/build OK)
- Then stderr includes resolving/fetching/building (or reusing) status lines in the `==> …` family

#### Scenario: Quiet suppresses features progress
- Given `ADEVCONTAINER_QUIET=1`
- When `up` runs the Features path
- Then Features progress status lines are not printed

#### Scenario: Features build tool body framed when streamed
- Given quiet mode unset and a Features build that live-tees builder output containing a recognizable line
- When the build runs
- Then the recognizable builder line appears on host stderr as a framed internal tool line (`| ` after indent), distinct from `==> ` status lines

---

### Requirement: Features fixtures

The repository MUST provide:

| Path | Content |
|------|---------|
| `Tests/Fixtures/features-node.json` | Valid image-based config with **only** a non-ood OCI feature suitable for Node (e.g. `ghcr.io/devcontainers/features/node` with a pinned tag) and options if needed |
| `Tests/Fixtures/features-local.json` | Valid image-based config with local path features `./.devcontainer/features/sample-a` and `sample-b` (options as needed) |
| `Tests/Fixtures/features-sample/` | On-disk sample feature packages (`sample-a`, `sample-b`, `sample-privileged`) for unit + local E2E |

Fixtures MUST NOT include Compose keys. `features-docker-ood` and `sample-privileged` exercise warn-skip paths. OCI fixtures SHOULD remain usable for optional network integration tests. Local E2E copies `features-sample` into the temp workspace `.devcontainer/features/` before `up`.

#### Scenario: features-node fixture admits
- Given `Tests/Fixtures/features-node.json`
- When parsed and validated under Features admission rules (without requiring live fetch in pure admission tests)
- Then admission succeeds for the features object shape and does not warn-skip the node feature

#### Scenario: features-local fixture admits
- Given `Tests/Fixtures/features-local.json`
- When parsed and validated under Features admission rules
- Then admission succeeds for both local path keys

---

### Requirement: Features test strategy

- **Unit tests** MUST mock registry fetch and runtime `build` / image inspect / property list as needed; default `swift run adevcontainerTests` MUST pass without network and without requiring Rosetta installed. Local path load/order/privileged warn-skip tests use `features-sample` fixtures offline.
- **Integration tests** MAY exercise real OCI fetch + `container build` + `up` when network and Apple `container` are available; they MUST **skip** cleanly when network is unavailable or Apple `container` is missing. **Local path E2E** (`fixtureE2E_featuresLocal`) MUST run when Apple `container` is available **without** requiring `ADEVCONTAINER_FEATURES_E2E` or ghcr network (still uses rosetta-ensure env for non-interactive CI).
- Tests MUST cover docker-* and privileged/securityOpt **warn-skip** (no throw; stripped from effective config) without requiring a real install of those contributions.
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
