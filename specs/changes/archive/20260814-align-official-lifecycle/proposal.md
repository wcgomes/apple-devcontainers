# Proposal: Align official Dev Containers lifecycle

## Intent

This CLI already runs a subset of Dev Containers lifecycle hooks, but it rejects official keys (`initializeCommand`, `waitFor`, `userEnvProbe`, `shutdownAction`), runs object-map entries sequentially, gates `postAttachCommand` on `--vscode` open, and locks bare `adevcontainer start` to runtime-only (no `postStartCommand`, including volume-mode). Official Environment Creation / Resume expects host `initializeCommand`, parallel named entries, `waitFor`-gated tool connect, probed user env on injected processes, `postStart` on every successful start of a stopped container, and `postAttach` when the supporting tool attaches. This change aligns the product lifecycle with that official contract for this CLI.

## Scope

- Change id: **`align-official-lifecycle`**
- New bounded context (full official lifecycle alignment), not an in-place edit of active `vscode-customizations-up-clone-rebuild`
- Live contract to update: realized `specs/lifecycle-hooks.md`, `specs/managed-lifecycle.md`, `specs/vscode.md`, `specs/core.md`, `specs/clone.md`, plus active `specs/changes/vscode-customizations-up-clone-rebuild/spec.md`
- **ADD** host `initializeCommand`, `waitFor` readiness, `userEnvProbe` merge, `shutdownAction` admission, and feature `postStart` remelt on resume
- **MODIFY** lifecycle hook surface (admitted keys, parallel object-map, `postStart` on every real start, postAttach policy pointer)
- **MODIFY** Start managed container / lifecycle-hooks-on-start lock in both realized managed-lifecycle and the active vscode-customizations delta — this change **supersedes** that hook lock
- **MODIFY** postAttachCommand policy (CLI-only) to the CLI attach model below
- **MODIFY** Up lifecycle matrix (initialize, waitFor, postAttach, start-stopped feature postStart) and core admitted lifecycle property list
- **MODIFY** clone create-path note that currently claims postAttach is `--vscode`-gated
- **REPLACE** the “Volume-mode start runs no hooks” scenario (it becomes false)
- Unchanged and still in force: vscode customizations apply MUST NOT run on `adevcontainer start`; string/argv `sh -lc` vs argv rules; no new product commands

## Non-goals

- Cloud prebuild or periodic `updateContentCommand`
- Docker Compose / multi-service
- True IDE attach listener or waiting for VS Code Server ready
- Last-tool-window-close auto-stop (`shutdownAction` is admitted; the CLI cannot observe last-window close)
- `updateRemoteUserUID` (macOS / Apple container; not Linux bind UID sync)
- Applying vscode settings/extensions on `start` (that vscode-customizations lock stays)
- Changing string/argv shell invocation (`sh -lc` for strings remains)
- Inventing new product commands
- Feature-contributed `initializeCommand` (host-only; not in official feature metadata merge)
- Treating `adevcontainer exec` as attach
- Materializing the entire guest workspace (or re-fetching git) so volume-mode `initializeCommand` can use repo-root paths such as `./scripts/…`
- Starting a volume-mode container solely so `start` can run `initializeCommand`

## Approach

Lite SDD: this proposal + outcome delta `spec.md` only (no `design.md`, no `tasks.md` in this propose step).

Admit the remaining official lifecycle keys and run them on existing commands (`up`, `clone`, `rebuild`, `start`, `stop`, `exec`) as the CLI’s Environment Creation / Resume / attach model. Object-map stages become official parallel. `postStartCommand` runs after every successful start of a previously stopped container, including bare `start` in bind and volume modes, with config then remelted feature `postStart`. `postAttachCommand` ungates from `--vscode`: the CLI is the supporting tool, so attach runs at the end of successful `up` / `clone` / `rebuild` and after a real `start`; already-running `start` attaches only when `--vscode` open succeeds; open soft-fail MUST NOT suppress a CLI attach that would otherwise run.

