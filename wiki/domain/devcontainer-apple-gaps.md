# Devcontainer vs Apple container gaps

Facts that constrain the CLI. Not a full Apple container manual — only gaps that change product behavior.

## Runtime model

| Area | Typical Docker/devcontainers | Apple container (this product) |
|------|------------------------------|--------------------------------|
| Driver | Docker/Moby engine API | Apple `container` CLI subprocess |
| Compose | Docker Compose common | **Unsupported** — hard reject |
| Privileged | `--privileged` widely used | **Rejected** ([0002](../decisions/0002-reject-docker-ood-privileged-tun.md)) |
| Devices | `--device=…` (e.g. `/dev/net/tun`) | **Rejected** ([0002](../decisions/0002-reject-docker-ood-privileged-tun.md)) |
| Features | OCI + local path feature packages + image build | **Supported** (OCI + local path runner); forever-reject `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker`; native arm64 build (no Rosetta by default) |
| Events / rich watch APIs | Engine events often used by tools | Do not assume Docker-equivalent event stream |
| List + label filter | `docker ps --filter label=…` | **No label filter on list** — client-side filter after JSON; prefer deterministic name + inspect; product `list` keeps `devcontainer.managed=adevcontainer` only |
| VS Code | Dev Containers full up/rebuild + clone-in-volume + IDE-owned customizations apply | **Attach** after CLI bring-up (experimental Apple Container support in Remote - Containers). Product `--vscode` on `up`/`start`/`clone` best-effort opens via `code --folder-uri` (soft-fail). **Apple attach does not auto-install** `customizations.vscode` — CLI applies config-file settings/extensions (see below). Manual attach without flag still valid. Not full Dev Containers parity. Volume-mode via product `clone` (not extension clone-in-volume) |
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

Detail: [architecture.md](../architecture.md), [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md). Contract: [`specs/adevcontainer/spec.md`](../../specs/adevcontainer/spec.md).

### File bind mounts

Apple `container` rejects bind mounts whose host source is a **file** (source must be a directory). File-path binds in `devcontainer.json` (e.g. `~/.kube/config`) must be promoted to the parent directory on both host and container sides before create. Product behavior: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md) (`MountNormalizer`).

The mounts-ports fixture uses a `~/.kube` **directory** bind; `reference/devcontainer.json` may still declare a file path and relies on auto-promotion.

### `container cp` vs named volume mounts

`container cp` host→guest targeting a path on a **named volume mount** can exit **0** and still write nothing (silent no-op). Rootfs destinations may still work with `cp`.

**Product implication:** volume-mode clone populate does **not** host→guest copy into the workspace volume. Happy path is **in-container full `git clone`** (after Features ensure git) + verify `.git`. Runtime may still expose tar-pipe `copyTreeIntoContainer` as a utility (not the clone happy path). Do not use `container cp` into named-volume mounts. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### list/inspect JSON (tested shape: 1.2.x)

Useful machine-JSON paths documented against Apple container **1.2.x**: `configuration.id`, `status.state`, `configuration.labels`. Full parse rules: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Features build (Rosetta / platform)

Apple BuildKit with `build.rosetta=true` can require Rosetta even for native arm64 image builds. Product ensures `build.rosetta=false` (one-time consent) and passes `--platform linux/arm64` on Features pull/build/create. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### VS Code attach (`--vscode` + manual)

After lifecycle success, `up` / `start` / `clone` accept **`--vscode`**: best-effort host `code --new-window --folder-uri …`. Missing `code` or launch fail → stderr warn; open alone does not fail the command. Without the flag, same URI recipe works manually (does not run postAttach or CLI extension install). Successful open gates **extensions apply** then **`postAttachCommand`** (CLI attach approximation). Full recipe + apply policy: [architecture.md — VS Code flow](../architecture.md#vs-code-flow). Contract: [`specs/adevcontainer/spec.md`](../../specs/adevcontainer/spec.md); open archive: [`specs/changes/archive/20260808-vscode-open-flag/`](../../specs/changes/archive/20260808-vscode-open-flag/); apply archive: [`specs/changes/archive/20260808-vscode-customizations-apply/`](../../specs/changes/archive/20260808-vscode-customizations-apply/).

| Piece | Fact |
|-------|------|
| Flag | `--vscode` on `up`, `start`, `clone` (post-success only; open soft-fail) |
| Prereq | VS Code + `ms-vscode-remote.remote-containers`; `dev.containers.experimentalAppleContainerSupport: true` |
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

- **Hard errors** for unsupported props/flags — never silent ignore.
- **`forwardPorts`**: map to publish ports; do not promise IDE auto-forward behavior.
- **`portsAttributes`**: metadata only; no IDE auto-forward.
- **Lifecycle**: run via `container exec` (hook matrix: create-path full order on `up`/`clone`; bind start-stopped `postStart` only; bare `start` no create-path/postStart; reuse none for create-path; **postAttach implemented** — runs after successful `--vscode` open only, skip otherwise, fail-keep; `start` loads config from labels; feature postAttach from image metadata on reuse/`start`). Exec must expand `containerEnv` PATH refs (same as create) or login-shell hooks fail (`id`/`bash` not found). Not Docker entrypoint injection parity. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
- **`runArgs`**: allowlist (`--init`, `--cap-add`/`--cap-drop`, …); privileged/tun/device and unknown flags fail closed.
- **`hostRequirements`**: preflight — fail on memory/cpus shortfall; map requested limits to create `-m`/`-c` when host OK; warn unsupported `gpu`; fail on unparseable/unknown keys.
- **Features**: OCI + local path fetch/load + derived image build on `up` (see [cli-runtime-boundary](../conventions/cli-runtime-boundary.md)); forever-reject `docker-outside-of-docker`, `docker-in-docker`, `docker-from-docker` and privileged/securityOpt metadata ([0002](../decisions/0002-reject-docker-ood-privileged-tun.md)).

## Reference config hotspots

`reference/devcontainer.json` exercises several gaps at once:

- Features block (ood, node, third-party) — ood forever-rejected; other OCI/local features run via Features runner
- `runArgs` privileged + `NET_ADMIN` + tun device — rejected
- Bind + named volume mounts — supported
- `postCreateCommand` — supported
- Large `forwardPorts` / `portsAttributes` — publish + metadata
- `customizations.vscode` — **CLI applies** (settings create-path; extensions after successful `--vscode` open); Apple attach does not auto-install — see VS Code attach table above

## Identity workaround

Because list-by-label may be weak/missing, the CLI owns **deterministic container names** (`adev-{base}-{hash12}`, human base from config `name` or workspace basename) plus managed labels (`devcontainer.managed`, `local_folder`, `config_file`, config hash, `workspace_mode` = `bind`|`volume`, `workspace_folder`, `remote_user`; volume-mode also `git_url`, `workspace_volume`, `config_volumes`) and resolves via `--name`/picker + client-side managed filter (only `up` uses `-w`). Volume identity keys off git URL + config relpath so reclones stay stable. Naming detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
