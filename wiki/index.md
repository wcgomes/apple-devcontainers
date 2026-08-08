# Wiki index

macOS Swift CLI (`adevcontainer`): read `devcontainer.json`, drive Apple `container`. Greenfield (not a @devcontainers/cli fork). Host: macOS 26+ Apple Silicon. Runtime dep: install Apple `container` separately.

## Architecture

- [architecture.md](architecture.md) — pipeline, package layout, commands (`up` bind-mode only uses `-w`; `clone` volume-mode + auto Features `git:1` when no git/common-utils, in-container full git clone populate, SSH `--ssh` / HTTPS host credential fill + guest store; `list`/`start`/`exec`/`stop`/`delete`/`prune`/`inspect` via `--name`/picker not `-w`; `up` bind stamps managed labels incl. `workspace_mode=bind`; `delete` vs `prune`), bind vs named-volume workspace, identity (path vs git URL), lifecycle matrix, progress stderr, runArgs allowlist, hostRequirements, Features (OCI + local path); binary `adevcontainer`; repo `apple-devcontainers`; host macOS 26+; tests `swift run adevcontainerTests`
- Contract: [`specs/adevcontainer/spec.md`](../specs/adevcontainer/spec.md) (realized; includes archived `20260808-clone-in-volume`)

## Decisions (ADRs)

- [decisions/index.md](decisions/index.md) — ADR routing map
- [0001](decisions/0001-greenfield-swift-cli.md) — greenfield Swift / Apple container
- [0002](decisions/0002-reject-docker-ood-privileged-tun.md) — reject docker-* / privileged / device / Compose / blind runArgs

## Domain

- [devcontainer-apple-gaps.md](domain/devcontainer-apple-gaps.md) — Apple container vs Docker/devcontainers gaps; bind (virtiofs/APFS) vs named volume (virtio-blk/ext4) I/O; `container cp` silent no-op on named-volume mounts (clone populate = in-container git clone, not cp/tar happy path); SSH `--ssh` / HTTPS host credential fill + guest store (no GCM-in-guest); file binds rejected (dir only); list/inspect JSON; keep-alive `/bin/sleep`; create --name = id; Compose/privileged/devices; VS Code attach + clone-in-volume analogue; Features OCI + local path

## Conventions

- [cli-runtime-boundary.md](conventions/cli-runtime-boundary.md) — AppleContainerRuntime; Features runner (OCI + local path; derived `container build --platform`; build.rosetta consent; BuildKit restore-after-build; docker-* forever-reject; PATH `${PATH}`/`$PATH` expand on create **and** exec); MountNormalizer file→dir bind; named volume ensure; workspace volume `adev-*-ws`; clone flow (host sparse config-only → identity prompt → ensure Features `git:1` if no git/common-utils → volume create; SSH inject `--ssh` when agent; HTTPS host `git credential fill` one-shot + guest `credential.helper store`; in-container full `git clone` + verify `.git`; no GCM-in-guest; no host full+tar happy path; `up` no inject); **selection:** only `up` uses `-w`; `start`/`exec`/`stop`/`delete`/`prune`/`inspect` use `--name`/picker; managed labels both modes (`workspace_mode=bind` on `up`, `=volume` on `clone`); `list`; `prune` resource set (+ ws volumes); progress/`==>` tee; machine JSON; ProcessRunner pipe drain; interactive exec vs pipes; lifecycle matrix (volume-mode start: no hooks; bind start-stopped: postStart only via `up`) + create-path delete-on-fail (clone also drops `*-ws`); runArgs allowlist; hostRequirements; names/labels (volume human-base = git URL repo basename)
- [release-distribution.md](conventions/release-distribution.md) — release, distribution, maintainer process (`main` ≠ release; ship only via `git tag vX.Y.Z` / dispatch; non-prerelease auto Homebrew bump via `HOMEBREW_TAP_TOKEN` + `scripts/render-homebrew-formula.sh`), GitHub repo `wcgomes/apple-devcontainers` (ex-`apple-dev-containers`, ex-`dev-containerization`, 301s), GitHub Actions (ci.yml / release.yml), macos-26 arm64, version inject (`Version.swift`, tag source of truth), tarball + sha256, Homebrew sole SoT `wcgomes/homebrew-tap` `Formula/adevcontainer.rb` (`brew install adevcontainer`; no in-repo `packaging/homebrew` mirror), prereleases skip brew, missing token fails non-prerelease, curl/tar fallback, COPYFILE_DISABLE, notarize deferred, branch protection on main
- [workspace-devcontainer.md](conventions/workspace-devcontainer.md) — repo `.devcontainer` (`swift:6.3.3-noble` + OCI Features node:1 lts, opencode, agents-workspace); `postCreateCommand` install-tools.sh (codegraph npm global + agent wiring/init) then `swift package resolve`; node needed for npm/codegraph (opencode Features lack node); Linux tooling + fixture; not macOS product build; no runArgs/SYS_PTRACE; swift-vscode extension only (no vscode.settings); no privileged/docker-* Features; research rejects (container-machine-vscode, MCR swift image, seccomp unconfined)
