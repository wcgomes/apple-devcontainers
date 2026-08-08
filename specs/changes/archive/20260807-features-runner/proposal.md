# Proposal: Features runner (OCI fetch + local path + derived image build)

## Intent

Core and lifecycle/`runArgs`/`hostRequirements` ship a usable Apple-container path, but any `features` entry was forever-rejected. Teams need common Dev Container Features (e.g. Node) without Docker-outside-of-Docker or privileged posture. This change establishes the durable outcome contract for a **Features runner**: admit the `features` object, forever-reject docker-* markers and privileged/securityOpt contributions, fetch feature OCI artifacts over HTTPS/registry API **or** load local path packages from disk, build a derived image with Apple `container build` on **native arm64** (no Rosetta by default), and use that image on create — all runner-owned inside `adevcontainer`.

## Scope

- Change id: **`features-runner`**
- Package root: `/Users/wyller/Repos/dev-containerization/`
- Library paths under `Sources/ADevContainerLib/`; suite under `Tests/adevcontainerTests/`; fixtures under `Tests/Fixtures/`
- Realized base contract: union of `specs/<domain>.md`. This delta **adds** Features runner requirements and **modifies** unsupported-property policy + supported property surface + `up` create image selection.

### A. Admit `features` (policy change)

- **Admit** top-level `features` as an object map of feature ref → options object (or empty object / null options).
- **Remove** the current rule that any `features` entry hard-errors as “not supported on MVP.”
- **Forever-reject still:**
  - Feature id/ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` (any registry, path, tag, or local path — match on id path segment / ref string).
  - Feature contributions that require `privileged: true` or `securityOpt` (or equivalent install metadata that needs them).
  - Compose / multi-service configs (unchanged).
- **Supported refs:** OCI HTTP(S) refs **and** local path features (`./…`, `../…`, absolute `/…`, `file://…`) resolved against the workspace root via `DefaultFeatureFetcher`.

### B. Feature refs and metadata

Supported ref shapes (v1):

| Form | Example | Support |
|------|---------|---------|
| OCI feature ref + optional version tag | `ghcr.io/devcontainers/features/node:1` | **Yes** |
| OCI ref + options object | `"ghcr.io/.../node:1": { "version": "lts" }` | **Yes** |
| Local path `./feature`, `../…`, absolute, `file://` | `./.devcontainer/features/sample-a` | **Yes** — directory with `devcontainer-feature.json` + `install.sh` |

For each admitted feature the runner MUST:

1. Resolve and parse `devcontainer-feature.json` metadata from the feature artifact/package.
2. Apply options substitution where the Features spec expects standard option injection into `install.sh` / env.
3. Order installs using simplified correct dependency order from `dependsOn` / `installsAfter` (id last-segment match so `./x/sample-a` satisfies `…/sample-a:1`; direct config order as tie-break where the upstream spec allows).

### C. Fetch (not plain image pull)

- **OCI:** fetch feature **OCI artifacts** (layers/files for the feature, not a runnable app image) via **HTTPS / registry API embedded in the runner**.
- **Local path:** copy package from disk into the feature cache (workspace-relative or absolute/`file://`).
- MUST NOT assume Apple `container image pull` can pull feature artifacts.
- MUST NOT require an external ORAS CLI install; embed minimal fetch (or pure URL/registry client) as an implementation detail.
- MUST NOT introduce a Node runtime for `adevcontainer` itself.

### D. Derived image build (native arm64)

Before create, when `features` is non-empty and admitted:

1. **Ensure** Apple BuildKit `build.rosetta=false` (one-time consent when needed — see locked decisions).
2. **Resolve** features (refs, options, metadata, order).
3. **Fetch/load** each feature into a workspace-local cache/scratch dir.
4. **Pull** base image and **build** a derived image with Apple `container build` / `--platform` host-native (`linux/arm64` on Apple Silicon) from a **generated Dockerfile** that:
   - `FROM` the user `image`.
   - `COPY` feature files and `RUN` `install.sh` **as root**.
   - Respect feature `user` / options substitution where standard for Features.
