# Proposal: Nested Dockerfile build

## Intent

`adevcontainer` hard-fails nested `build` and legacy `dockerFile`/`dockerfile`/`context` with "Dockerfile build is not supported", so image-based configs that build a local Dockerfile cannot `up`, `clone`, or `rebuild`. This change admits a v1 nested `build` translation through Apple `container build` so those configs become representable without Compose or a Features-branded path.

## Scope

- Change id: **`dockerfile-build`** (issue #40).
- Affected live domains: [core.md](../../../core.md) (property surface, unsupported-property source selectors, `up` create image selection, config hash), [features.md](../../../features.md) (Features `FROM` base when nested `build` is used), [managed-lifecycle.md](../../../managed-lifecycle.md) (purge of a dockerfile-only product tag).
- Admit nested `build` XOR top-level `image` on `up` / `clone` / `rebuild`. Build the user Dockerfile to a product tag, then run Features from that tag when `features` is non-empty (same effective-image swap as today).
- Keep top-level `dockerFile` / `dockerfile` / `context` blocked. Compose remains out of scope.

## Non-goals

- Docker Compose / multi-service configs.
- Top-level `dockerFile` / `dockerfile` / `context` (legacy selectors stay blocked).
- Other nested `build.*` keys (`options`, `cacheFrom`, `cacheTo`, and any key other than `dockerfile`, `context`, `args`, `target`).
- Hashing the build-context tree (COPY sources); operators run `rebuild` when those files change.
- Emulating Docker BuildKit cache imports/exports, privileged/DinD Dockerfiles, or inventing a workaround when Apple `container build` does not accept `--build-arg` / `--target`.
- Requiring `--no-cache` or operator image deletion so a rebuilt product Dockerfile tag becomes the Features `FROM` base (product-level tag reuse; `rebuild` invokes Features `container build` with the same tag name).
- Staging the whole guest workspace as volume-mode rebuild build context.
- Changing Features derived-tag format `adev-{base}:{hash12}`, Features purge policy, or `--skip-pull` as a skip of the product's explicit image-pull step.
- Wiki edits or archive of this change as part of specification creation.

## Approach

Admit nested `build` at the config boundary (xor `image`), resolve dockerfile/context paths, and on `up`/`clone` create paths build or reuse a product-local tag via Apple `container build --platform linux/arm64` behind `AppleContainerRuntime`. `rebuild` always invokes product `container build` (same tag name is fine) so unhashed COPY sources are picked up, and when Features are present also invokes Features `container build` even if that derived tag exists (same tag name; no `--no-cache`; no image delete). Clone-origin / volume-mode `rebuild` stages the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes and context `"."` is that directory. Apply the same `build.rosetta=false` gate as Features. When Features are present, obtain the user Dockerfile tag first and pass that tag as the Features `FROM` base. Stamp the product Dockerfile tag so dockerfile-only purge can delete it. Add `references/dockerfile/` as the v1 example.

## Decision index

- **Nested `build` xor `image`:** Exactly one source selector. `build.dockerfile` is required; `build.context` is optional and defaults to `"."`; `build.args` is an optional string map with the existing substitution subset; `build.target` is an optional string. Any other `build.*` key fails closed. Top-level `dockerFile` / `dockerfile` / `context` stay blocked.
- **Path confinement:** On `clone`, dockerfile and context MUST resolve inside the config-file directory (no `..`). Root `.devcontainer.json` plus a sibling `Dockerfile` with context `"."` is allowed. Bind `up` / `rebuild` MAY use `context: ".."`.
- **Features order:** Build the user Dockerfile first, then Features `FROM` that tag (same effective-image swap as today). On `rebuild` with nested `build` + Features, Features `container build` runs even when the derived tag exists.
- **Config hash:** MUST include dockerfile path, context, args, target, and Dockerfile file bytes. The context tree (COPY sources) is not hashed; the operator runs `rebuild`, which always invokes `container build`.
- **`--skip-pull` vs local build:** `--skip-pull` does not skip the local Dockerfile build. `up` and `clone` reuse the product-built tag when it already exists locally and MUST NOT invoke `container build`. `rebuild` MUST invoke `container build` even when that tag exists (same tag name is fine) so unhashed COPY sources are picked up.
- **Purge:** Stamped identity includes the product-built Dockerfile tag so dockerfile-only purge can delete it. Features-derived tags keep the existing purge policy.
- **Example:** `references/dockerfile/` with `.devcontainer.json` + `Dockerfile` (small `FROM`, no privileged/DinD). Update `references/README.md`.
- **Platform, consent, progress, errors:** Platform is `linux/arm64`. Same `build.rosetta=false` gate as Features. Progress is `==> Building image` (or Reusing). Errors use code `dockerfile_build` and property `build`, not Features-branded codes or properties.
- **Product tag:** Distinct from Features `adev-{base}:{hash12}` (e.g. `adev-{base}-df:{hash12}`; empty resource base `adevcontainer-df:{hash12}`, analogous to Features `adevcontainer:{hash12}`). Tag hash material is Dockerfile bytes + context path + args + target.
- **Apple build flags:** Apple `container build` must accept `--build-arg` / `--target` when those keys are set; if it does not, fail structured naming the key — do not invent a workaround.
- **Create paths:** `up` / `clone` / `rebuild` all take this path. `up`/`clone` build or reuse the product tag; `rebuild` always invokes product `container build`.
- **Rebuild Features force-build:** When nested `build` and Features are both present, `rebuild` MUST invoke Features `container build` even when that derived tag exists (same tag name allowed) so the in-place overwritten product Dockerfile tag (`adev-*-df:{hash12}`) becomes the Features `FROM` base. `up`/`clone` still reuse an existing Features derived tag. Do not add `--no-cache`. Do not require the operator to delete images. This is product-level tag reuse, not Docker layer cache. Image-based Features (no nested `build`) keep the realized rebuild reuse clause.
- **Volume-mode rebuild material:** Clone-origin / volume-mode `rebuild` MUST stage the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes (not empty) and `container build` can run. Typical `.devcontainer/devcontainer.json` + sibling Dockerfile with context `"."` is that directory (already staged as `.devcontainer/`). Root `.devcontainer.json` + sibling `Dockerfile` + context `"."` MUST stage files at that config-file directory level (root files / same-level siblings), not `src/` or other unfetched workspace trees, and MUST NOT skip `context: "."`. Clone still forbids `..`. Bind `up`/`rebuild` unchanged (host workspace is the context). Missing material MUST fail structured with `dockerfile_build` / property `build` before deleting the old container.
- **Missing inputs:** Missing dockerfile or context files → structured error. `image` + `build` → fail. Neither → fail.
- **No design.md:** Admission xor, path confinement, tag/hash split, `up`/`clone` reuse vs `rebuild` always-build, rebuild Features force-build, volume-mode config-dir staging, Features ordering, and purge stamping remain understandable in this index and in `tasks.md`; the overflow rule is not met.

## Clarifications

- **Q:** What nested `build` keys are in v1, and how do they relate to `image`?
  **A:** Nested `build` xor `image`. `build.dockerfile` required; `build.context` optional default `"."`; `build.args` optional string map with substitution; `build.target` optional string. Other `build.*` (`options`, `cacheFrom`, `cacheTo`) fail-closed. Top-level `dockerFile` / `dockerfile` / `context` stay blocked.

- **Q:** Where may dockerfile and context paths resolve on clone vs bind?
  **A:** Clone: dockerfile + context MUST resolve inside the config-file directory (no `..`). Root `.devcontainer.json` + sibling `Dockerfile` with context `"."` allowed. Bind `up` / `rebuild` MAY use `context: ".."`.

- **Q:** How do Features interact with a user Dockerfile?
  **A:** Build the user Dockerfile first, then Features `FROM` that tag (same swap as today). On `rebuild` with nested `build` + Features, Features `container build` runs even when the derived tag exists.

- **Q:** Does `rebuild` reuse an existing Features derived tag when nested `build` is present?
  **A:** No. `up`/`clone` still reuse that tag. `rebuild` MUST invoke Features `container build` even when it exists (same tag name allowed) so the force-rebuilt product Dockerfile tag becomes the Features `FROM` base. Do not add `--no-cache`. Do not require deleting images. Image-based Features keep the realized rebuild reuse clause.

- **Q:** What participates in config hash vs rebuild-for-COPY-sources?
  **A:** Config hash MUST include dockerfile path, context, args, target, and Dockerfile file bytes. Context tree (COPY sources) is not hashed; operator runs `rebuild`, which MUST invoke `container build` even when the product tag exists.

- **Q:** Does `--skip-pull` skip the local Dockerfile build? When is the tag reused?
  **A:** `--skip-pull` does not skip local Dockerfile build. `up`/`clone` reuse the product-built tag when it already exists and MUST NOT invoke `container build`. `rebuild` MUST invoke `container build` even when that tag exists (same tag name is fine).

- **Q:** What does purge delete for a dockerfile-built image?
  **A:** Stamped identity includes the product-built Dockerfile tag so dockerfile-only purge can delete it. Features-derived tags keep existing purge policy.

- **Q:** What example lands in-tree?
  **A:** `references/dockerfile/` with `.devcontainer.json` + `Dockerfile` (small FROM, no privileged/DinD). Update `references/README.md`.

- **Q:** Platform, Rosetta consent, progress lines, and error branding?
  **A:** Platform `linux/arm64`; same `build.rosetta=false` gate as Features. Progress `==> Building image` (or Reusing). Errors `dockerfile_build` / property `build`, not Features-branded.

- **Q:** What is the product Dockerfile tag, and what hashes it?
  **A:** Tag distinct from Features `adev-{base}:{hash12}` (e.g. `adev-{base}-df:{hash12}`). Hash material: Dockerfile bytes + context path + args + target.

- **Q:** What if Apple `container build` does not accept `--build-arg` or `--target`?
  **A:** Apple `container build` must accept `--build-arg`/`--target`; if not, structured fail naming the key — do not invent a workaround.

- **Q:** Which commands take the Dockerfile path?
  **A:** `up` / `clone` / `rebuild` all take this path. `up`/`clone` build or reuse; `rebuild` always invokes `container build`.

- **Q:** How does clone-origin / volume-mode `rebuild` obtain Dockerfile bytes?
  **A:** It MUST stage the config-file directory (not the whole workspace) so the tag hash uses real Dockerfile bytes (not empty) and `container build` can run. Missing material fails structured `dockerfile_build` / property `build` before deleting the old container.

- **Q:** What does volume/clone-origin `rebuild` stage as Docker context?
  **A:** The config-file directory, not the whole workspace. Typical `.devcontainer/devcontainer.json` + sibling Dockerfile with context `"."` is that directory (already staged as `.devcontainer/`). Root `.devcontainer.json` + sibling `Dockerfile` + context `"."` MUST stage files at that config-file directory level (root files / same-level siblings), not `src/` or other unfetched workspace trees, and MUST NOT skip `context: "."`. Clone still forbids `..`. Bind `up`/`rebuild` unchanged (host workspace is the context).

- **Q:** What happens when files or source selectors are missing or combined?
  **A:** Missing dockerfile/context files → structured error. `image`+`build` → fail. neither → fail.