**Live-contract conflict (active `vscode-customizations-up-clone-rebuild`):** that delta locks bare `start` as runtime-only — MUST NOT run hooks including `postStartCommand` — and keeps the scenario “Volume-mode start runs no hooks”. This change **supersedes that start hook lock** and replaces that scenario. It does **not** supersede “`start` MUST NOT apply vscode customizations”. postAttach rows in that delta that still say “only after successful `--vscode` open” are also superseded by this attach model.

## Decision index

- **Align the full official lifecycle for this CLI:** not a postStart-on-start-only tweak. Rationale: remaining official keys are currently rejected or wrong; one change keeps Creation / Resume / attach consistent.
- **`initializeCommand`:** admit; run on the host at the start of `up` / `clone` / `rebuild` and of a real start (stopped→running) when a host workspace exists (bind via stamped `local_folder` / config). Volume-mode / clone-origin **rebuild** with no usable host workspace: still run, cwd a temporary host workspace root that contains the current guest `.devcontainer/` (and root `.devcontainer.json` if that is the config) so `bash .devcontainer/…` works; remove the temp after the hook (success or fail). Missing `.devcontainer` dir must not skip (host-global commands still run). Repo-root paths like `./scripts/…` are not required. Do not copy the whole guest workspace. Do not re-fetch git (live volume config may have been edited). Volume-mode **start** with no host workspace: skip with a warning (cannot obtain guest files before start without starting). Already-running `start`: do not run (no start occurred).
- **Create-path hooks stay create-path:** `onCreate` / `updateContent` / `postCreate` remain `up` / `clone` / `rebuild` fresh create only. No cloud periodic `updateContent`. Feature hooks still merge on create-path.
- **`postStartCommand` on every real start:** MUST run after successful start of a previously stopped container on `adevcontainer start` (bind and volume) and on `up` start-stopped. Config hook then remelted feature `postStart`. Already-running `start` / `up` reuse: MUST NOT re-run. Restart/start failure: fail the command, MUST NOT delete. `start` recovery that delegates to `rebuild` MUST NOT double-run `postStart` after rebuild.
- **`postAttachCommand` CLI attach model:** ungate from `--vscode`. Official Environment Resume runs postStart and postAttach. Run postAttach at the end of successful `up` / `clone` / `rebuild`, and after a real `start`. Already-running `start`: only when `--vscode` open succeeds. `exec` is not attach. When `--vscode` is set, postAttach still runs after successful open; if open soft-fails on a path that would otherwise run postAttach as CLI attach, still run postAttach. Manual IDE UI attach without the CLI remains out of scope.
- **`waitFor`:** admit official enum; default `updateContentCommand`. Block Ready / optional vscode open / postAttach until the named stage inclusive has finished. Later create-path hooks MAY run in the background; the process SHOULD still wait for them before exiting so delete-on-fail and exit code stay correct. Do not emit success JSON until waitFor succeeded. A later background hook failure after Ready was emitted still fails the command exit; create-path delete-on-fail still applies to onCreate / updateContent / postCreate / first postStart; restart-class hooks MUST NOT delete.
- **Object-map form:** official parallel. Each named entry in a stage MUST run concurrently; the stage succeeds only if every entry exits 0. Replaces sequential sorted-by-name as the required behavior.
- **`userEnvProbe`:** admit `none` / `interactiveShell` / `loginShell` / `loginInteractiveShell`; default `loginInteractiveShell`. When not `none`, probe the remote connection user’s shell environment inside the container and merge into subsequent injected processes (lifecycle execs and `adevcontainer exec`). `none` skips.
- **`shutdownAction`:** admit enum. `stopContainer` (default for this image/Dockerfile product) matches existing `adevcontainer stop`. `none` does not change explicit `stop` (last-window-close remains out of scope). `stopCompose` MUST fail closed.
- **Shell invocation unchanged:** keep existing string → `sh -lc` and argv-without-shell rules.
- **vscode-customizations conflict:** this change supersedes the start hook lock only. `start` still MUST NOT apply vscode settings or extensions.
- **Image-metadata hooks survive create and resume:** official image fragments merge with config. Bake the **union** of base-image `devcontainer.metadata` and feature contributions onto the derived `LABEL` (not features-only). Fresh `up` / `rebuild` / `clone` with **empty features** still apply base-image metadata create-path + resume hooks. On `start`, if config load is nil, still remelt container+image metadata and run feature-only postStart (`failKeepContainer`); postAttach same when the CLI-attach gate would run. `up` / `rebuild` finish remelt MUST NOT replace-away base-image postAttach that apply already unioned. Do not remelt onCreate / updateContent / postCreate on resume. `initializeCommand` stays host/config-only.