5. **Tag** a deterministic local image name from **config hash + features hash** (stable, collision-resistant within product policy).
6. **Reuse**: if that tag already exists locally, **skip rebuild** and use the existing image.
7. Use the **derived image** as the create image instead of the raw config `image` (same `--platform`; no `--rosetta` unless user opted in via `runArgs`).

### E. Merge feature contributions into create / lifecycle

When feature metadata contributes the following, merge into the create path (union with existing config / `runArgs` rules):

| Contribution | Behavior |
|--------------|----------|
| `init` | Map to create `--init` (union with allowlisted `runArgs` `--init`) |
| `capAdd` | Map through the **existing cap-add allowlist path** only; unknown/disallowed caps fail closed per runArgs policy |
| `containerEnv` | Merge into effective container env (feature env then config overrides — **config wins** on key conflict); expand `${PATH}` / `$PATH` on create |
| mounts | Compatible **bind/volume** only; file binds go through **MountNormalizer**; reject device/privileged mount shapes |
| lifecycle hooks from feature metadata | Merge into create-path hook order **after** image feature installs (installs are already in the derived image); hooks run via exec as today |

**SHOULD:** when the base or derived image carries a `devcontainer.metadata` label, read and merge that metadata into effective config where present (best-effort; document gaps if image label absent).

Forever-reject if metadata requires `privileged: true`, `securityOpt`, or equivalent unsupported security posture.

### F. Progress

Long feature steps MUST print stderr progress status lines (same `==>` / StatusPrinter family as today), including at least:

- Resolving features
- Fetching feature \<id\>
- Building derived image (and skip/reuse when tag exists)
- Configuring native arm64 builds (build.rosetta=false) — only when actually changing config

`ADEVCONTAINER_QUIET=1` silences progress status as today. `--json` keeps stdout pure JSON.

### G. Fixtures and tests

- Fixtures: `features-node.json`, `features-triple.json`, `features-local.json`, `features-docker-ood.json`, `features-sample/*`
- Unit tests: mock registry/fetch/build; local path uses on-disk samples; no network required for default suite
- Integration: local path E2E when Apple `container` available; OCI E2E opt-in via `ADEVCONTAINER_FEATURES_E2E=1`; never require docker-ood

### H. Non-goals

- docker-outside-of-docker / docker-in-docker / docker-from-docker, privileged, device passthrough, Compose
- Full upstream Features matrix / every edge of the Dev Container Features specification
- Feature authoring / publish CLI commands
- External ORAS install as a user dependency
- Node runtime for `adevcontainer` itself
- Blind `runArgs` or expanding forever-reject list exceptions for ood/privileged
- Installing Rosetta; default Features path must not require it

## Approach

Lite SDD: this proposal + delta `spec.md` + dependency-ordered `tasks.md`. Implementation extends Config resolver admission (`features` object), adds a Features subsystem (resolve → fetch/load → Dockerfile generate → `container build` → tag/reuse), and changes `up` so create uses the derived image when features are present. All `container` subprocesses remain behind **AppleContainerRuntime** (build/pull/inspect as needed). Test-first under MiniTest (`swift run adevcontainerTests`). No network package installs in tasks.

## Locked product decisions (summary)

| Topic | Decision |
|-------|----------|
| Admit `features` | Yes — MODIFY unsupported property policy |
| OCI refs | Yes — primary path |
| Local path features | Yes — `./`, `../`, `/`, `file://` via DefaultFeatureFetcher |
| docker-* markers | Forever-reject: `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` |
| privileged / securityOpt contributions | Forever-reject |
| Fetch | HTTPS/registry API in-runner for OCI; disk copy for local; not `container image pull` for feature artifacts |
| Build | `container build --platform` host-native + generated Dockerfile; install.sh as root; no `--rosetta` by default |
| build.rosetta | One-time consent to set `false` when needed; silent if already false; CI env `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` |
| Image tag | Deterministic from config hash + features hash; reuse if exists |
| Create image | Derived image when features present |
| ORAS external | No |
| Node for CLI | No |

(End of file)
