# Architecture

Greenfield native Swift executable (arm64). Reads `devcontainer.json`, drives Apple `container` CLI. No Node runtime for this product.

## Host and deps

| Item | Value |
|------|--------|
| Host | macOS 26+, Apple Silicon only |
| CLI language | Swift 6.x (SPM; full Xcode not required) |
| User runtime dep | Apple `container` CLI (install separately — [apple/container](https://github.com/apple/container); tested with 1.2.x JSON) |
| Apple container binary (typical) | `/usr/local/bin/container` |
| Product binary | `adevcontainer` |
| GitHub repo | [wcgomes/apple-devcontainers](https://github.com/wcgomes/apple-devcontainers) (ex-`apple-dev-containers`, ex-`dev-containerization`) |
| Release / install | CI + GitHub Release tarball; Homebrew primary — [release-distribution.md](conventions/release-distribution.md) |

## Package layout

| Path | Role |
|------|------|
| `Sources/ADevContainerLib` | Library: resolver, runtime, commands, Features, shared types |
| Thin executable target | CLI entry only; links the lib |
| `adevcontainerTests` | Executable product — **suite of record** (MiniTest) |

On CLT-only hosts, XCTest / `swift test` may report no tests. Run the suite with:

```bash
swift run adevcontainerTests
```

## Pipeline

```
devcontainer.json → Config resolver → [Features runner] → AppleContainerRuntime → /usr/local/bin/container
```

1. **Config resolver** — JSONC parse; variable substitution (`${localEnv:*}`, `${localWorkspaceFolderBasename}`, `${containerWorkspaceFolder}`, `${devcontainerId}` — latter may stay literal until create identity is known); validate supported props; hard-error unsupported (never silent ignore).
2. **Features runner** (when `features` non-empty) — load local path and/or fetch OCI features; order; ensure `build.rosetta=false`; derived image build; swaps effective image before create. Then expand deferred `${devcontainerId}` in mounts/`containerEnv` before volume ensure + create. Detail: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md) (`${devcontainerId}` deferred expand).
3. **AppleContainerRuntime** — sole boundary to the external `container` CLI; subprocess invoke; parse machine-readable JSON only. Features OCI fetch is separate (embedded HTTPS); local path is disk copy.
  4. **Apple container** — create/run/exec/stop/delete/prune/inspect/build of the managed dev container and related config volumes/image.

## Workspace modes

| Mode | Entry | Workspace storage | Host FS path |
|------|-------|-------------------|--------------|
| **Bind** | `up` from host workspace | Host dir via virtiofs (APFS) | Real path on Mac |
| **Volume** | `clone <git-url>` | Named volume via virtio-blk (`volume.img` ext4) | No durable host checkout; label `local_folder=volume://…` |

Volume mode exists for better metadata I/O (git status, node_modules, many small files) vs virtiofs binds. Contract: [`specs/clone.md`](../specs/clone.md) (archived change `20260808-clone-in-volume`).

## Commands (product surface)

| Command | Role |
|---------|------|
| `doctor` | Host/runtime readiness checks |
| `up` | **Bind-mode** only: resolve config from host workspace, create/start/reuse; ensure named volumes; workspace bind; Features; lifecycle hooks in scope. Optional `--vscode` after success (see [VS Code flow](#vs-code-flow)). Reuse only when stamped config hash matches; mismatch → fail `config_hash_mismatch` (remediate with `rebuild`). Eligible bring-up failure with an editable host `devcontainer.json` → [bring-up recovery](#bring-up-recovery) |
| `clone <git-url> [--resume]` | **Volume-mode** workspace (VS Code clone-in-volume analogue): host sparse/shallow **config-only** fetch → resolve (workspaceFolder default + `${localWorkspaceFolderBasename}` = **git URL repo basename**, not temp dir name) → **author identity before Features/create:** host `git -C <sparse-temp> config --get user.name/email` (includeIf-aware; env `ADEVCONTAINER_GIT_AUTHOR_*`); both env → skip prompt; TTY confirm/override or collect; non-TTY silent + warn if incomplete → **ensure Features `ghcr.io/devcontainers/features/git:1` when no `git`/`common-utils`** (Features path, not apt; `up` unchanged) → ensure workspace volume → create + start (**SSH:** inject `create --ssh` when `SSH_AUTH_SOCK` set) → **in-container full `git clone`** + verify `.git` (**HTTPS:** host `git credential fill` one-shot → guest `credential.helper store`; no GCM-in-guest; no host full+tar happy path) → author both → guest `--local`; else warn, no partial → create-path hooks. Eligible failure retains the config checkout (not always-clean). Optional `--vscode` after success. Resume: `clone --resume <config-dir>` — [bring-up recovery](#bring-up-recovery) |
| `rebuild [--name]` | **Forced-rebuild** path (realized in domain specs; archive [`20260810-rebuild`](../specs/changes/archive/20260810-rebuild/)): managed selection (`--name` / auto-single / picker); read **current** stamped `devcontainer.json` before any delete; after config/host/Features succeed → container-only delete old → create same name (bind) or same `*-ws` workspace volume (volume; data preserved, never re-clone). Volume/clone-origin with no host workspace still runs host `initializeCommand` from a temp guest-config root (not skip). Optional `--skip-pull` / `--vscode` / `--json`. Recovery mode-split (TTY prompt Y/n, retain): [gaps](domain/devcontainer-apple-gaps.md#failed-rebuild-recovery-mode-split) |
| `list [--json]` | Managed containers only (`devcontainer.managed=adevcontainer`) |
| `start [--name]` | Start a managed stopped container via `--name` or interactive picker. **Real start** (stopped→running, bind+volume): host `initializeCommand` when a host workspace exists (volume start without host path skips+warns) → `postStartCommand` + feature remelt → CLI-attach `postAttachCommand`. **Already-running start:** no initialize/postStart; postAttach only after successful `--vscode` open. **Never applies** settings/extensions. Optional `--vscode` is **open only**. postAttach loads config from labels (bind: host `local_folder`+`config_file`; volume: in-container config path) and merges feature postAttach from image `devcontainer.metadata` (load errors → treat absent, do not fail start). Start failure recovery delegates to `rebuild --name` — does **not** re-run start or open an editor |
| `exec [--name]` | Run command/shell in running managed container (`-it` / empty cmd → interactive TTY, default `bash`). Selection: `--name` or picker (no `-w`). User/workdir from labels `devcontainer.remote_user` / `devcontainer.workspace_folder` when stamped (new creates always stamp non-empty `remote_user` incl. `root`; empty = legacy — see [Connection user](#connection-user)) |
| `stop [--name]` | Stop managed container (`--name` or picker; no `-w`) |
| `delete [--name]` | Remove **container only** (`--name` or picker; no `-w`) |
| `prune [--name]` | Remove container **and** unreferenced candidate volumes (labels `config_volumes` / `workspace_volume` = candidates only; real mounts after target delete decide) **and** config image (`--name` or picker; not binds; not global prune; shared volumes preserved) |
| `inspect [--name]` | Show resolved identity/state (`--name` or picker; no `-w`) |

**Selection:** only `up` takes `-w`/cwd (bind workspace). Lifecycle commands (`start`/`exec`/`stop`/`delete`/`prune`/`rebuild`/`inspect`) resolve managed containers by `--name` or interactive picker — never `-w`.

**Config drift / forced rebuild:** `up` reuses a matching managed container. Existing managed container with a stamped config hash that differs from the current resolve → structured fail `config_hash_mismatch` (hint: `adevcontainer rebuild` with managed selection). A forced rebuild uses **`rebuild`**. Hash mismatch is not bring-up recovery.

### Bring-up recovery

Shared primitive `BringUpRecovery`. Rebuild hard post-delete recovery is separate and unchanged: [gaps](domain/devcontainer-apple-gaps.md#failed-rebuild-recovery-mode-split). Contract: [`specs/clone.md`](../specs/clone.md) + [`specs/managed-lifecycle.md`](../specs/managed-lifecycle.md); archive [`20260814-bring-up-recovery`](../specs/changes/archive/20260814-bring-up-recovery/).

| Path | Behavior |
|------|----------|
| `up` | Edit host `devcontainer.json`; retry from scratch (re-resolve + create path). Deletes leftover containers including after a later retry or `name` change. No helper, no retained checkout. |
| `clone` | Retain product-managed config-only checkout; TTY edits retained config and retries without re-fetch. Non-TTY/`--json` print exact `clone --resume <config-dir>`. Resume/remove: managed root + marker only; never delete an external path. Successful TTY retry/`--resume` overlays the edited `devcontainer.json` into the guest workspace **after populate** (replaces the git-populated original). Overlay is clone-recovery only; none when there is no editable config. |
| `start` | TTY prompt then `rebuild --name`. Does **not** re-run start, open an editor, or write config. |
| Offer | Editable `devcontainer.json` exists. Triggers: parse/resolve on an existing file, create, start, ownership, clone populate, create-path hooks. |
| No offer | Config missing; clone fetch fails before any config exists. |
| Prompt | TTY (no `--json`): `Open the recovery editor now? [Y/n]` default **Y**. Decline/EOF → original error. Non-TTY/`--json` never prompt. |

**delete vs prune:** `delete` drops the managed dev container only (no volumes). `prune` also removes the config `image` and **unreferenced** candidate named volumes: labels `config_volumes` / `workspace_volume` are the **candidate set only**; after the target container is gone, real mounts on all remaining containers (running/stopped, managed or not — `containersAttached` / `list --all`) decide delete vs preserve. Shared/referenced volumes stay with a StatusPrinter warning listing referencers (share-only → exit 0). Container delete fail → no volume deletes; attachment inspect fail → preserve affected volume(s) + non-zero. Same volume name = shared Docker-like resource (labels on containers, not volumes). Neither deletes bind-mount host paths or runs global `volume`/`image` prune. Derived Features tags (`adev-{base}:{hash12}` / `adevcontainer:{hash12}`) are not removed by `prune` unless they equal the config `image` field. Recovery-helper prune skip unchanged. Contract: [`specs/managed-lifecycle.md`](../specs/managed-lifecycle.md); archive [`20260812-prune-shared-volume-safety`](../specs/changes/archive/20260812-prune-shared-volume-safety/).

**Progress:** StatusPrinter phases on stderr (`==> …`); internal tool tees framed `    | ` (hooks, Features build, clone populate `streamOutput`); connection hints are **info** (not `==> `) after successful `up`/`clone`/`start`/`rebuild` unless originating `--vscode`. User `exec` unframed; interactive TTY unchanged. QUIET silences phase/info only; warn/error/tool body emit. `--json` stdout pure. Full stack: [terminal-output.md](conventions/terminal-output.md); runtime tee notes: [cli-runtime-boundary — Progress/tee](conventions/cli-runtime-boundary.md#progress--tee).

## Identity

- **Human base:** sanitize(`devcontainer.json` `name`) when non-empty after trim; else sanitize(workspace folder basename) — **volume-mode:** git URL repo basename (not a temp host path). DNS-safe: lowercase; non-`[a-z0-9-]` → `-`; **collapse consecutive hyphens** (`-{2,}` → `-`); trim leading/trailing hyphens; clip base ~20 chars. Punctuation-heavy names must not yield invalid Apple refs (e.g. `C# (.NET)` → `c-net` → Features tag `adev-c-net:{hash12}`, never `adev-c----net:…` — Apple rejects consecutive hyphens in references).
- **Container name:** `adev-{base}-{hash12}`; empty base → `adev-{hash12}`; ≤63 chars. Apple `container create --name` is the container **id**.
  - **Bind-mode `hash12`:** workspace path + config path.
  - **Volume-mode `hash12`:** normalized git URL + config relpath (not a temp host path). Stable across reclones of the same repo/config.
- **Workspace volume (volume-mode):** `adev-{base}-{hash12}-ws`.
- **Features derived tag** (when Features build runs): `adev-{base}:{hash12}` (content hash of base image + features + `recipeVersion` epoch in `DerivedImageTag`; bump epoch on install-Dockerfile semantic changes — current **`"6"`**; see [cli-runtime-boundary](conventions/cli-runtime-boundary.md)); empty base → `adevcontainer:{hash12}`. No `adevcontainer/features:` prefix. Plain config `image` (no Features) is unchanged.
- **Labels (managed set):** stamped on create for both modes — `devcontainer.managed=adevcontainer`, `devcontainer.local_folder` (bind: host path; volume: `volume://…`), `devcontainer.config_file`, app config hash, `devcontainer.workspace_mode` (`bind` on `up`, `volume` on `clone`), `devcontainer.workspace_folder`, `devcontainer.remote_user` (**always non-empty on new creates** — resolved connection user, including `root`; empty = legacy only), `devcontainer.config_volumes` when applicable. Volume-mode also `devcontainer.git_url` (userinfo stripped), `devcontainer.workspace_volume`.
- **Config hash on `up`:** reuse/start-stopped only when stamped hash matches current resolve; mismatch → `config_hash_mismatch`; use `rebuild` for a forced rebuild. See [cli-runtime-boundary](conventions/cli-runtime-boundary.md#up-reuse-vs-rebuild-forced-rebuild).
- Enables find/reuse without Docker-style label filter APIs (list has no label filter — client-side filter; `list` keeps only managed). See [gaps](domain/devcontainer-apple-gaps.md).

## Connection user

Effective user for `exec`, lifecycle hooks, and VS Code attach defaults (not always the create process user):

| Order | Source |
|-------|--------|
| 1 | Local `remoteUser` |
| 2 | Local `containerUser` |
| 3 | Image `devcontainer.metadata` last non-empty `remoteUser`/`containerUser` |
| 4 | Final OCI `USER` (`variants[].config.config.User` on Apple image inspect) |
| 5 | `root` only if inspect OK and all above empty |

- **Create `-u`:** (1) explicit local `containerUser` if set; (2) else non-root connection user; (3) else omit when root. Apple attach ignores nameConfig `remoteUser` and uses container default user — product therefore applies non-root connection user at create so the VS Code terminal matches. When both keys set: create = `containerUser`, connection = `remoteUser`.
- **Stamp:** successful create always stamps non-empty `devcontainer.remote_user` (resolved connection user, including `root`). Empty stamp is legacy only. `exec` / `--vscode` consume it. No hardcoded `vscode`/`node`; inspect failure ≠ assume root.
- **nameConfig** written **before** `code` launch (attach defaults); terminal user still depends on create `-u`, not nameConfig alone. Detail: [cli-runtime-boundary — Connection user](conventions/cli-runtime-boundary.md#connection-user-remoteuser--containeruser). Archive: [`specs/changes/archive/20260811-align-remote-user-resolution/`](../specs/changes/archive/20260811-align-remote-user-resolution/).

## Ports and lifecycle

- `forwardPorts` → publish ports on the Apple container (IDE auto-forward not guaranteed).
- `portsAttributes` stored/surfaced as metadata where useful.
- Lifecycle hooks: in-container via `container exec` except host `initializeCommand`. Each hook admits **string** | **argv** | **object map** `name → string|argv` (empty `{}` no-op); map entries run **in parallel** (stage succeeds only if every entry exits 0). `waitFor` default `updateContentCommand`. `userEnvProbe` / `shutdownAction` admitted (`stopCompose` fail-closed; explicit `stop` always stops). Detail: [cli-runtime-boundary — Lifecycle](conventions/cli-runtime-boundary.md#lifecycle-execution-hook-matrix). Contract: [`specs/lifecycle-hooks.md`](../specs/lifecycle-hooks.md) + active [`align-official-lifecycle`](../specs/changes/align-official-lifecycle/). Matrix:

  | Path | Hooks |
  |------|--------|
  | Fresh create (`up` bind, `clone` volume, or `rebuild` replacement) | host `initializeCommand` (host path when present; volume/clone-origin `rebuild` with no host workspace still runs from a temp root with the live guest `.devcontainer/` and root `.devcontainer.json` if that is the config; temp removed after the hook; `./scripts/…` not required) → `onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`; `waitFor` default `updateContentCommand` (Ready/open/postAttach after named stage); delete container if any create-path hook fails (`up`/`clone` may enter [bring-up recovery](#bring-up-recovery); `rebuild` hard post-delete may enter rebuild recovery) |
  | Reuse running (`up` only when config hash matches) | host `initializeCommand` when host workspace exists; no create-path hooks; settings+extensions apply on marker drift (**not** `--vscode`-gated); CLI-attach postAttach (feature hooks mergeable from image metadata) |
  | Config hash mismatch (`up`) | fail `config_hash_mismatch` — no delete or replacement; use `rebuild` |
  | Bind start-stopped (`up`, hash match) | host `initializeCommand` → `postStartCommand` + feature remelt; then settings+extensions apply if pending (**not** `--vscode`-gated); CLI-attach postAttach; postStart failure fails `up` but does **not** delete |
  | Bare `start` | **Real start:** host `initializeCommand` (skip+warn if no host path) → `postStartCommand` + feature remelt → CLI-attach postAttach. **Already-running:** no initialize/postStart; postAttach only after successful `--vscode` open. **Never applies** settings/extensions. Config from labels for postAttach only; feature hooks from image metadata |
  | `customizations.vscode` | **CLI apply** (config-file v1): settings+extensions after create-path hooks on `up`/`clone`/`rebuild` and on `up` reuse / `up` start-stopped drift (**not** gated on `--vscode` or open); **not** on `start`; soft-fail; marker idempotency — see [VS Code flow](#vs-code-flow) |
  | `postAttachCommand` | **CLI attach** on `up`/`clone`/`rebuild`/real `start` after waitFor (not `--vscode`-gated; open success/soft-fail MUST NOT skip). Already-running `start`: **RUNS** only after successful `--vscode` open; **SKIP** (+ status when any present) if flag absent or open soft-fails. Order on apply-commands: apply → open → postAttach (postAttach still runs if open soft-fails). Non-zero → fail command, **keep** container. Soft-fail apply ≠ postAttach fail-keep. Contract: [`specs/vscode.md`](../specs/vscode.md) + active [`align-official-lifecycle`](../specs/changes/align-official-lifecycle/) + active [`vscode-customizations-up-clone-rebuild`](../specs/changes/vscode-customizations-up-clone-rebuild/); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../specs/changes/archive/20260808-vscode-customizations-apply/) |

- **runArgs allowlist** and **hostRequirements** enforce+apply: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md). Contract: [`specs/runargs-host.md`](../specs/runargs-host.md).
- Long-lived devcontainers use keep-alive entrypoint **`/bin/sleep` infinity** so the container stays up for `exec`/attach.

## Features

Shipped under `Sources/ADevContainerLib/Features/`. On `up`/`clone`/`rebuild` when `features` is non-empty (after clone git-ensure; volume-mode rebuild: OCI only):

1. Admit **OCI** and **local path** refs; **warn-skip** docker-* markers (omit from admitted list) and warn-strip metadata `privileged` / `securityOpt` (not applied).
2. One-time consent for `build.rosetta=false` when needed (CI: `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1`).
3. Load local packages or fetch OCI over HTTPS (embedded client).
4. Order via `dependsOn` / `installsAfter`; build derived image via `container build --platform linux/arm64` — metadata `containerEnv` as Dockerfile **`ENV` before** install `RUN` (`$PATH`/`$VAR` expand); `install.sh` runs **as root** after `chmod -R 0755` with options + `_REMOTE_USER`/`_CONTAINER_USER` on RUN prefix (base USER when local config has no remote/container user); Dockerfile then **restores base image USER**; derived LABEL unions base-image + feature lifecycle; `recipeVersion` **`"6"`**. Reuse tag when unchanged. If BuildKit was stopped before the build, restore-after-build stops it again (best-effort); already-running / undetermined status → leave alone.
5. Create from derived image; merge contributions (runtime env **config wins**, `${PATH}` expansion on create and later exec). Create `-u`: explicit `containerUser`, else non-root connection user, else omit when root.

**Clone-only:** if no admitted feature id is `git` or `common-utils`, inject `ghcr.io/devcontainers/features/git:1` (Features path, not apt) so populate can run **in-container full `git clone`** and in-container git works. `up` does not inject. Host git is required only for config-only sparse/shallow fetch and HTTPS `git credential fill`.

Full runner steps, reject list, and progress lines: [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md).

## VS Code flow

**Product (implemented):** after successful lifecycle on `up`, `start`, `clone`, or `rebuild`, optional **`--vscode`** best-effort opens VS Code on the host. **`--vscode` gates open only** — not settings/extensions apply, not postAttach (except already-running `start`). Without the flag, no open; CLI-attach postAttach still runs on `up`/`clone`/`rebuild`/real start. Manual attach (same URI recipe) remains valid and is **not** an apply trigger. **Apple `apple-container+` attach does not auto-install** config `customizations.vscode` — the CLI applies them on `up`/`clone`/`rebuild` (below).

**Behavior (`--vscode`):**
- Runs only after lifecycle success (create/start/reuse path completed).
- Invokes: `code --new-window --folder-uri "vscode-remote://apple-container+${HEX}${FOLDER}"`.
- **Order on `up`/`clone`/`rebuild` with `--vscode`:** settings+extensions apply if pending (soft-fail; **not** flag-gated) → Ready/open after waitFor → **config** then **feature** `postAttachCommand` (CLI attach; fail-keep; open soft-fail does **not** skip). Apply is a dedicated step (`VSCodeCustomizationsApply`), not folded into postAttach.
- **`start`:** never apply. Real start: postStart then CLI-attach postAttach (not flag-gated). Already-running: open → postAttach on open success only.
- **Soft-fail open:** missing `code` on PATH or launch failure → stderr warn; open alone does not fail the command. On `up`/`clone`/`rebuild`/real start, postAttach still runs. On already-running `start`, must **not** run postAttach. On `up`/`clone`/`rebuild`, apply may already have run; marker MAY finalize even when open soft-fails or `--vscode` is absent.
- **postAttach (shipped):** CLI is the supporting tool. **RUNS** on `up`/`clone`/`rebuild`/real start after waitFor. Already-running `start`: skip (one status line when any present) if flag absent or open soft-fails. postAttach non-zero → fail command, **keep** container. Approximation only — no wait for VS Code Server / IDE-confirmed attach; manual UI attach does not trigger postAttach or apply.
- **Config source:**
  - `up` / `clone` / `rebuild`: in-memory resolved (or stamped) config for apply; on **reuse/restart**, merge feature postAttach from image `devcontainer.metadata` (Features not re-run); vscode customizations from resolved/loadable config.
  - bare `start`: load from labels **for postAttach only** — bind: host paths `local_folder` + `config_file`; volume: cat stamped config in-container; then merge feature postAttach from image metadata. Load failure → treat postAttach absent (start success preserved). Load MUST NOT drive settings/extensions apply.
- **Folder:** resolved `remoteWorkspaceFolder` / label `devcontainer.workspace_folder`; when config omits `workspaceFolder`, default is `/workspaces/<basename>`.

### customizations.vscode (CLI apply, shipped)

v1: **config-file only** (not feature-contributed / image `devcontainer.metadata` merge; not Features Dockerfile / image build). Outside create identity hash — edits apply in-place via marker drift.

| Piece | When | Detail |
|-------|------|--------|
| **settings** | After create-path hooks on fresh `up`/`clone`/`rebuild`; repair on `up` reuse / `up` start-stopped when marker drifts | Merge into `~/.vscode-server/data/Machine/settings.json` under effective remote user. **Not** gated on `--vscode` or open success. **Not** on `start`. Empirically validated (e.g. `editor.tabSize`, `files.insertFinalNewline`) |
| **extensions** | On `up`/`clone`/`rebuild` (fresh, `up` reuse, `up` start-stopped) after hooks / after postStart as applicable — **before** optional open | Marketplace VSIX (guest `targetPlatform`) → tar-pipe (`copyTreeIntoContainer`) into guest `/tmp` → unzip under `~/.vscode-server/extensions` (not base64-in-argv). **Install complete only after** upsert into Server registry `~/.vscode-server/extensions/extensions.json` (folder-only → UI shows 0 installed). Registry `metadata.pinned`: **false** for bare `publisher.name` (autoupdate on); **true** only for `publisher.name@version`. Best-effort delete `…/CachedProfilesData/__default__profile__/extensions.user.cache` when registry dirty. BFS `package.json` **`extensionDependencies` ∪ `extensionPack`** (shared cycle guard; soft-fail per ID; e.g. Swift → `llvm-vs-code-extensions.lldb-dap`). Seed path: no extension host / activation / `runtimeDependencies` downloads (.NET SDK etc. = image prereq, not seed). Marketplace VSIX targets **guest** `targetPlatform` (`linux`/`alpine` × `arm64`/`x64` from guest `uname -m` + os-release; `?targetPlatform=` only on platform-specific assets — universal omits, else 404; unknown arch soft-fails — no host VSIX). Gallery contrast + csdevkit pack+dep example: [gaps — CLI extension seed](domain/devcontainer-apple-gaps.md#cli-extension-seed-vs-full-marketplace-install). **Not** gated on `--vscode` or open success. **Not** on `start`. Skip on matching marker. Manual UI attach is not an apply trigger. Install-before-open usually enough; Reload Window residual MAY |
| **Idempotency** | Guest marker `$HOME/.adevcontainer/vscode-customizations.applied` | Content hash of normalized (sorted) **config-file** extension IDs + canonical settings JSON only — transitive deps are side effects, not hash inputs. Match → skip; drift → re-apply on `up`/`clone`/`rebuild`. Full hash written only after full payload success (`--vscode`/open not required). Settings-only or extensions-only success MUST NOT finalize. `start` never writes or updates the marker |
| **Soft-fail** | All apply I/O/network/exec | Warn stderr; never fail lifecycle exit; never delete/stop solely due to apply. **≠** postAttach fail-keep |

Malformed nested `extensions`/`settings` types soft-skip apply with warn (do not fail whole-config resolve when `customizations.vscode` is an object). Other `customizations.*` namespaces remain non-applied metadata. **Apple attach does not auto-install** — CLI apply does.

**Prereqs (host):** VS Code + extension `ms-vscode-remote.remote-containers`.

**Inputs from a running managed container** (name = id on Apple container): container id/name, image ref, remote workspace folder (as above).

**Remote authority:** scheme `apple-container` with hex-encoded UTF-8 compact JSON authority payload `{"id":"<containerId>","image":"<imageRef>"}` — no spaces. Full folder URI:

```text
vscode-remote://apple-container+<hex(json)><remoteWorkspaceFolder>
```

**Open recipe (host or CLI):**

```bash
code --new-window --folder-uri "vscode-remote://apple-container+${HEX}${FOLDER}"
```

- Prefer `code --new-window --folder-uri …` so the folder is in the window. `open vscode://…` may **reuse** an existing window.
- Extension UI command `remote-containers.attachToAppleContainer` opens the **remote authority only** (no folder) → empty/no-folder window UX gap; the `--folder-uri` recipe avoids that.
- **nameConfig** (attach defaults): write `~/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/<containerName>.json` with `workspaceFolder` + `remoteUser` (from non-empty connection-user resolution / stamp) **before** launching `code`. Apple attach **ignores** nameConfig `remoteUser` for the integrated terminal (uses container default user) — create `-u` compensation covers that; nameConfig still written for other attach defaults. Folder path in the URI alone does not set remote user.

Not full Dev Containers up/rebuild or IDE-owned customizations parity; volume-mode is product `clone`, not the extension’s clone-in-volume. Contract: [`specs/vscode.md`](../specs/vscode.md) + active [`align-official-lifecycle`](../specs/changes/align-official-lifecycle/) + active [`vscode-customizations-up-clone-rebuild`](../specs/changes/vscode-customizations-up-clone-rebuild/); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../specs/changes/archive/20260808-vscode-customizations-apply/). Gaps: [devcontainer-apple-gaps.md](domain/devcontainer-apple-gaps.md).

## Reference config

- **Workspace self-devcontainer:** `.devcontainer/devcontainer.json` — `swift:6.3.3-noble` plus OCI Features (`opencode`, `agents-workspace`) for Linux Swift tooling + product fixture; not full macOS product build/test. Detail: [workspace-devcontainer.md](conventions/workspace-devcontainer.md).
- **Team sample (warn-skip surface):** `reference/devcontainer.json` — features (incl. docker-ood), privileged+tun `runArgs`, mounts, `postCreateCommand`, `forwardPorts`, VS Code customizations. Docker-oriented bits warn-skip; Compose/unknown still fail-closed; see [0003](decisions/0003-warn-skip-apple-incompatibles.md) and [gaps](domain/devcontainer-apple-gaps.md).
- **Language / multi-feature sample:** `references/multiplatform` — `base:ubuntu` + OCI Features `dotnet:2` + `node:1` (install-time feature `containerEnv` path; no privileged/DinD surface).


## Out of scope (product shape)

- Not a fork of https://github.com/devcontainers/cli
- No Docker Compose driver
- No docker-outside-of-docker / docker-in-docker / docker-from-docker / privileged / tun device **emulation** (warn-skip optional bits; do not implement DinD/device paths)
