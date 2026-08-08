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
| List + label filter | `docker ps --filter label=…` | **No label filter on list** — client-side filter after JSON; prefer deterministic name + inspect |
| VS Code | Dev Containers full up/rebuild | **Attach-only** after CLI `up` (experimental Attach to Running Apple Container) |
| Default process | Often long-running or sleep entry | Keep-alive `--entrypoint /bin/sleep` + `infinity` for long-lived devcontainers |
| Create identity | Name vs id often distinct | `create --name` **is** the id (`configuration.id`) |
| Bind mounts | File or directory host source OK | **Directory sources only** — file binds rejected by runtime |
| Env PATH | Shell/`${PATH}` often expanded | Apple `container` does **not** expand `${PATH}` — product expands on **create and exec** (`expandEnvPathRefs`); exec-only miss breaks lifecycle (`sh -lc` needs `/bin` on PATH) |

### File bind mounts

Apple `container` rejects bind mounts whose host source is a **file** (source must be a directory). File-path binds in `devcontainer.json` (e.g. `~/.kube/config`) must be promoted to the parent directory on both host and container sides before create. Product behavior: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md) (`MountNormalizer`).

The mounts-ports fixture uses a `~/.kube` **directory** bind; `reference/devcontainer.json` may still declare a file path and relies on auto-promotion.

### list/inspect JSON (tested shape: 1.2.x)

Useful machine-JSON paths documented against Apple container **1.2.x**: `configuration.id`, `status.state`, `configuration.labels`. Full parse rules: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

### Features build (Rosetta / platform)

Apple BuildKit with `build.rosetta=true` can require Rosetta even for native arm64 image builds. Product ensures `build.rosetta=false` (one-time consent) and passes `--platform linux/arm64` on Features pull/build/create. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).

## Config surface implications

- **Hard errors** for unsupported props/flags — never silent ignore.
- **`forwardPorts`**: map to publish ports; do not promise IDE auto-forward behavior.
- **`portsAttributes`**: metadata only; no IDE auto-forward.
- **Lifecycle**: run via `container exec` (hook matrix: create-path full order; start-stopped `postStart` only; reuse none; `postAttach` admit + skip on `up`). Exec must expand `containerEnv` PATH refs (same as create) or login-shell hooks fail (`id`/`bash` not found). Not Docker entrypoint injection parity. Detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
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
- `customizations.vscode` — editor-side; CLI does not replace VS Code extension install

## Identity workaround

Because list-by-label may be weak/missing, the CLI owns **deterministic container names** (`adev-{base}-{hash12}`, human base from config `name` or workspace basename) plus labels (`devcontainer.local_folder`, `devcontainer.config_file`, config hash) and resolves via name/inspect rather than Docker-style filter queries. Naming detail: [cli-runtime-boundary.md](../conventions/cli-runtime-boundary.md).
