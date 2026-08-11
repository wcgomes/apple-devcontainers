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
| Force-recreate | Often `up --recreate` / Dev Containers rebuild UX | **No `up --recreate`.** `up` fails on config hash mismatch (`config_hash_mismatch`); sole force-recreate is `rebuild` (managed `--name`/picker). Detail: [cli-runtime-boundary](../conventions/cli-runtime-boundary.md#up-reuse-vs-rebuild-force-recreate) |
| Default process | Often long-running or sleep entry | Keep-alive `--entrypoint /bin/sleep` + `infinity` for long-lived devcontainers |
| Create identity | Name vs id often distinct | `create --name` **is** the id (`configuration.id`) |
| Bind mounts | File or directory host source OK | **Directory sources only** — file binds rejected by runtime |
| Workspace I/O | Often bind or named volume | **Bind:** host APFS via virtiofs. **Named volume:** `volume.img` ext4 via virtio-blk — better metadata I/O; rationale for `clone` volume-mode |
| Host→guest copy | `docker cp` into bind or volume | **`container cp` into a named-volume mount can exit 0 without writing files** (silent no-op). Rootfs paths may still accept `cp`. Product clone populate avoids host→guest copy entirely (in-container `git clone`); tar-pipe utility remains if ever needed — see below |
| Env PATH | Shell/`${PATH}` often expanded | Apple `container` does **not** expand `${PATH}` — product expands on **create and exec** (`expandEnvPathRefs`); exec-only miss breaks lifecycle (`sh -lc` needs `/bin` on PATH) |

### Bind vs volume workspace

| | Bind (`up`) | Volume (`clone`) |
|--|-------------|------------------|
| Storage | Host directory (virtiofs → APFS) | Named volume `adev-*-ws` (virtio-blk → ext4 in `volume.img`) |
| Identity hash | workspace path + config path | normalized git URL + config relpath |
| `local_folder` label | real host path | `volume://…` |
| Start hooks | bind start-stopped: `postStart` only | volume-mode `start`: **no hooks** |
| Auth for git | N/A (host tree already present) | **SSH:** `SSH_AUTH_SOCK` + `create --ssh`. **HTTPS:** host `git credential fill` one-shot → guest `credential.helper store`. No GCM-in-guest; no host `~/.git-credentials` mount; no PAT CLI primary UX |
| Populate | N/A (host tree) | **In-container full `git clone`** + verify `.git` (host = config-only sparse/shallow only; no host full+tar happy path) |

Detail: [architecture.md](../architecture.md), [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md). Contract: [`specs/clone.md`](../../specs/clone.md) (volume vs bind); union of [`specs/<domain>.md`](../../specs/).

### Real-runtime validation constraints

- Volume-mode clone population runs inside the container. A host-only `file://` URL is not reachable from an Apple container; real-runtime fixtures need a container-reachable endpoint, such as a host `git daemon` over `git://`. This is a runtime reachability constraint, not a product clone failure. Live recovery E2E shares this family: when guest DNS / host `file://` cannot populate via live `CloneCommand`, fixtures bootstrap clone-origin labels and volumes instead.
- Live non-TTY recovery E2E is opt-in via `ADEVCONTAINER_RECOVERY_E2E=1` (default suite skips). TTY editor path is manual-only; `ADEVCONTAINER_RECOVERY_E2E_TTY=1` only surfaces skip guidance.
- Feature material for rebuild/recovery git inject on live rebuild must use a durable host path (e.g. `~/Library/Caches`). Apple `container build` effectively drops or breaks contexts under `/var/folders` temp.
- `--skip-pull` suppresses adevcontainer's explicit image-pull step only. Apple `container` may still auto-fetch a missing image during `create`, so the flag does not guarantee fail-if-absent or runtime-level no-fetch behavior.

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

- Helper: immutable digest-pinned Alpine `linux/arm64`; digest/platform inspection + exact existing workspace-volume presence preflighted before the old-container delete gate. Never deletes/recreates/repopulates/rolls back an image.
- Apple mount identity is nested: `configuration.mounts[].type.volume.name` (logical name); do not use `source` (may be `volume.img`). Require stamped volume at stamped folder, read-write. Malformed/unknown/read-only/wrong-target/bind/virtiofs fail closed.
- After failed replacement: detach failed container and verify absence from all attachments before helper create; failed detach blocks recovery.
- Host session: raw config private (`0700`/`0600`); edits via helper stdin → atomic same-directory write guarded by baseline hash → readback byte/hash verify. Conflicts/failed verify retain state. Raw config never in labels, JSON errors, or logs. Spec private-file = host-session only.
- After atomic `mv`, in-volume stamped config must be `remoteUser`-readable (product `chmod 644`). Host session stays `0700`/`0600`.
- `RecoveryConfigSession.cleanup` fail-closed bar: path/ownership/session-id only — not on-disk metadata equality after `applyValidatedEdit` advances `lastAppliedHash`.
- Helper/session retained for retry; crossing helper delete gate detaches/replaces helper before another edit. Cleanup only after successful final verification.
- **Named apply after volume auto-start** (order: volume auto-start → apply/write). Helper must be **exec-ready** before exec (probe → `start` → stop+start bounce); status alone insufficient (`cannot exec: container is not running` while listed running).
- No `container cp`, volume delete/recreate/repopulate, or image rollback (named-volume `cp` limitation still applies independently).

#### Bind / `up` path

Host stamped `devcontainer.json` editor UX only — **no** Alpine helper, **no** helper volume attach, **no** atomic in-volume write. Operator edits the host-side stamped config; recovery does not route through the volume helper pipeline.

- Bind named retry after non-TTY may use host-side **BindRecoveryResume** stamps (not container labels) when the container is already gone — labels are unavailable once the failed container is deleted.

Contract + README/CLI help landed (archive `20260810-rebuild`). Remaining gaps only: automated TTY E2E absent; non-TTY live recovery E2E gated `ADEVCONTAINER_RECOVERY_E2E=1`.

### list/inspect JSON (tested shape: 1.2.x)

Useful machine-JSON paths documented against Apple container **1.2.x**: `configuration.id`, `status.state`, `configuration.labels`. Full parse rules: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Features build (Rosetta / platform)

Apple BuildKit with `build.rosetta=true` can require Rosetta even for native arm64 image builds. Product ensures `build.rosetta=false` (one-time consent) and passes `--platform linux/arm64` on Features pull/build/create. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### VS Code attach (`--vscode` + manual)

After lifecycle success, `up` / `start` / `clone` / `rebuild` accept **`--vscode`**: best-effort host `code --new-window --folder-uri …`. Missing `code` or launch fail → stderr warn; open alone does not fail the command. Without the flag, same URI recipe works manually (does not run postAttach or CLI extension install). Successful open gates **extensions apply** then **`postAttachCommand`** (CLI attach approximation). Full recipe + apply policy: [architecture.md — VS Code flow](../architecture.md#vs-code-flow). Contract: [`specs/vscode.md`](../../specs/vscode.md); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../../specs/changes/archive/20260808-vscode-customizations-apply/).

| Piece | Fact |
|-------|------|
| Flag | `--vscode` on `up`, `start`, `clone`, `rebuild` (post-success only; open soft-fail) |
| Prereq | VS Code + `ms-vscode-remote.remote-containers` |
| Authority | `apple-container+` + hex(UTF-8 compact JSON `{"id","image"}`) — id = create `--name` |
| Open | `code --new-window --folder-uri "vscode-remote://apple-container+${HEX}${FOLDER}"` |
| Folder | `remoteWorkspaceFolder` from labels/resolve; default if config omits `workspaceFolder`: `/workspaces/<basename>` |
| Apple attach spike | `apple-container+` attach does **not** install `customizations.vscode.extensions` (e.g. `swiftlang.swift-vscode`) — product must apply via CLI |
| customizations.vscode | **CLI applies** config-file only (v1; not feature/metadata merge; not image build). Helper: `VSCodeCustomizationsApply` |
| settings | Merge into `~/.vscode-server/data/Machine/settings.json` under effective remote user — **create-path** after hooks on fresh `up`/`clone`; repair on `start`/reuse marker drift. **Not** gated on `--vscode`. Validated: Machine settings take effect (e.g. tabSize / insertFinalNewline) |
| extensions | After **successful** `--vscode` open only; host VSIX → tar-pipe → guest unzip under `~/.vscode-server/extensions` (not base64-in-argv). **Registry required:** upsert `extensions.json` — folder unpack alone leaves UI at 0 installed. Cache invalidate: best-effort rm `extensions.user.cache`. BFS `extensionDependencies` (cycle guard; soft-fail per ID; e.g. Swift pulls `lldb-dap`). Skip if no flag or open soft-fails; manual UI attach without flag does not install. Reload Window may be needed once |
| Order after open | extensions apply (soft-fail) → postAttach (fail-keep). Apply is **not** delivered via `postAttachCommand` |
| Soft-fail apply | Warn stderr; never fail lifecycle exit; never delete/stop container solely due to apply. **≠** postAttach fail-keep |
| Idempotency | Guest marker `$HOME/.adevcontainer/vscode-customizations.applied` = hash of normalized **config** extensions+settings only (transitive deps side effects); skip on match; re-apply on drift; full hash only after full payload success (settings-only leaves extensions pending) |
| Identity | `customizations` stay out of create identity / config hash |
| postAttach | **Implemented:** **RUNS** config then feature postAttach only after successful `--vscode` open; **SKIP** if no flag or open soft-fails (status when any present); fail-keep; not IDE-confirmed ready |
| postAttach sources | `start`: config from labels (bind host paths / volume in-container cat); reuse/`start`: feature hooks from image `devcontainer.metadata` |
| nameConfigs (optional) | `…/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/<containerName>.json` → `workspaceFolder` + `remoteUser` |
| UI gap | `remote-containers.attachToAppleContainer` attaches authority **without** folder → empty window; folder-uri avoids it |
| `open vscode://` | May reuse window; prefer `code --new-window --folder-uri` |
| Parity | Not full Dev Containers up/rebuild / IDE-owned apply; manual attach without `--vscode` still valid |

## Config surface implications

- **Hard errors** for unknown-dangerous props/flags and Compose — never silent ignore. Known optional Apple-incompatibles **warn-skip**.
- **`forwardPorts`**: map to publish ports; do not promise IDE auto-forward behavior.
- **`portsAttributes`**: metadata only; no IDE auto-forward.
- **Lifecycle**: run via `container exec` (hook matrix: create-path full order on `up`/`clone`; bind start-stopped `postStart` only; bare `start` no create-path/postStart; reuse none for create-path; **postAttach implemented** — runs after successful `--vscode` open only, skip otherwise, fail-keep; `start` loads config from labels; feature postAttach from image metadata on reuse/`start`). Exec must expand `containerEnv` PATH refs (same as create) or login-shell hooks fail (`id`/`bash` not found). Not Docker entrypoint injection parity. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
- **`runArgs`**: allowlist (`--init`, `--cap-add`/`--cap-drop`, …); privileged/tun/device/security family **warn-skip**; unknown and first-class smuggling flags fail closed.
- **`hostRequirements`**: preflight — fail on memory/cpus shortfall; map requested limits to create `-m`/`-c` when host OK; warn unsupported `gpu`; fail on unparseable/unknown keys.
- **Features**: OCI + local path fetch/load + derived image build on `up` (see [cli-runtime-boundary](../conventions/cli-runtime-boundary.md)); **warn-skip** `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` and privileged/securityOpt metadata ([0003](../decisions/0003-warn-skip-apple-incompatibles.md)).

## Reference config hotspots

`reference/devcontainer.json` exercises several gaps at once:

- Features block (ood, node, third-party) — ood warn-skipped; other OCI/local features run via Features runner
- `runArgs` privileged + `NET_ADMIN` + tun device — privileged/tun warn-skipped; `NET_ADMIN` allowlisted (extra warning that caps alone ≠ device/VPN on Apple container)
- Bind + named volume mounts — supported
- `postCreateCommand` — supported
- Large `forwardPorts` / `portsAttributes` — publish + metadata
- `customizations.vscode` — **CLI applies** (settings create-path; extensions after successful `--vscode` open); Apple attach does not auto-install — see VS Code attach table above

## Identity workaround

Because list-by-label may be weak/missing, the CLI owns **deterministic container names** (`adev-{base}-{hash12}`, human base from config `name` or workspace basename) plus managed labels (`devcontainer.managed`, `local_folder`, `config_file`, config hash, `workspace_mode` = `bind`|`volume`, `workspace_folder`, `remote_user`; volume-mode also `git_url`, `workspace_volume`, `config_volumes`) and resolves via `--name`/picker + client-side managed filter (only `up` uses `-w`). Volume identity keys off git URL + config relpath so reclones stay stable. Naming detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
