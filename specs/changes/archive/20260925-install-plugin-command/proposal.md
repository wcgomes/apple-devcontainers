# Proposal: Plugin restage aligned to symlink install

## Intent

`doctor --repair` mixed host preflight with plugin restage. This change originally replaced that flag with `install-plugin` and a Mach-O copy. Before archive, those overlapping requirements are corrected to the symlink contract: `plugin --install` and `plugin --uninstall`, an absolute symlink, and no Homebrew write to Apple’s install-root.

## Scope

- Change id: **`install-plugin-command`**.
- Affected domains: [plugin.md](../../../plugin.md) **Explicit plugin restage after Apple upgrade wipe**; [core.md](../../../core.md) **Doctor preflight**.
- Authoritative contract: [plugin-symlink-install](../20260925-plugin-symlink-install/spec.md). This corrected delta matches that contract and does not add requirements.
- Restage is `plugin --install` / `plugin --uninstall`. The plugin binary is an absolute symlink, not a copy. Homebrew target is `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`. Uninstall removes layout entries only. Formula `post_install` does not write `/usr/local`. Doctor hints PATH `adevcontainer plugin --install`. There is no `install-plugin` command and no `doctor --repair` restage.

## Non-goals

- Requirements that are not in the symlink change.
- Auto-restage on `up` or any other lifecycle command.
- Wiki edits.
- Waiting on unmerged home-dir plugin discovery ([apple/container#1618](https://github.com/apple/container/pull/1618)).
- ContainerAPIClient / XPC migration, or shipping under Apple’s bundled `libexec/container/plugins/`.
- Renaming the formula, the plugin binary, or the SPM product.

## Approach

Rewrite the overlapping requirements to the symlink contract, then archive. `plugin` requires exactly one of `--install` or `--uninstall`. `--install` writes `config.toml` as a regular file and makes `bin/dev` an absolute symlink to the Homebrew opt path or, outside Homebrew, to the running executable path without realpath. `--uninstall` removes only those two layout entries. Homebrew `post_install` does not write Apple’s install-root. Doctor hints PATH `adevcontainer plugin --install`.

## Decision index

- **Command is `plugin`, not `install-plugin`:** `plugin --install` and `plugin --uninstall` are the only restage verbs. `install-plugin` is not a command and is not an alias. Neither flag, or both flags, is a usage error. Exactly one flag is required.
- **Install is an absolute symlink, not a copy:** `--install` removes `bin/dev` when it is a regular file or a symlink to the wrong target, then creates an absolute symlink. An already-correct absolute symlink is left in place. `config.toml` is always written as a regular file. `--install` MUST NOT copy the Mach-O into the plugin layout or change the mode or contents of the symlink target.
- **Homebrew target is the opt path:** When the running executable is Homebrew formula `adevcontainer`, including a versioned Cellar path and including `sudo` with a bare argv0, the symlink target MUST be `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`. It MUST NOT be a Cellar path and MUST NOT be a realpath of the keg. If that opt path cannot be formed, fail rather than fall back.
- **Non-Homebrew target is the running executable path:** No realpath resolution. A bare argv0 MUST NOT be treated as a relative source path.
- **Uninstall removes layout entries only:** `--uninstall` removes `bin/dev` and `config.toml` only. It MUST NOT delete the symlink target, the Homebrew keg, or any other path. A missing layout is success.
- **Doctor hints PATH `plugin --install`:** Missing-plugin remediation names PATH `adevcontainer plugin --install`, including `sudo` when the destination requires elevation. It MUST NOT name `container dev plugin --install`. `--repair` does not restage; any `--repair` fails as usage and hints `plugin --install`. Lifecycle commands do not restage.
- **Homebrew does not write Apple’s install-root:** `post_install` MUST NOT write `/usr/local/libexec/...` or any other Apple `container` install-root plugin path, and MUST NOT copy or chmod the formula binary into that layout. Caveats tell the user to run `sudo adevcontainer plugin --install` once after install, and again only after upgrading Apple `container`.

## Clarifications

- **Q:** The active `install-plugin-command` delta still required a Mach-O copy, `install-plugin`, and `post_install` restage. Archive it with `plugin-symlink-install`?
- **A:** Correct the overlapping requirements to the symlink contract first, then archive both. The symlink change is authoritative. Do not keep the copy text in the source spec.
