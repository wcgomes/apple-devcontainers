# Proposal: Align remote connection user resolution

## Intent

Today the product collapses `remoteUser` and `containerUser` into one `effectiveUser` and uses that single value for **create `-u`**, **labels**, **exec**, lifecycle hooks, VS Code customizations, and success JSON. When both config keys are unset, the label is empty, create omits `-u`, and consumers that need a connection user get nothing. Features-generated Dockerfiles end on `USER root`, so derived images do not restore the base image default user. VS Code nameConfig is written **after** host `code` launch, so attach can miss the intended remote user. Image inspect does not expose OCI `USER`, so there is no accurate fallback when config omits user keys.

This change **separates** container process user (create) from **remote connection user** (exec / attach / labels / VS Code / success JSON), aligns precedence with Dev Containers practice (`remoteUser` → `containerUser` → final OCI image `USER` → `root`), stamps a **non-empty** `devcontainer.remote_user`, restores base image `USER` after Features install, writes nameConfig **before** open, and is greenfield (no legacy empty-label migration).

## Scope

- Change id: **`align-remote-user-resolution`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/`; tests under `Tests/adevcontainerTests/`
- Realized base contract: union of `specs/<domain>.md`. This delta **adds** remote connection user resolution, create-user vs connection-user split, OCI image user exposure, and Features final-`USER` restore; **modifies** label stamp semantics for `devcontainer.remote_user`, success-JSON `remoteUser`, exec/VS Code/customizations/lifecycle consumer wording that currently say empty-when-unset or collapse both keys, nameConfig write ordering, and Features derived Dockerfile user policy.
- Commands / paths affected: create path on `up` / `clone` / `rebuild`; `exec`; lifecycle hook exec; VS Code `--vscode` open + nameConfig + settings/extensions apply + postAttach on `up` / `start` / `clone` / `rebuild`; image inspect used for resolution and Features restore.
- Greenfield: no migration of existing containers with empty `devcontainer.remote_user`; no backward-compat shims for the old collapsed `effectiveUser` create `-u` behavior.

## Non-goals

- Migrating or rewriting labels on already-created managed containers (operators use `rebuild` for a fresh stamp)
- Hardcoding product usernames such as `vscode` as a default when config and image omit user
- Changing selection, drift/hash identity inputs beyond stamping the resolved connection user into `devcontainer.remote_user`
- Changing Features `_REMOTE_USER` / `_CONTAINER_USER` install-env contract shape beyond feeding resolved values and restoring final image `USER`
- Full Dev Containers extension parity or Docker-only user/namespace features
- Requiring host VS Code for lifecycle success (nameConfig remains soft-fail; open remains soft-fail)
- Archive / domain fold (implement after this Lite change; fold at land)

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md` (no `design.md`).

1. Resolve **remote connection user** with precedence `remoteUser` → `containerUser` → final OCI image `USER` (from image inspect) → `root`. Treat inspect **failure** as failure to resolve that tier — **not** as “USER is root”.
2. Pass create `-u` when config sets a non-empty explicit `containerUser`; else when the resolved connection user is non-empty and not `root` (Apple attach uses container default user — no exec `-u`); else omit `-u`.
3. Stamp `devcontainer.remote_user` with the **resolved non-empty** remote connection user on every managed create (`up` / `clone` / `rebuild`).
4. Drive `exec`, lifecycle hooks, VS Code open/nameConfig/customizations/postAttach, and success-JSON `remoteUser` from that resolved connection user (stamped label on reuse/`exec`/`start` paths).
5. Features Dockerfile: install layers as root; after all features, restore the base image’s final `USER` (from inspect). Bump Features `recipeVersion` when install-Dockerfile semantics change.
6. Write optional nameConfig **before** host `code` launch on `--vscode` paths.
7. Test-first unit/command coverage with mocked runtime inspect; no hardcoded product usernames in resolution logic.
