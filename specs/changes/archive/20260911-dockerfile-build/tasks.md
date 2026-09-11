# Tasks: dockerfile-build

Spec ref: `specs/changes/dockerfile-build/`. Execute test-first: write the failing tests and confirm the expected failures before changing production code. Do not invent Apple `container build` workarounds for `--build-arg` / `--target`. Do not hash the context tree. `up`/`clone` reuse an existing product tag and an existing Features derived tag; `rebuild` always invokes product `container build`, and with nested `build` + Features also Features `container build` even when that derived tag exists (same tag name; no `--no-cache`; no image delete). Volume/clone-origin `rebuild` stages the config-file directory, not the whole workspace. Do not edit the wiki.

## 1. Reference example and failing admission tests

- [ ] 1.1 Add `references/dockerfile/.devcontainer.json` with nested `build` (no top-level `image`) [P] (path: `references/dockerfile/.devcontainer.json`)
- [ ] 1.2 Add a small sibling `Dockerfile` (`FROM` only; no privileged/DinD) [P] (path: `references/dockerfile/Dockerfile`)
- [ ] 1.3 Mention the dockerfile example in the references index (path: `references/README.md`)
- [ ] 1.4 Write failing tests: nested `build` without `image` admits; `image`+`build` fails; neither fails; top-level `dockerFile`/`dockerfile`/`context` stay blocked; unknown `build.*` fails; missing `dockerfile` fails; omitted `context` defaults to `"."`; non-string `args`/`target` fail; `build.args` receive the existing substitution subset; nested `build` is on the supported surface (path: `Tests/adevcontainerTests/CompatibilityPolicyTests.swift`)
- [ ] 1.5 Update unrepresentable-source tests so Compose and top-level dockerfile selectors still fail, while nested `build` with this translation is no longer treated as unrepresentable (path: `Tests/adevcontainerTests/CompatibilityPolicyTests.swift`)
- [ ] 1.6 Run the suite of record and confirm failures are limited to missing nested-`build` admission before production edits (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [ ] verify **Nested build without image admits**, **Image and nested build together fail**, **Neither image nor nested build fails**, **Top-level dockerfile selectors remain blocked**, **Unknown nested build key fails closed**, **Missing build.dockerfile fails**, **Omitted build.context defaults to dot**, **Non-string build.args or target fails closed**, and **build.args receive substitution** are covered by red tests
- [ ] verify **nested build is on the supported surface** and **Unrepresentable source selector remains blocked** (Compose and top-level dockerfile selectors) are covered
- [ ] verify **dockerfile reference admits** has an in-tree example to target

## 2. Admission and resolved model

- [ ] 2.1 Admit nested `build` xor `image`; keep top-level `dockerFile`/`dockerfile`/`context` and Compose blocked; fail unknown nested keys and invalid shapes with property `build` (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [ ] 2.2 Model admitted build fields on the resolved config (dockerfile, context default `"."`, args, target) and stop requiring `image` when nested `build` is present (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [ ] 2.3 Apply the existing substitution subset to `build.args` values and carry defaults through resolve (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [ ] 2.4 Stop describing Dockerfile nested `build` as unsupported in CLI help; keep Compose and top-level dockerfile selectors as hard errors (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)

## Checkpoint

- [ ] verify **Nested build without image admits**, **Image and nested build together fail**, **Neither image nor nested build fails**, **Top-level dockerfile selectors remain blocked**, **Unknown nested build key fails closed**, **Missing build.dockerfile fails**, **Omitted build.context defaults to dot**, **Non-string build.args or target fails closed**, **build.args receive substitution**, and **nested build is on the supported surface** pass
- [ ] verify **Unrepresentable source selector remains blocked** still fails Compose and top-level dockerfile selectors
- [ ] verify **dockerfile reference admits**

## 3. Hash material and product tag (test-first)

- [ ] 3.1 Write failing tests: config hash includes dockerfile path, context, args, target, and Dockerfile bytes; those changes alter the hash; other context-tree files do not; product tag is `adev-{base}-df:{hash12}` (empty base `adevcontainer-df:{hash12}`) and distinct from Features `adev-{base}:{hash12}` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [ ] 3.2 Include dockerfile path, context, args, target, and Dockerfile file bytes in config hash material; do not hash the context tree (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [ ] 3.3 Compute the product Dockerfile tag from Dockerfile bytes + context path + args + target only (`adev-{base}-df:{hash12}`; empty base `adevcontainer-df:{hash12}`); do not reuse Features `recipeVersion` or `adev-{base}:{hash12}` (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)

## Checkpoint

- [ ] verify **Dockerfile bytes and build fields change config hash**
- [ ] verify **Context tree is not hashed**
- [ ] verify **Product Dockerfile tag is distinct from Features tag**

## 4. Runtime build argv, errors, and progress (test-first)

- [ ] 4.1 Add structured error code `dockerfile_build` (distinct from `feature_build`) (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [ ] 4.2 Write failing tests: `container build` includes `--platform linux/arm64`, `-f`, context, optional `--build-arg` / `--target`; runtime rejection of those flags fails naming `args` or `target` with no workaround; user-Dockerfile build failure uses `dockerfile_build` / property `build`; progress `==> Building image` / `==> Reusing image` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [ ] 4.3 Extend `AppleContainerRuntime.build` to pass `--build-arg` / `--target` when set; map user-Dockerfile failures to `dockerfile_build` / property `build`; keep Features callers on `feature_build`; do not invent a workaround if Apple rejects those flags (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)

## Checkpoint

- [ ] verify **build.args map to --build-arg or fail naming args**
- [ ] verify **build.target maps to --target or fail naming target**
- [ ] verify **Dockerfile build failure is not Features-branded**
- [ ] verify **Progress Building image during dockerfile build** and reuse wording are testable on the runtime/status path

## 5. Up create path (test-first)

- [ ] 5.1 Write failing tests: fresh `up` with nested `build` and no features builds or reuses `adev-{base}-df:{hash12}` with `--platform linux/arm64`; `--skip-pull` still builds; missing dockerfile/context files fail `dockerfile_build` / property `build`; bind `context: ".."` is allowed; dockerfile-only does not invoke Features build; rosetta gate runs before dockerfile build (at most once); reuse-running does not rebuild the Dockerfile (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [ ] 5.2 On `up` create, resolve dockerfile/context against the config-file directory, ensure `build.rosetta=false` once, build or reuse the product tag, ignore `--skip-pull` for that local build, and create from the product tag when Features are absent (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)

## Checkpoint

- [ ] verify **Fresh up builds and creates from the product Dockerfile tag**
- [ ] verify **Existing product Dockerfile tag is reused**
- [ ] verify **skip-pull does not skip local Dockerfile build**
- [ ] verify **Missing dockerfile file fails structured** and **Missing context directory fails structured**
- [ ] verify **Bind up may use context parent**
- [ ] verify **Dockerfile-only create does not require Features build**
- [ ] verify **build.rosetta gate runs before dockerfile build**
- [ ] verify **Up without features unchanged image path** still uses config `image` when nested `build` is absent
- [ ] verify **Reuse running does not re-fetch features** still does not rebuild the Dockerfile

## 6. Clone and rebuild create paths (test-first)

- [ ] 6.1 Write failing tests: clone with in-directory dockerfile/context (root `.devcontainer.json` + sibling `Dockerfile` context `"."`, or nested `.devcontainer/` pair) builds or reuses the product tag; `--skip-pull` still builds; clone `..` escape fails; clone config fetch materializes those in-directory files (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [ ] 6.2 Write failing tests: `rebuild` of a nested-`build` container always invokes `container build` even when the product Dockerfile tag already exists (same tag name allowed); `--skip-pull` still builds; progress is `==> Building image`; rosetta gate runs at most once before dockerfile and Features (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 6.3 Wire clone create through the same Dockerfile path (rosetta once, skip-pull does not skip local build, tag reuse) and reject dockerfile/context that escape the config-file directory (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [ ] 6.4 Confirm clone config-only fetch already materializes in-directory dockerfile/context (root sibling files and `.devcontainer/` tree); change sparse fetch only if tests show those files are missing (path: `Sources/ADevContainerLib/Git/GitClient.swift`)
- [ ] 6.5 Write failing tests: clone-origin / volume-mode `rebuild` stages the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes (not empty) and `container build` can run; root `.devcontainer.json` + sibling `Dockerfile` + context `"."` stages config-dir siblings (not only the Dockerfile file) and does not skip `context: "."`; missing dockerfile or context material fails structured `dockerfile_build` / property `build` before the old container is deleted (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 6.6 Wire rebuild replacement through the Dockerfile path: always invoke `container build` (same tag name allowed; do not skip because the tag exists), skip-pull does not skip local build, rosetta once, build before create; Features pre-delete ordering unchanged. On clone-origin / volume-mode rebuild, stage the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes; root `.devcontainer.json` + sibling `Dockerfile` + context `"."` stages config-dir siblings (not only the Dockerfile file) and does not skip `context: "."`; missing material fails `dockerfile_build` / property `build` before deleting the old container (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint

- [ ] verify **Clone in-directory dockerfile builds**
- [ ] verify **Clone context parent is rejected**
- [ ] verify **Rebuild takes the dockerfile path** (`container build` even when the product tag exists)
- [ ] verify **Existing product Dockerfile tag is reused** on clone only (not rebuild)
- [ ] verify **skip-pull does not skip local Dockerfile build** on clone and rebuild
- [ ] verify **Volume-mode rebuild uses real Dockerfile bytes**
- [ ] verify **Volume-mode rebuild root-sibling context stages config-dir siblings**
- [ ] verify **Volume-mode rebuild missing dockerfile material fails before delete**

## 7. Features FROM dockerfile tag (test-first)

- [ ] 7.1 Write failing tests: nested `build` + Features obtains the product Dockerfile tag first (`up`/`clone` build or reuse; `rebuild` always `container build`), Features `FROM`s that tag, create uses the Features derived tag; image-based Features path is unchanged (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [ ] 7.2 Write failing tests: `rebuild` with nested `build` + Features invokes Features `container build` even when the Features derived tag already exists (same tag name allowed; operator not required to delete images); image-based Features rebuild reuse is unchanged (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [ ] 7.3 Keep Features generated Dockerfiles `FROM`ing the supplied `baseImage` with no assumption that it is config `image` (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`)
- [ ] 7.4 On `up`, build/reuse the user Dockerfile before `FeaturesRunner.run` and pass that tag as `baseImage` (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [ ] 7.5 On `clone`, build/reuse the user Dockerfile before Features and pass that tag as `baseImage` (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [ ] 7.6 On `rebuild`, always `container build` the user Dockerfile before Features, pass that tag as `baseImage`, and request Features force-build when nested `build` is present (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [ ] 7.7 When rebuild requests Features force-build, invoke `container build` even if the derived tag exists (same tag name allowed; do not add `--no-cache`; do not require deleting images) (path: `Sources/ADevContainerLib/Features/FeaturesRunner.swift`)

## Checkpoint

- [ ] verify **Features FROM the dockerfile tag when both are present**
- [ ] verify **Features FROM dockerfile tag when nested build is present**
- [ ] verify **Rebuild with nested build rebuilds Features even when derived tag exists**
- [ ] verify **Rebuild with nested build does not reuse Features derived tag**
- [ ] verify **Create uses derived image after build** still holds for image-based Features
- [ ] verify **Up with features builds then hooks** still holds for image-based Features
- [ ] verify **rebuild with unchanged features material reuses derived tag** still holds when nested `build` is absent

## 8. Purge stamping (test-first)

- [ ] 8.1 Write failing tests: dockerfile-only purge deletes the product Dockerfile tag; Features-derived tags are not removed solely because nested `build` was used (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [ ] 8.2 Confirm dockerfile-only create leaves the product Dockerfile tag as the inspect/config image so existing purge image-delete removes it; change purge only if that tag is not visible as the config image; keep existing Features-derived tag policy (path: `Sources/ADevContainerLib/Commands/PurgeCommand.swift`)

## Checkpoint

- [ ] verify **Purge dockerfile-only deletes the product Dockerfile tag**
- [ ] verify **Purge does not delete Features-derived tags solely because dockerfile was used**

## 9. Validation

- [ ] 9.1 Run `swift build` and fix only build failures introduced by this change (path: `Package.swift`)
- [ ] 9.2 Run `swift run adevcontainerTests` and confirm every scenario in this change maps to a passing test; platform-gated Apple runtime tests may skip when unavailable (path: `Tests/adevcontainerTests/main.swift`)
- [ ] 9.3 Inspect the final diff for scope, Features-branded dockerfile errors, context-tree hashing, Apple build-flag workarounds, `--no-cache` / required image deletes, whole-workspace volume rebuild staging, unresolved clarification markers, and accidental wiki edits (path: `specs/changes/dockerfile-build/spec.md`)

## Checkpoint

- [ ] all locally runnable change scenarios map to passing tests; Apple runtime scenarios are explicitly gated and skipped when unavailable
- [ ] unchanged Supported property surface and Unsupported property policy scenarios remain green
- [ ] no unresolved clarification placeholders remain
- [ ] no user-Dockerfile failure uses `feature_build` or property `features`
- [ ] only files required by this change are modified
