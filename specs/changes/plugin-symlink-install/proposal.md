# Proposal: Symlink plugin install

## Intent

Copying the Mach-O into Apple’s install-root cannot be done by Homebrew: `brew` does not run as root, its sandbox cannot write `/usr/local/libexec`, and a later `cp` or `chmod` through a plugin symlink would mutate the keg. This change replaces `install-plugin`’s copy with an absolute symlink installed by `plugin --install` and removed by `plugin --uninstall`.

## Scope

- Change id: **`plugin-symlink-install`**.
- Affected live contract: [plugin.md](../../plugin.md) **Dual install as Apple CLI plugin `dev`** and **Explicit plugin restage after Apple upgrade wipe**; [core.md](../../core.md) **Doctor preflight** as already modified by the active [install-plugin-command](../install-plugin-command/spec.md) delta.
- This change supersedes the overlapping requirements in that still-active delta (copy the Mach-O; `install-plugin`; Homebrew `post_install` restages `/usr/local`). Do not edit or archive `specs/changes/install-plugin-command/` in this change. Where both active deltas speak, this change is the contract.
- In-scope outcomes: `plugin --install` / `plugin --uninstall`; symlink target rules; elevation and doctor remediation; lifecycle still does not restage; Homebrew formula renderer, README, and CONTRIBUTING name the new command and stop writing Apple’s install-root.
- Formula name stays `adevcontainer`. Plugin binary name stays `dev`. SPM product stays `adevcontainer`.

## Non-goals

- Product-code, test, or docs implementation while writing these artifacts.
- Editing or archiving `specs/changes/install-plugin-command/`.
- Wiki edits. `wiki/architecture.md` and `wiki/conventions/release-distribution.md` still describe copy-based `install-plugin` and Homebrew `post_install` restage; that descriptive text conflicts with this confirmed contract and is left stale on purpose.
- Pushing the external tap `wcgomes/homebrew-tap`. The in-repo renderer is the formula content to change; the release workflow publishes it later.
- `design.md`. The decisions below stay understandable without an alternatives write-up.
- Auto-restage on `up` or any other lifecycle command.
- Waiting on unmerged home-dir plugin discovery ([apple/container#1618](https://github.com/apple/container/pull/1618)).
- ContainerAPIClient / XPC migration, or shipping under Apple’s bundled `libexec/container/plugins/`.
- Renaming the formula, the plugin binary, or the SPM product.

## Approach

Remove `install-plugin` with no alias. Add `plugin` that requires exactly one of `--install` or `--uninstall`. `--install` writes `config.toml` as a regular file and makes `bin/dev` an absolute symlink to the Homebrew opt path or, outside Homebrew, to the running executable path without realpath. `--uninstall` removes only those two layout entries. Homebrew `post_install` stops writing Apple’s install-root; caveats tell the user to run `sudo adevcontainer plugin --install` once after install and again only after upgrading Apple `container`.

## Decision index

- **Command is `plugin`, not `install-plugin`:** `plugin --install` and `plugin --uninstall` are the only restage verbs. `install-plugin` is removed and is not an alias. Neither flag, or both flags, is a usage error. Exactly one flag is required.
- **Install is an absolute symlink, not a copy:** `--install` removes `bin/dev` when it is a regular file (old copy) or a symlink to the wrong target, then creates an absolute symlink. An already-correct absolute symlink is left in place. `config.toml` is always written as a regular file (`abstract`, no `[servicesConfig]`), never by writing through a symlink. `--install` MUST NOT copy the Mach-O into the plugin layout or chmod the symlink target.
- **Homebrew target is the opt path:** When the running executable is Homebrew formula `adevcontainer`, including a versioned Cellar path and including `sudo` with a bare argv0, the symlink target MUST be `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`. It MUST NOT be a Cellar path and MUST NOT be `resolvingSymlinksInPath` of the keg. If that opt path cannot be formed, fail rather than fall back to Cellar or realpath.
- **Non-Homebrew target is the running executable path:** No realpath resolution. Under `sudo`, a bare argv0 MUST NOT be treated as a relative source path (same rule as today’s `install-plugin`).
- **Plugin invocation must not self-link `bin/dev`:** When argv0 or the identified path is `{install-root}/libexec/container-plugins/dev/bin/dev` (absolute path or process name `dev`), `--install` MUST NOT target that plugin path. An existing absolute link text is reused (Cellar link becomes the opt path; an opt link is kept; do not realpath the keg). A regular file, relative symlink, or self-symlink falls back to PATH `adevcontainer` or the Homebrew opt binary. If neither can be identified, fail instead of creating a self-symlink. PATH `adevcontainer plugin --install` is unchanged.
- **Uninstall removes layout entries only:** `--uninstall` removes `bin/dev` (symlink or leftover copy) and `config.toml` only. It MUST NOT delete the symlink target or the Homebrew keg. A missing layout is success.
- **Elevation and doctor stay PATH-only where the plugin cannot be assumed:** When the destination is not writable, re-exec with elevated privileges or print exact remediation naming PATH `adevcontainer plugin --install` or `adevcontainer plugin --uninstall` with `sudo`. Doctor missing-plugin remediation uses PATH `adevcontainer plugin --install`, never `container dev plugin --install`. Lifecycle commands do not restage. `--repair` remains a usage error whose hint names `plugin --install`.
- **Homebrew does not restage Apple’s install-root:** `post_install` MUST NOT write `/usr/local/libexec/...` (or any Apple install-root plugin path). A `cp` or `chmod` through the new symlink would mutate the keg, and brew cannot write there. Caveats MUST tell the user to run `sudo adevcontainer plugin --install` once after install, and again only after upgrading Apple `container` ([apple/container#1617](https://github.com/apple/container/issues/1617)). `brew upgrade adevcontainer` MUST NOT require restage when the symlink already targets the opt path.
- **Preserved restage limits:** `plugin --install` and `plugin --uninstall` MUST NOT require `container system start`. The product MUST NOT wait on home-dir plugin discovery.
- **No `design.md`:** Target selection, elevation, and the Homebrew sandbox constraint stay understandable in this index and in `tasks.md`. The overflow rule is not met.
