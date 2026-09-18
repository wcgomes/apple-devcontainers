# Proposal: Feature entrypoint keep-alive wrap

## Intent

Official `@devcontainers/cli` honors Feature metadata `entrypoint` at main-container create: PID 1 is a wrapper that runs each Feature entrypoint as its own script line, then keep-alive `/bin/sleep infinity`. adevcontainer always creates with `--entrypoint /bin/sleep` and `infinity`, so Feature entrypoints never run. Users then need `postStartCommand` (or similar) for Features such as sshd. This change makes `adevcontainer up` match that default Docker/Podman Dev Containers UX without treating entrypoint as a lifecycle hook.

## Scope

- Change id: **`feature-entrypoint-keep-alive`**
- Domain: [features.md](../../features.md) **Merge feature metadata into create and lifecycle** (add `entrypoint`) plus an added features-domain wrap requirement. `specs/core.md` has no named requirement covering create entrypoint/keep-alive argv, so this change does not modify core.
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; tests under `Tests/adevcontainerTests/`
- Main managed create only: parse Feature `entrypoint` strings in install order; wrap then keep-alive when any are non-empty; otherwise keep today’s `--entrypoint /bin/sleep` image `infinity`.
- Active unrelated change `install-plugin-command` stays untouched.

## Non-goals

- SSH special-case (no sshd-only path; Feature `entrypoint` is generic)
- Changing `overrideCommand: false` (remains blocked) or treating `overrideCommand: true` as distinct from the product keep-alive default
- Honoring image Dockerfile `ENTRYPOINT`/`CMD`
- Baking `ENTRYPOINT` into the Features install Dockerfile
- Bumping Features `recipeVersion`
- Treating Feature `entrypoint` as a postStart remelt/exec lifecycle hook
- Applying Feature entrypoints to ownership or recovery helper creates
- `clone --ssh`
- Allowing `runArgs --entrypoint` (forever rejected)
- Workspace `.devcontainer` sshd/postStart local test edits
- Wiki edits, archive, or product/Sources/Tests implementation as part of writing these artifacts

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md` (no `design.md`).

Parse Feature metadata `entrypoint` as a string in install order. Empty or absent values contribute nothing. When one or more non-empty strings exist, main managed create uses a `/bin/sh -c` wrapper that runs each as its own script line (not `exec`’d unless the script itself execs), then `exec /bin/sleep infinity` so keep-alive remains final PID 1. Ownership and recovery helper creates keep sleep-only argv. `${devcontainerId}` in an entrypoint uses the existing deferred create-time substitution. Non-string metadata fails closed in the Feature metadata error family.

## Decision index

- **String metadata, install order:** Parse Feature `devcontainer-feature.json` `entrypoint` as a string. Collect non-empty values in Feature install order. Empty or absent → no contribution (today’s create argv).
- **Main managed create only:** When one or more non-empty entrypoints exist, create MUST use a `/bin/sh -c` wrapper that runs each Feature entrypoint as its own script line, then `exec /bin/sleep infinity`. Same shape as official CLI (entrypoints then keep-alive), not image `ENTRYPOINT`/`CMD`.
- **Keep-alive stays PID 1:** The wrapper MUST NOT `exec` a Feature entrypoint unless that script itself execs. Final PID 1 remains `/bin/sleep infinity`.
- **Empty list is today’s argv:** `--entrypoint /bin/sleep` image `infinity` when no non-empty Feature entrypoints.
- **`overrideCommand` unchanged:** Default `true` stays a silent keep-alive restatement. `false` stays blocked. Image Dockerfile `ENTRYPOINT`/`CMD` stay discarded.
- **Helpers stay sleep-only:** Ownership and recovery helper creates MUST keep the current sleep-only entrypoint (empty Feature entrypoint list).
- **Not a Dockerfile change:** Do not emit Dockerfile `ENTRYPOINT` in Features build. Do not bump `recipeVersion`.
- **Not a lifecycle hook:** `container start` re-runs PID 1. MUST NOT remelt Feature entrypoint via exec on start/resume.
- **`${devcontainerId}`:** Expand in Feature entrypoint strings with the same deferred create-time substitution already used for mounts/`containerEnv`. No new mechanism.
- **Non-string fails closed:** Non-string `entrypoint` in Feature metadata MUST fail structured in the same family as other Feature metadata type errors.
- **No `design.md`:** Wrap shape, helper exclusion, and substitution reuse remain understandable in this index and in `tasks.md`; the overflow rule is not met.
