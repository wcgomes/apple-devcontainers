# Proposal: Features install-time containerEnv

## Intent

Feature packages declare `containerEnv` in `devcontainer-feature.json` so `install.sh` and the running container see the same keys (e.g. `DOTNET_ROOT`). Official `@devcontainers/cli` emits feature `containerEnv` as Dockerfile `ENV` **before** `install.sh`. adevcontainer only merges feature `containerEnv` at **runtime** create/exec (config wins on conflict). The generated install Dockerfile passes options + `_REMOTE_USER` / `_CONTAINER_USER` only — install scripts that read their own `containerEnv` fail under adevcontainer.

This change makes each feature’s declared `containerEnv` available to that feature’s `install.sh` during derived-image build (ref CLI parity), keeps runtime merge **config-wins**, and bumps Features `recipeVersion` so cached derived tags rebuild under the new install recipe.

**Defect fix (same change id):** An early implementation put metadata `containerEnv` on the install `RUN` export prefix via `shellEscape`, which single-quotes values containing `$`. That turned `PATH=$PATH:$DOTNET_ROOT` into the literal `PATH='$PATH:$DOTNET_ROOT'`, wiping system PATH (`dirname: command not found`). Correct shape matches `@devcontainers/cli`: emit non-empty feature `containerEnv` as Dockerfile **`ENV` lines before** that feature’s install `RUN` (BuildKit expands `$VAR`/`${VAR}`); keep options + `_REMOTE_USER`/`_CONTAINER_USER` on the RUN prefix so they still win over ENV for the install process. Product `recipeVersion` is `"5"` (prior epoch `"4"` was RUN-prefix containerEnv without expandable `$` refs).

## Scope

- Change id: **`features-install-containerenv`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; tests under `Tests/adevcontainerTests/`
- Realized base contract: union of `specs/<domain>.md`. This delta **modifies** **Derived image build** install-layer env (step 4) and the product `recipeVersion` epoch; **does not** change runtime **Merge feature metadata** config-wins policy for `containerEnv`.
- Paths affected: Features Dockerfile generation / install env assembly; `DerivedImageTag.recipeVersion`; unit coverage for generator + tag material.
- Greenfield install-recipe bump: existing local derived tags under prior epochs (`"3"`, `"4"`) MUST miss and rebuild after bump to `"5"`.

## Non-goals

- Changing runtime merge order or conflict policy (config `containerEnv` still wins over feature env)
- Host-side pre-expansion of install-time feature `containerEnv` `$PATH`/`$VAR` via `CreateRequest.expandEnvPathRefs` (preferred: Dockerfile `ENV` so BuildKit expands; runtime PATH expansion on create/exec unchanged)
- Applying config-file `containerEnv` into the install Dockerfile (install-time source is **feature metadata** only)
- Cross-feature env bleed: one feature’s `containerEnv` need not become global image `ENV` for later features beyond what is required so **that** feature’s `install.sh` sees its own keys
- Privileged / docker-* / securityOpt policy, OCI fetch, install-as-root / final `USER` restore semantics (beyond `recipeVersion` bump for this install-env change)
- Archive / domain fold (implement after this Lite change; fold at land)

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md` (no `design.md`).

1. Per feature install layer, emit that feature’s non-empty metadata `containerEnv` as Dockerfile `ENV` lines **before** the install `RUN` (values must not be shell single-quoted; `$VAR`/`${VAR}` remain expandable). Options + `_REMOTE_USER` / `_CONTAINER_USER` / homes stay on the RUN export prefix.
2. Empty or absent feature `containerEnv` MUST leave install env behavior otherwise unchanged (options + user keys only; no extra `ENV`).
3. Runtime merge of feature → config `containerEnv` remains **config wins**; no create/exec contract change. Config-file `containerEnv` is not written into the install Dockerfile.
4. Bump `DerivedImageTag.recipeVersion` to `"5"` so install-Dockerfile semantic change (ENV-before-RUN + expandable PATH refs) invalidates existing derived tags.
5. Test-first unit coverage on Dockerfile/install-env generation (including `PATH=$PATH:…` / no single-quote wipe) and recipeVersion/tag material; mock runtime as today.
