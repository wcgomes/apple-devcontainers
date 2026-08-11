# adevcontainer — Features Runner Specification

## Purpose

OCI and local-path Features runner: admission, warn-skip for Apple-incompatible optional bits, metadata resolve and dependency order, artifact fetch, derived image build on native arm64, build.rosetta consent, contribution merge, progress status, fixtures, and test strategy.

## Requirements

### Requirement: Features object admission (OCI + local path)

The CLI MUST admit a top-level `features` property when it is an **object** (map). Each map key is a feature reference string; each value MUST be an object of option key → JSON value, or an empty object. A missing `features` key or empty object `{}` MUST be treated as no features (no-op for the runner).

**Supported reference forms (v1):**

1. **OCI** feature references resolvable over HTTP(S) registry APIs, including optional tag/version suffix, e.g. `ghcr.io/devcontainers/features/node:1`.
2. **Local path** feature keys: relative (`./…`, `../…`), absolute (`/…`), and `file://…` URIs. Relative paths resolve against the **workspace root**. The path MUST be a directory containing `devcontainer-feature.json` and `install.sh`; the package is copied into the feature cache. Missing directory / metadata / install script → structured error at fetch/load (not a silent skip).

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

#### Scenario: Local path missing package fails at load
- Given an admitted local path whose directory (or `install.sh` / `devcontainer-feature.json`) is missing
- When features are fetched/loaded
- Then the CLI fails with a structured error naming the feature ref

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
4. **Build** a derived image with Apple `container build` from a **generated Dockerfile** that `FROM`s the base image and, per feature, `COPY`s the package then `RUN`s recursive `chmod -R 0755` on the package directory **before** `./install.sh` **as root** (options / `_REMOTE_USER` / `_CONTAINER_USER` env) so scripts `install.sh` copies into bare-path lifecycle hooks remain executable (ref CLI parity; avoids exit 126). Build argv MUST include the same host-native **`--platform`**.
5. **Tag** a deterministic local image as `adev-{base}:{hash12}`, where `base` is the same human base as container identity and `hash12` is a 12-character content hash of base image + features + a product **`recipeVersion`** constant (install Dockerfile semantics epoch). If `base` is empty → `adevcontainer:{hash12}`. MUST NOT use an `adevcontainer/features:` prefix or a `/features` path segment. **Reuse** when that tag already exists locally (skip rebuild). When generator install-layer semantics change (e.g. chmod recipe), the product MUST bump `recipeVersion` so existing tags miss and rebuild.
6. **Create** the workspace container **from the derived image** (not the raw config `image`) with the same **`--platform`**. Contributions that affect create flags (`init`, `capAdd`, env, mounts) MUST be merged **before** create.
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
- Then `up` fails with a structured feature-build error and no workspace container is created

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
| `containerEnv` | Merged into effective env; **config `containerEnv` wins** on key conflict |
| mounts | Bind and volume only; sources normalized with **MountNormalizer** for file→dir promotion; incompatible mount types fail structured |
| lifecycle hooks contributed by features | Appended/merged into the create-path exec order after start (installs already in derived image); same string/argv/object-map forms and failure/delete-on-fail policy as config hooks for create-path failures |

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

`ADEVCONTAINER_QUIET=1` MUST silence these status lines (progress only). Policy warn-skip warnings MUST still emit under QUIET. Machine JSON on stdout MUST remain pure when `--json` (or equivalent) is used.

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