## Clarifications

- **Q:** Align only postStart-on-start, or the official lifecycle for this CLI?
  **A:** The official lifecycle for this CLI, not just postStart-on-start.
- **Q:** When does `initializeCommand` run?
  **A:** On the host at the start of `up` / `clone` / `rebuild` and of a real start when a host workspace exists. Volume-mode / clone-origin rebuild with no usable host workspace still runs it on a temporary workspace root that contains the guest config directory/files. Volume-mode start with no host workspace skips with a warning. Already-running `start` does not run it.
- **Q:** How does volume-mode rebuild run `initializeCommand` when there is no durable host workspace?
  **A:** Option 2: place the current guest `.devcontainer/` directory (and root `.devcontainer.json` if that is the config) onto a host temporary workspace root; run the hook with that cwd so `bash .devcontainer/…` works; remove the temp after the hook (success or fail). Guest files are already readable while rebuild reads config from the volume. Missing `.devcontainer` must not skip. Repo-root paths like `./scripts/…` are not required. Do not copy the whole guest workspace. Do not re-fetch git. Volume-mode start stays skip+warn.
- **Q:** Do onCreate / updateContent / postCreate run on resume?
  **A:** No. Create-path only (`up` / `clone` / `rebuild` fresh create). No cloud periodic updateContent. Feature hooks still merge on create-path.
- **Q:** Does bare `start` run `postStartCommand`, including volume-mode?
  **A:** Yes, after every successful start of a previously stopped container (bind and volume `start`, and `up` start-stopped). Remelt feature postStart on resume. Already-running must not re-run. Restart failure must not delete. Rebuild-delegated start recovery must not double-run postStart.
- **Q:** Is postAttach still `--vscode`-only?
  **A:** No. CLI attach model: end of successful `up` / `clone` / `rebuild`; after a real `start`; already-running `start` only when `--vscode` open succeeds; `exec` is not attach; open soft-fail must not suppress a CLI attach that would otherwise run.
- **Q:** How should `waitFor` interact with Ready, open, postAttach, and process exit?
  **A:** Default `updateContentCommand`. Block Ready / open / postAttach until the named stage inclusive finishes. Later hooks may be backgrounded; Ready/open may happen at waitFor while the process continues remaining hooks. Do not emit success JSON until waitFor succeeded. Process exit still reflects remaining hook success. Create-path delete-on-fail still applies to onCreate / updateContent / postCreate / first postStart. Restart-class failures must not delete.
- **Q:** Object-map sequential or official parallel?
  **A:** Official parallel. Stage succeeds only if every named entry exits 0.
- **Q:** Admit `userEnvProbe`?
  **A:** Yes. Official enum; default `loginInteractiveShell`. Probe and merge into subsequent injected processes unless `none`.
- **Q:** Admit `shutdownAction`?
  **A:** Yes. `stopContainer` is the image/Dockerfile default and matches explicit `stop`. `none` does not disable explicit `stop`. `stopCompose` fails closed. Last-window-close auto-stop stays out of scope.
- **Q:** Change string/argv shell invocation?
  **A:** No. Keep existing `sh -lc` for strings.
- **Q:** Does this override the vscode-customizations start apply lock?
  **A:** No. Only the start hook lock is superseded. `start` still MUST NOT apply vscode customizations.
- **Q:** Do base-image `devcontainer.metadata` hooks survive Features bake and resume remelt?
  **A:** Yes. Bake the unioned contributions (base-image + features) onto derived `LABEL devcontainer.metadata`. Empty-features create still applies image-metadata create-path + resume hooks. `start` with unreadable config still remelts metadata postStart / CLI-attach postAttach. Finish remelt unions with apply (does not replace-away base-image postAttach).
