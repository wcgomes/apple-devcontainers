# Devcontainer vs Apple container gaps

Facts that constrain the CLI. Not a full Apple container manual — only gaps that change product behavior.

## Runtime model

| Area | Typical Docker/devcontainers | Apple container (this product) |
|------|------------------------------|--------------------------------|
| Driver | Docker/Moby engine API | Apple `container` CLI subprocess |
| Compose | Docker Compose common | **Unsupported** — hard reject |
| Privileged | `--privileged` widely used | **Warn-skip** — not applied ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)) |
| Devices | `--device=…` (e.g. `/dev/net/tun`) | **Warn-skip** — not applied ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)) |
| Features | OCI + local path feature packages + image build | **Supported** (OCI + local path runner); **warn-skip** `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` and privileged/securityOpt metadata ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)); native arm64 build (no Rosetta by default) |
| Events / rich watch APIs | Engine events often used by tools | Do not assume Docker-equivalent event stream |
| List + label filter | `docker ps --filter label=…` | **No label filter on list** — client-side filter after JSON; prefer deterministic name + inspect; product `list` keeps `devcontainer.managed=adevcontainer` only |
| VS Code | Dev Containers full up/rebuild + clone-in-volume + IDE-owned customizations apply | **Attach** after CLI bring-up (Apple Container support in Remote - Containers). Product `--vscode` on `up`/`start`/`clone`/`rebuild` best-effort opens via `code --folder-uri` (soft-fail). **Apple attach does not auto-install** `customizations.vscode` — CLI applies config-file settings/extensions (see below). Manual attach without flag still valid. Not full Dev Containers parity. Volume-mode via product `clone` (not extension clone-in-volume) |
| Forced rebuild | Managed-container rebuild workflow | `up` fails on config hash mismatch (`config_hash_mismatch`); use `rebuild` (managed `--name`/picker). Detail: [cli-runtime-boundary](../conventions/cli-runtime-boundary.md#up-reuse-vs-rebuild-forced-rebuild) |
| Default process | Often long-running or sleep entry | Keep-alive `--entrypoint /bin/sleep` + `infinity` for long-lived devcontainers |
| Create identity | Name vs id often distinct; official CLI uses labels + a random Docker name | `create --name` **is** the id (`configuration.id`) and a DNS hostname — sanitized `name` ≤63, no `adev-`/hash. `${devcontainerId}` / `*-ws` / Features tags use workspace/repo basename + hash, never config `name`. Occupancy on collision. See [Identity workaround](#identity-workaround) |
| Bind mounts | File or directory host source OK | **Directory sources only** — file binds rejected by runtime |
| Workspace I/O | Often bind or named volume | **Bind:** host APFS via virtiofs. **Named volume:** `volume.img` ext4 via virtio-blk — better metadata I/O; rationale for `clone` volume-mode |
| Named volume ownership | Engine/user mapping varies; often usable by non-root | Apple named volumes mount **root:root**. Non-root connection users get **EACCES** writing home-dir volumes (e.g. config mounts) and creating siblings under root-owned intermediate parents during postCreate/postStart. Product fixes via `WorkspaceOwnership` — named-volume targets chown; bind-mode create paths (`up` fresh create, `rebuild`) also run a **parents-only** rootfs fix-up (mkdir -p + non-recursive ancestor chown up to the break list; bind target never chowned; no-op for root/unset; `up` reuse/start-stopped and bare `start` excluded) — see [Named volume ownership](#named-volume-ownership-rootroot) |
| Host→guest copy | `docker cp` into bind or volume | **`container cp` into a named-volume mount can exit 0 without writing files** (silent no-op). Rootfs paths may still accept `cp`. Product clone populate avoids host→guest copy entirely (in-container `git clone`); tar-pipe utility remains if ever needed — see below |
| Env PATH | Shell/`${PATH}` often expanded | Apple `container` does **not** expand `${PATH}` — product expands on **create and exec** (`expandEnvPathRefs`); exec-only miss breaks lifecycle (`sh -lc` needs `/bin` on PATH) |
| Image USER / remoteUser | Docker inspect `Config.User`; metadata often on image labels | Apple image inspect: **`variants[].config.config.User`** (not top-level `Config`). Labels may carry `devcontainer.metadata` with `remoteUser`/`containerUser`. Official `mcr.microsoft.com/devcontainers/base:*` typically **OCI USER root** + metadata **`remoteUser: vscode`**. **Apple attach** ignores nameConfig `remoteUser` and uses container default user (no exec `-u`) — product create `-u` = explicit `containerUser`, else non-root connection user, else omit when root. Chain + stamp: [cli-runtime-boundary — Connection user](../conventions/cli-runtime-boundary.md#connection-user-remoteuser--containeruser). **Inspect failure ≠ root**; never hardcode `vscode`/`node` |

### Bind vs volume workspace

| | Bind (`up`) | Volume (`clone`) |
|--|-------------|------------------|
| Storage | Host directory (virtiofs → APFS) | Named volume `adev-*-ws` (virtio-blk → ext4 in `volume.img`) |
| Identity hash | workspace path + config path | normalized git URL + config relpath |
| `local_folder` label | real host path | `volume://…` |
| Start hooks | real start: host `initializeCommand` (if host path) + `postStart` + feature remelt + CLI-attach postAttach | same; volume start without host path skips initialize + warns |
| Auth for git | N/A (host tree already present) | **SSH:** `SSH_AUTH_SOCK` + `create --ssh`. **HTTPS:** host `git credential fill` one-shot → guest `credential.helper store`. No GCM-in-guest; no host `~/.git-credentials` mount; no PAT CLI primary UX |
| Populate | N/A (host tree) | **In-container full `git clone`** + verify `.git` (host = config-only sparse/shallow only; no host full+tar happy path) |

Detail: [architecture.md](../architecture.md), [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md). Contract: [`specs/clone.md`](../../specs/clone.md) (volume vs bind); union of [`specs/<domain>.md`](../../specs/).

### Real-runtime validation constraints

- Volume-mode clone population runs inside the container. A host-only `file://` URL is not reachable from an Apple container; real-runtime fixtures need a container-reachable endpoint, such as a host `git daemon` over `git://`. This is a runtime reachability constraint, not a product clone failure. Rebuild recovery E2E shares this family: when guest DNS / host `file://` cannot populate via live `CloneCommand`, fixtures bootstrap clone-origin labels and volumes instead.
- Recovery E2E gate: `ADEVCONTAINER_RECOVERY_E2E=1` (non-TTY) / `ADEVCONTAINER_RECOVERY_E2E_TTY=1` (TTY). Default suite skips. Rebuild non-TTY live exists when gated. Automated TTY recovery E2E is absent (TTY env only surfaces skip guidance). Bring-up gated case `recoveryE2E_bringUpCommands_gated` still skip-cascades and then always skips — it does not execute live bring-up commands.
- Feature material for rebuild/recovery git inject on live rebuild must use a durable host path (e.g. `~/Library/Caches`). Apple `container build` effectively drops or breaks contexts under `/var/folders` temp.
- `--skip-pull` suppresses adevcontainer's explicit image-pull step only. Apple `container` may still auto-fetch a missing image during `create`, so the flag does not guarantee fail-if-absent or runtime-level no-fetch behavior.

### Named volume ownership (root:root)

Apple named volumes present as **root:root** at the mount target. Without a product fix, a non-root connection user cannot write the volume (classic symptom: EACCES on home-dir `type=volume` mounts such as opencode-config) and cannot `mkdir` siblings under intermediate parents that `mkdir -p` created as root (e.g. `/home/vscode/.local` blocks `devcontainer-features` next to a volume target under `.local/share/…`).

**Product:** after start, before create-path hooks, `WorkspaceOwnership` chowns `type=volume` mount targets to the connection user (non-root). Workspace named-volume path (`adev-*-ws`) remains a separate call (`ensureWorkspaceWritableByRemoteUser`); config mounts use the same helper (`ensureNamedVolumeMountsWritableByRemoteUser`). **Never** chown bind mounts on the host; **skip** readonly volume mounts. Intermediate parents get **non-recursive** chown; walk stops before system tops (`/`, `/home`, `/Users`, `/var`, …) so nested home paths become writable for siblings without chowning `/home`. Failure: hard-fail + delete on `up`/`clone`; soft-fail warn on `rebuild`. **Bind-mode create paths** (`up` fresh create; `rebuild` both modes) additionally run a **parents-only** fix-up (`ensureWorkspaceParentsWritableByRemoteUser`, `parentsOnly` scope): one root exec `mkdir -p`s the container-rootfs workspace folder path and non-recursively chowns its ancestors up to the same break list — no `chown -R`, and the workspace folder itself (the host bind target) is **never** chowned — so hooks (non-root connection user) can create sibling dirs under root-owned parents like `/workspaces` in bind mode. No-op for root/unset connection user; excluded from `up` reuse/start-stopped and bare `start`. Volume-mode `clone` already delivers the parent outcome via the existing workspace-chown parent walk — no second mechanism. Parents-only failure: hard-fail + delete + [bring-up recovery](#bring-up-recovery-up--clone--start) eligible on `up`; soft-fail warn on `rebuild`; `clone` unchanged. Detail: [cli-runtime-boundary — Named volumes / ownership](../conventions/cli-runtime-boundary.md#named-volumes-ensure--reuse--ownership). Contract: [`workspace-parents-writable`](../../specs/changes/workspace-parents-writable/spec.md).

### File bind mounts

Apple `container` rejects bind mounts whose host source is a **file** (source must be a directory). File-path binds in `devcontainer.json` (e.g. `~/.kube/config`) must be promoted to the parent directory on both host and container sides before create. Product behavior: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md) (`MountNormalizer`).

The mounts-ports fixture uses a `~/.kube` **directory** bind; `reference/devcontainer.json` may still declare a file path and relies on auto-promotion.

### `container cp` vs named volume mounts

`container cp` host→guest targeting a path on a **named volume mount** can exit **0** and still write nothing (silent no-op). Rootfs destinations may still work with `cp`.

**Product implication:** volume-mode clone populate does **not** host→guest copy into the workspace volume. Happy path is **in-container full `git clone`** (after Features ensure git) + verify `.git`. Runtime may still expose tar-pipe `copyTreeIntoContainer` as a utility (not the clone happy path). Do not use `container cp` into named-volume mounts. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Failed rebuild recovery (mode-split)

Rebuild recovery is **mode-split**. Shared rules: same hard post-delete trigger matrix and TTY/non-TTY branching; pre-delete config/host/Features failures and postAttach/settings/open failures never enter recovery.

**Shared hard post-delete matrix:** replacement `create` failure, replacement `start` failure, or create-path hook failure. Excluded (terminal, no recovery): volume ensure, pre-delete config/host/Features, `postAttachCommand`, customizations apply, final verification, and other non-retryable errors. Retryable hard failures are runtime, lifecycle, and post-create only.

**TTY / non-TTY (both modes):** After hard post-delete on TTY: structured error, then `Open the recovery editor now? [Y/n]` (default **Y**). Decline/EOF retains helper/session or BindRecoveryResume and prints retry guidance (no editor). Named `rebuild` retry skips the prompt and opens the editor before apply/write. Non-TTY/JSON unchanged: structured retained details, no editor/prompt; named retry applies retained temp. TTY loops on invalid config once the editor is open. Progress must show "entering recovery" so create-path/postCreate failure is not mistaken for a hang. TTY editor launch uses **InteractiveProcessRunner** `tcsetpgrp` + `SIGCONT` (inherit-stdio alone → `nano`/`vi` `STAT=T` hang). Detail: [cli-runtime-boundary](../conventions/cli-runtime-boundary.md).

#### Clone-origin volume path

Eligible only for a managed clone-origin container with complete volume-mode stamps: non-empty normalized git URL, existing workspace volume, config path contained by stamped workspace folder, managed identity. Incomplete/malformed/unknown identity fail closed.

- Helper: immutable digest-pinned Alpine `linux/arm64`; digest/platform inspection + exact existing workspace-volume presence preflighted before the old-container delete gate. Never deletes/replaces/repopulates/rolls back an image.
- Apple mount identity is nested: `configuration.mounts[].type.volume.name` (logical name); do not use `source` (may be `volume.img`). Require stamped volume at stamped folder, read-write. Malformed/unknown/read-only/wrong-target/bind/virtiofs fail closed.
- After failed replacement: detach failed container and verify absence from all attachments before helper create; failed detach blocks recovery.
- Host session: raw config private (`0700`/`0600`); edits via helper stdin → atomic same-directory write guarded by baseline hash → readback byte/hash verify. Conflicts/failed verify retain state. Raw config never in labels, JSON errors, or logs. Spec private-file = host-session only.
- After atomic `mv`, in-volume stamped config must be `remoteUser`-readable (product `chmod 644`). Host session stays `0700`/`0600`.
- `RecoveryConfigSession.cleanup` fail-closed bar: path/ownership/session-id only — not on-disk metadata equality after `applyValidatedEdit` advances `lastAppliedHash`.
- Helper/session retained for retry; crossing helper delete gate detaches/replaces helper before another edit. Cleanup only after successful final verification.
- **Named apply after volume auto-start** (order: volume auto-start → apply/write). Helper must be **exec-ready** before exec (probe → `start` → stop+start bounce); status alone insufficient (`cannot exec: container is not running` while listed running).
- No `container cp`, volume delete/replace/repopulate, or image rollback (named-volume `cp` limitation still applies independently).

#### Bind / `up` path

Host stamped `devcontainer.json` editor UX only — **no** Alpine helper, **no** helper volume attach, **no** atomic in-volume write. Operator edits the host-side stamped config; recovery does not route through the volume helper pipeline.

- Bind named retry after non-TTY may use host-side **BindRecoveryResume** stamps (not container labels) when the container is already gone — labels are unavailable once the failed container is deleted.

Contract + README/CLI help landed (archive `20260810-rebuild`). Rebuild remaining gaps only: automated TTY E2E absent; non-TTY live rebuild recovery E2E gated `ADEVCONTAINER_RECOVERY_E2E=1`. Bring-up recovery is a separate path — see [below](#bring-up-recovery-up--clone--start).

### Bring-up recovery (`up` / `clone` / `start`)

Not rebuild-only. Shared primitive `BringUpRecovery`. Rebuild post-delete recovery ([above](#failed-rebuild-recovery-mode-split)) is unchanged. Contract: [`specs/clone.md`](../../specs/clone.md) + [`specs/managed-lifecycle.md`](../../specs/managed-lifecycle.md); archive [`20260814-bring-up-recovery`](../../specs/changes/archive/20260814-bring-up-recovery/).

**Offer** when bring-up fails and an editable `devcontainer.json` exists. Triggers: config parse/resolve on an existing file, create, start, workspace-ownership, clone populate, create-path hooks. **No recovery:** config not found; clone git fetch fails before any config exists. postAttach/settings/open still never enter recovery.

**TTY / non-TTY:** TTY without `--json`: structured error, then `Open the recovery editor now? [Y/n]` (default **Y**). Affirmative → editor + retry from scratch. Decline/EOF → original error. Non-TTY/`--json` never prompt or open an editor; fail with the original error plus an edit/retry hint.

| Command | Recovery |
|---------|----------|
| `up` | Edit the host config (bind resolve). Retry re-resolves from the host and re-runs the create path. Deletes leftover containers including after a later retry or `name` change. No helper, no retained checkout. |
| `clone` | Retain a product-managed config-only checkout (`~/Library/Application Support/adevcontainer/clone-recovery`, marker `.adevcontainer-retained-checkout`). TTY edits the retained config and retries without re-fetch. Non-TTY prints exact `clone --resume <config-dir>`. Resume/remove: managed root + marker only; never delete an external path. Successful TTY retry/`--resume` overlays the edited `devcontainer.json` into the guest workspace **after populate** (replaces the git-populated original). Overlay is clone-recovery only; none when there is no editable config. Rebuild helper write-back is unchanged. |
| `start` | Delegates to `rebuild --name` (ports/labels are baked at create). Does **not** re-run start, open an editor, or write config. |

Same E2E gate as rebuild. Do not treat the bring-up gated case as live command execution — `recoveryE2E_bringUpCommands_gated` is still a skip stub.

### list/inspect JSON (tested shape: 1.2.x)

**Container** machine-JSON (list/inspect) against Apple container **1.2.x**: `configuration.id`, `status.state`, `configuration.labels`.

**Image** inspect (USER / metadata for connection user + Features base USER): `variants[].config.config.User`; labels may include `devcontainer.metadata` JSON. Do not assume Docker’s top-level `Config.User`. Full parse rules: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Features build (Rosetta / platform / USER)

Apple BuildKit with `build.rosetta=true` can require Rosetta even for native arm64 image builds. Product ensures `build.rosetta=false` (one-time consent) and passes `--platform linux/arm64` on Features pull/build/create. Feature install runs **as root** then Dockerfile **restores base OCI USER**; derived LABEL unions base-image + feature lifecycle (`recipeVersion` **`"7"`**); install env uses base USER when config remote/container user empty. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Features install `containerEnv`

**Shipped** (`recipeVersion` **`"7"`**): `FeatureDockerfileGenerator` emits feature metadata `containerEnv` as Dockerfile **`ENV` before** each feature’s install `RUN` (Dockerfile expands `$PATH`/`$VAR` — single-quoted RUN-prefix `PATH` wiped system PATH, e.g. dotnet). Feature **options** and user contract keys (`_REMOTE_USER` / `_CONTAINER_USER`) stay on the install **`RUN` env prefix**.

| Piece | Fact |
|-------|------|
| Install | Metadata `containerEnv` → Dockerfile `ENV` before `./install.sh` (e.g. dotnet `DOTNET_ROOT`, `PATH=…:$PATH`) |
| RUN prefix | Options + `_REMOTE_USER` / `_CONTAINER_USER` only (base USER when config remote/container user empty) |
| Precedence | `ENV` then RUN prefix; options/user overwrite on key collision for that install layer |
| Runtime | Create/exec merge unchanged: feature contributions then **config wins** |
| Example | `references/multiplatform` — `base:ubuntu` + `dotnet:2` + `node:1` (no pre-built language image required solely for install env) |

Detail: [cli-runtime-boundary — Features runner](../conventions/cli-runtime-boundary.md#features-runner).

### VS Code attach (`--vscode` + manual)

After lifecycle success, `up` / `start` / `clone` / `rebuild` accept **`--vscode`**: best-effort host `code --new-window --folder-uri …`. Missing `code` or launch fail → stderr warn; open alone does not fail the command. **`--vscode` = open only** — not settings/extensions apply, not postAttach (except already-running `start`). Without the flag, no open; CLI-attach postAttach still runs on `up`/`clone`/`rebuild`/real start. Same URI recipe works manually (manual attach is **not** an apply trigger). On `up`/`clone`/`rebuild` with `--vscode`: **apply → open**; postAttach is CLI attach after waitFor (open soft-fail does not skip). On `start`: never apply; real start CLI-attach postAttach; already-running postAttach only after successful open. Full recipe + apply policy: [architecture.md — VS Code flow](../architecture.md#vs-code-flow). Contract: [`specs/vscode.md`](../../specs/vscode.md) + active [`vscode-customizations-up-clone-rebuild`](../../specs/changes/vscode-customizations-up-clone-rebuild/); archive [`20260814-align-official-lifecycle`](../../specs/changes/archive/20260814-align-official-lifecycle/); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../../specs/changes/archive/20260808-vscode-customizations-apply/).

| Piece | Fact |
|-------|------|
| Flag | `--vscode` on `up`, `start`, `clone`, `rebuild` (post-success only; **open** gate; open soft-fail; **not** an apply or CLI-attach postAttach gate — already-running `start` is the exception) |
| Prereq | VS Code + `ms-vscode-remote.remote-containers` |
| Authority | `apple-container+` + hex(UTF-8 compact JSON `{"id","image"}`) — id = create `--name` |
| Open | `code --new-window --folder-uri "vscode-remote://apple-container+${HEX}${FOLDER}"` |
| Folder | `remoteWorkspaceFolder` from labels/resolve; default if config omits `workspaceFolder`: `/workspaces/<basename>` |
| Apple attach spike | `apple-container+` attach does **not** install `customizations.vscode.extensions` (e.g. `swiftlang.swift-vscode`) — product must apply via CLI |
| customizations.vscode | **CLI applies** config-file only (v1; not feature/metadata merge; not image build). Helper: `VSCodeCustomizationsApply` |
| settings | Merge into `~/.vscode-server/data/Machine/settings.json` under effective remote user — **create-path** after hooks on fresh `up`/`clone`/`rebuild`; repair on `up` reuse / `up` start-stopped marker drift. **Not** gated on `--vscode`. **Not** on `start`. Validated: Machine settings take effect (e.g. tabSize / insertFinalNewline) |
| extensions | On `up`/`clone`/`rebuild` (fresh, `up` reuse, `up` start-stopped) **before** optional open; **not** gated on `--vscode` or open success; **not** on `start`. Marketplace VSIX for **guest** `targetPlatform` (linux/alpine × arm64/x64) → tar-pipe → guest unzip under `~/.vscode-server/extensions` (not base64-in-argv). **Registry required:** upsert `extensions.json` — folder unpack alone leaves UI at 0 installed. `metadata.pinned`: **false** bare IDs; **true** only `publisher.name@version`. Cache invalidate: best-effort rm `extensions.user.cache`. BFS **`extensionDependencies` ∪ `extensionPack`** (shared cycle guard; soft-fail per ID; e.g. Swift → `lldb-dap`). Unknown guest arch soft-fails (no host VSIX). Manual UI attach is not an apply trigger. Install-before-open usually enough; Reload Window residual MAY |
| Order with `--vscode` | `up`/`clone`/`rebuild`: apply (soft-fail) → open → CLI-attach postAttach (fail-keep; open soft-fail does not skip). `start`: never apply; real start CLI-attach postAttach; already-running: open → postAttach on open success only. Apply is **not** delivered via `postAttachCommand` |
| Soft-fail apply | Warn stderr; never fail lifecycle exit; never delete/stop container solely due to apply. **≠** postAttach fail-keep |
| Idempotency | Guest marker `$HOME/.adevcontainer/vscode-customizations.applied` = hash of normalized **config** extensions+settings only (transitive deps side effects); skip on match; re-apply on drift on `up`/`clone`/`rebuild`; full hash only after full payload success (`--vscode`/open not required; settings-only or extensions-only MUST NOT finalize; `start` never writes) |
| Identity | `customizations` stay out of create identity / config hash |
| postAttach | **CLI attach** on `up`/`clone`/`rebuild`/real start after waitFor (not `--vscode`-gated; open soft-fail does not skip). Already-running `start`: **RUNS** only after successful `--vscode` open; **SKIP** if no flag or open soft-fails (status when any present). Fail-keep; not IDE-confirmed ready |
| postAttach sources | `start`: config from labels for postAttach only (bind host paths / volume in-container cat) — **not** for apply; reuse/`start`: feature hooks from image `devcontainer.metadata` |
| nameConfigs | Write `…/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/<containerName>.json` (`workspaceFolder` + `remoteUser`) **before** `code` launch; `remoteUser` from non-empty connection-user resolution. Apple attach **ignores** nameConfig `remoteUser` for terminal user (container default) — create `-u` compensation |
| UI gap | `remote-containers.attachToAppleContainer` attaches authority **without** folder → empty window; folder-uri avoids it |
| `open vscode://` | May reuse window; prefer `code --new-window --folder-uri` |
| Parity | Not full Dev Containers up/rebuild / IDE-owned apply; manual attach without `--vscode` still valid |

#### CLI extension seed vs full marketplace install

CLI apply is a **seed** (download VSIX, unpack, registry upsert) — not full gallery/extension-host install. Shipped BFS: **`extensionDependencies` ∪ `extensionPack`**.

| Aspect | Full VS Code gallery / extension host | CLI seed (shipped) |
|--------|----------------------------------------|---------------------|
| Transitive graph | **`extensionPack`** (member failures soft) **and** **`extensionDependencies`** (hard) | BFS **pack ∪ deps** from each VSIX `package.json`; shared cycle guard; **soft-fail per ID** (both edges). Marker hash = **config-file IDs + settings only** (transitive side effects not hash inputs) |
| Activation / runtime | Runs extension host; can download **`runtimeDependencies`** and other activation-time assets | **No** extension host, activation, or `runtimeDependencies` downloads. Heavy runtimes (e.g. **.NET SDK**) are **image prereqs**, not seed artifacts |
| Platform VSIX | Target = **guest/remote** OS/arch | **Shipped:** guest `uname -m` + `/etc/os-release` → marketplace `targetPlatform` (`linux-arm64` / `linux-x64` / `alpine-arm64` / `alpine-x64`); `?targetPlatform=` only on platform-specific assets (universal omits — 404 with query); version pick prefers matching platform then universal; **unknown guest arch soft-fails** (refuse host-platform VSIX) |
| Example (not a product special-case) | `ms-dotnettools.csdevkit`: pack → `ms-dotnettools.csharp`; hard dep → `ms-dotnettools.vscode-dotnet-runtime` | Listing only `csdevkit` seeds that ID + pack members + deps from its `package.json` (csharp + vscode-dotnet-runtime); still **no** EH/activation/`runtimeDependencies`; .NET SDK stays image prereq |

## Config surface implications

- **Hard errors** for unknown-dangerous props/flags and Compose — never silent ignore. Known optional Apple-incompatibles **warn-skip**.
- **`forwardPorts`**: map to publish ports; do not promise IDE auto-forward behavior.
- **`portsAttributes`**: metadata only; no IDE auto-forward.
- **Lifecycle**: in-container via `container exec` except host `initializeCommand` (up/clone/real start when host workspace exists; volume/clone-origin `rebuild` with no host workspace still runs — not skip; volume start without host path skips+warns). Hook matrix: create-path full order on `up`/`clone`/`rebuild`; real start (bind+volume) `postStart` + feature remelt; already-running start no postStart; reuse none for create-path; **postAttach** = CLI attach on `up`/`clone`/`rebuild`/real start (not `--vscode`-gated); already-running start postAttach only after successful `--vscode` open; fail-keep; `start` loads config from labels for postAttach only; feature postAttach from image metadata on reuse/`start`. Forms: string | argv | named object map (**parallel**; stage succeeds only if every entry exits 0). `waitFor` default `updateContentCommand`. `userEnvProbe` / `shutdownAction` admitted (`stopCompose` fail-closed; explicit stop always stops). Exec must expand `containerEnv` PATH refs (same as create) or login-shell hooks fail (`id`/`bash` not found). Not Docker entrypoint injection parity. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
- **`runArgs`**: allowlist (`--init`, `--cap-add`/`--cap-drop`, …); privileged/tun/device/security family **warn-skip**; unknown and first-class smuggling flags fail closed.
- **`hostRequirements`**: preflight — fail on memory/cpus shortfall; map requested limits to create `-m`/`-c` when host OK; warn unsupported `gpu`; fail on unparseable/unknown keys.
- **Features**: OCI + local path fetch/load + derived image build on `up` (see [cli-runtime-boundary](../conventions/cli-runtime-boundary.md)); **warn-skip** `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` and privileged/securityOpt metadata ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)). Install as root, restore base USER; derived LABEL unions base-image + feature lifecycle; `recipeVersion` `"7"`. Metadata `containerEnv` → Dockerfile `ENV` before install RUN; options + user keys on RUN prefix — [Features install containerEnv](#features-install-containerenv). Runtime create/exec still config-wins.
- **Connection user**: local `remoteUser` → local `containerUser` → image metadata last non-empty remote/container user → OCI USER → root (chain unchanged). **Create `-u`:** explicit `containerUser` if set; else non-root connection user; else omit when root — Apple attach ignores nameConfig `remoteUser` / uses container default. Successful create always stamps non-empty `devcontainer.remote_user` (incl. `root`; empty = legacy only). Archive: [`specs/changes/archive/20260811-align-remote-user-resolution/`](../../specs/changes/archive/20260811-align-remote-user-resolution/).

## Reference config hotspots

`reference/devcontainer.json` exercises several gaps at once:

- Features block (ood, node, third-party) — ood warn-skipped; other OCI/local features run via Features runner
- `runArgs` privileged + `NET_ADMIN` + tun device — privileged/tun warn-skipped; `NET_ADMIN` allowlisted (extra warning that caps alone ≠ device/VPN on Apple container)
- Bind + named volume mounts — supported
- `postCreateCommand` — supported
- Large `forwardPorts` / `portsAttributes` — publish + metadata
- `customizations.vscode` — **CLI applies** settings+extensions by default on `up`/`clone`/`rebuild` (not `--vscode`-gated; not on `start`); Apple attach does not auto-install — see VS Code attach table above

## Identity workaround

Apple `create --name` **is** the container id and a DNS hostname — official Dev Containers CLI can use labels + a random Docker name; this product cannot. Config `name` is create-name / DNS only: DNS-safe sanitized `name` (else workspace/repo basename), ≤63, no `adev-` prefix and no identity hash. Empty sanitize fails (no invented `adev-{hash12}`). Example: `"name": "My App"` in folder `foo` → DNS `my-app`.

`${devcontainerId}` is the **resource stem** `adev-{base}-{hash12}` (empty base → `adev-{hash12}`). Base = workspace/repo basename, **never** config `name`. Same hash material as `*-ws`. Example: folder `foo` → stem `adev-foo-{hash12}`. Token-expanded volumes (e.g. `${devcontainerId}-shellhistory`) are stem-keyed; rebuild rename keeps them.

Human base (~20 clip of workspace/repo basename, **never** config `name`) names the stem and hashed sidecars: Features `adev-{base}:{hash12}` / `adevcontainer:{hash12}`, volume-mode `{stem}-ws`. Workspace identity stays on managed labels (bind: `local_folder`+`config_file`; volume: `git_url`+config path) because friendly names can collide. Occupancy: `up`/`clone` leftover different-name (incl. old `adev-*`) → delete-hint; foreign occupant → TTY Y/n + new name (persist into `name`; no recovery editor or suffix picker). `rebuild` applies the live computed create name (user `name` change and old `adev-*` migrate); reuse stem-keyed `*-ws` and `${devcontainerId}` volumes and the same Features tag (human base unchanged); foreign occupant of the new name: do not delete selected; TTY Y/n + new name. `start`: idle containers are not renamed. Discovery: `--name`/picker + client-side managed filter (only `up` uses `-w`). Labels otherwise unchanged (`devcontainer.managed`, config hash, `workspace_mode`, `workspace_folder`, non-empty `remote_user` on new creates; volume-mode also `workspace_volume`, `config_volumes`). Naming + occupancy: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
