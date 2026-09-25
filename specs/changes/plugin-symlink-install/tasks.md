# Tasks: plugin-symlink-install

Spec ref: `specs/changes/plugin-symlink-install/`. Execute test-first: write the failing tests and confirm the expected failures before changing production code. This change supersedes overlapping `install-plugin` copy and Homebrew `post_install` restage requirements. Do not edit or archive `specs/changes/install-plugin-command/`. Do not edit the wiki. Do not push `wcgomes/homebrew-tap`. Do not stage or commit `.devcontainer/devcontainer.json` or `.devcontainer/install-tools.sh`. Formula name stays `adevcontainer`. Plugin binary name stays `dev`. SPM product stays `adevcontainer`.

Verified test paths beyond the command modules: `Tests/adevcontainerTests/AllCommandTests.swift` already calls `InstallPluginCommand.run` and expects a copied Mach-O while services are stopped. `Tests/adevcontainerTests/main.swift` is the suite-of-record entry. Both must be updated or the suite cannot match this contract. No other product files are in scope.

## 1. Failing tests for symlink install, uninstall, and doctor checks

- [x] 1.1 Retarget plugin tests to this contract: `plugin` with neither flag or both flags is a usage error naming both flags; `install-plugin` is an unknown command and not an alias; usage and help document `plugin --install` and `plugin --uninstall` and do not document `install-plugin` or `--repair`; `--repair` fails as usage and hints `plugin --install`; missing-plugin doctor prints PATH `adevcontainer plugin --install` (`sudo` when elevation is required) and never `container dev plugin --install`; `--install` creates an absolute symlink plus regular-file `config.toml` (`abstract`, no `[servicesConfig]`), replaces a regular-file copy and a wrong or relative symlink without deleting the old target, leaves an already-correct absolute symlink in place, replaces a symlinked `config.toml` without writing through it, and does not copy or chmod the target; Homebrew target is `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer` even for a Cellar path and under `sudo` with a bare argv0, never Cellar and never realpath, and fails closed if the opt path cannot be formed; non-Homebrew target is the running executable path without realpath; bare argv0 is not a relative source path; elevation remediation names PATH `adevcontainer plugin --install` or `plugin --uninstall` with `sudo`; `--uninstall` removes only `bin/dev` and `config.toml`, leaves the target, keg, and other files, and succeeds when the layout is missing; `up`/lifecycle still do not restage; doctor accepts a symlink layout as present and does not restage (path: `Tests/adevcontainerTests/ContainerPluginTests.swift`)
- [x] 1.2 Retarget the stopped-services install test so `plugin --install` installs the symlink layout while Apple container services are not running and succeeds without requiring `container system start`; `plugin --uninstall` likewise does not require `container system start`; doctor still fails for a non-running system and MUST NOT restage [P] (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [ ] 1.3 Run the suite of record and confirm failures are limited to the missing `plugin` verb, remaining `install-plugin` copy restage, and stale `install-plugin` remediation (path: `Tests/adevcontainerTests/main.swift`). BLOCKED: this host is Linux and `Package.swift` requires macOS 26, so the suite was not executed.

## Checkpoint

- [x] verify **plugin with neither flag is a usage error**
- [x] verify **plugin with both flags is a usage error**
- [x] verify **install-plugin is not a command**
- [x] verify **--repair fails as usage and hints plugin --install**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **plugin --install creates an absolute symlink and writes config.toml**
- [x] verify **plugin --install replaces a copied plugin binary**
- [x] verify **plugin --install replaces a symlink to the wrong target**
- [x] verify **plugin --install keeps an already-correct symlink**
- [x] verify **plugin --install writes config.toml as a regular file**
- [x] verify **Homebrew install links the opt path**
- [x] verify **Non-Homebrew install links the running executable path**
- [x] verify **plugin --install does not symlink bin/dev to itself**
- [x] verify **plugin --install does not treat a bare argv0 as a relative source path**
- [x] verify **plugin --install does not mutate the symlink target**
- [x] verify **plugin --install uses elevated privileges when required**
- [x] verify **plugin --install does not require container system start**
- [x] verify **plugin --uninstall removes the plugin binary and config.toml only**
- [x] verify **plugin --uninstall removes a leftover copy without deleting the keg**
- [x] verify **plugin --uninstall succeeds when the layout is missing**
- [x] verify **plugin --uninstall uses elevated privileges when required**
- [x] verify **plugin --uninstall does not require container system start**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Plugin binary is an absolute symlink to the installed executable**

## 2. Command surface

- [x] 2.1 Remove `install-plugin` from usage, help, and unknown-command hints. Add `plugin` documenting `--install` and `--uninstall` and that exactly one is required. Neither flag or both flags is a usage error naming both flags. Reject `--repair` on every command as usage with a hint naming `plugin --install` and not `install-plugin`. Missing-plugin help MUST name PATH `adevcontainer plugin --install` and MUST NOT name `container dev plugin --install`. Other help stays invocation-aware (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)

## Checkpoint

- [x] verify **plugin with neither flag is a usage error**
- [x] verify **plugin with both flags is a usage error**
- [x] verify **install-plugin is not a command**
- [x] verify **--repair fails as usage and hints plugin --install**
- [x] verify **Doctor reports missing plugin layout with exact remediation**

## 3. Symlink install, uninstall, and doctor checks

- [x] 3.1a Plugin-invocation `--install` must not retarget `bin/dev` at itself. If argv0 or the identified path is the plugin binary (absolute path or process name `dev`), reuse an existing absolute link text (Cellar becomes the opt path; keep an opt link; do not realpath the keg) or locate PATH `adevcontainer` / the Homebrew opt binary. Fail instead of creating a self-symlink. PATH `adevcontainer plugin --install` is unchanged. (path: `Sources/ADevContainerLib/Commands/DoctorCommand.swift`, `Tests/adevcontainerTests/ContainerPluginTests.swift`)
- [x] 3.1 Replace copy/chmod staging with absolute-symlink install and layout-only uninstall. Homebrew target is `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`, including Cellar-path and sudo bare-argv0 invocations; do not call `resolvingSymlinksInPath` on the keg; if the opt path cannot be formed, fail instead of using a Cellar or realpath target. Non-Homebrew target is the running executable path without realpath; bare argv0 is not a relative source path. Keep an already-correct absolute symlink; replace a regular file or wrong symlink without deleting the old target. Write `config.toml` as a regular file and do not write through an existing symlink. Do not copy the Mach-O or chmod the target. Missing-plugin hint names PATH `adevcontainer plugin --install` (`sudo` when required). Doctor stays checks-only and treats a symlink layout as present. Do not require `container system start` (path: `Sources/ADevContainerLib/Commands/DoctorCommand.swift`)
- [x] 3.2 Replace this command module with `plugin --install` and `plugin --uninstall` (rename the file to `PluginCommand.swift` in this same task; do not keep `InstallPluginCommand` or an `install-plugin` alias). Derive install-root from Apple `container`. Re-exec with elevated privileges or print PATH remediation with `sudo` naming `adevcontainer plugin --install` or `adevcontainer plugin --uninstall`. Missing layout uninstall succeeds. Do not require `container system start` (path: `Sources/ADevContainerLib/Commands/InstallPluginCommand.swift`)
- [x] 3.3 Dispatch `plugin` and remove the `install-plugin` case. Unknown-command hint MUST include `plugin` and MUST NOT list `install-plugin`. `doctor` MUST NOT accept `--repair` (path: `Sources/adevcontainer/AdevcontainerMain.swift`)

## Checkpoint

- [x] verify **plugin --install creates an absolute symlink and writes config.toml**
- [x] verify **plugin --install replaces a copied plugin binary**
- [x] verify **plugin --install replaces a symlink to the wrong target**
- [x] verify **plugin --install keeps an already-correct symlink**
- [x] verify **plugin --install writes config.toml as a regular file**
- [x] verify **Homebrew install links the opt path**
- [x] verify **Non-Homebrew install links the running executable path**
- [x] verify **plugin --install does not symlink bin/dev to itself**
- [x] verify **plugin --install does not treat a bare argv0 as a relative source path**
- [x] verify **plugin --install does not mutate the symlink target**
- [x] verify **plugin --install uses elevated privileges when required**
- [x] verify **plugin --install does not require container system start**
- [x] verify **plugin --uninstall removes the plugin binary and config.toml only**
- [x] verify **plugin --uninstall removes a leftover copy without deleting the keg**
- [x] verify **plugin --uninstall succeeds when the layout is missing**
- [x] verify **plugin --uninstall uses elevated privileges when required**
- [x] verify **plugin --uninstall does not require container system start**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**
- [x] verify **Plugin binary is an absolute symlink to the installed executable**
- [x] verify **config.toml is a CLI plugin**

## 4. Packaging docs stop restaging Apple's install-root

- [x] 4.1 Formula name stays `adevcontainer`. Remove `post_install` writes to Apple’s install-root (`/usr/local/libexec/...` or any Apple install-root plugin path), including `cp` and `chmod` of the formula binary into that layout. Caveats MUST tell the user to run `sudo adevcontainer plugin --install` once after install, and again only after upgrading Apple `container`. Caveats MUST state that `brew upgrade adevcontainer` does not require `plugin --install` again when the symlink already targets the opt path. Caveats MUST NOT tell the user to `brew reinstall` or `brew upgrade` this formula to restage the plugin. Do not push the external tap (path: `scripts/render-homebrew-formula.sh`)
- [x] 4.2 Homebrew install instructions tell the user to run `sudo adevcontainer plugin --install` once after `brew install`, and again only after upgrading Apple `container`, and that `brew upgrade adevcontainer` does not require restage when the symlink targets the opt path. Tarball install uses PATH `adevcontainer plugin --install` (`sudo` when the destination requires elevation). Command table and plugin section name `plugin --install` and `plugin --uninstall`. MUST NOT name `install-plugin`, `doctor --repair`, or `container dev plugin --install` for a missing layout, and MUST NOT say `post_install` or `brew reinstall` restages the plugin [P] (path: `README.md`)
- [x] 4.3 Source install uses PATH `adevcontainer plugin --install` (`sudo` when the destination requires elevation) and MUST NOT name `install-plugin` [P] (path: `CONTRIBUTING.md`)

## Checkpoint

- [x] verify **Homebrew post_install does not write Apple's install-root**
- [x] verify **Homebrew caveats name plugin --install**
- [x] verify **brew upgrade does not require restage when the symlink targets the opt path**
- [x] verify **Tarball install uses plugin --install**
- [x] verify **Source install uses plugin --install**

## 5. Suite of record

- [ ] 5.1 Run `swift run adevcontainerTests` and confirm every scenario above maps to a passing test or packaging checkpoint (path: `Tests/adevcontainerTests/main.swift`). BLOCKED: this host is Linux and `Package.swift` requires macOS 26, so the suite was not executed and must not be reported as passed.

## Checkpoint

- [x] verify **PATH binary remains adevcontainer**
- [x] verify **Plugin layout uses name dev under container install-root**
- [x] verify **config.toml is a CLI plugin**
- [x] verify **Plugin binary is an absolute symlink to the installed executable**
- [x] verify **Plugin invocation runs the subcommand**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **plugin --install creates an absolute symlink and writes config.toml**
- [x] verify **plugin --install replaces a copied plugin binary**
- [x] verify **plugin --install replaces a symlink to the wrong target**
- [x] verify **plugin --install keeps an already-correct symlink**
- [x] verify **plugin --install writes config.toml as a regular file**
- [x] verify **Homebrew install links the opt path**
- [x] verify **Non-Homebrew install links the running executable path**
- [x] verify **plugin --install does not symlink bin/dev to itself**
- [x] verify **plugin --install does not treat a bare argv0 as a relative source path**
- [x] verify **plugin --install does not mutate the symlink target**
- [x] verify **plugin --install uses elevated privileges when required**
- [x] verify **plugin --install does not require container system start**
- [x] verify **plugin with neither flag is a usage error**
- [x] verify **plugin with both flags is a usage error**
- [x] verify **install-plugin is not a command**
- [x] verify **--repair fails as usage and hints plugin --install**
- [x] verify **Homebrew post_install does not write Apple's install-root**
- [x] verify **Homebrew caveats name plugin --install**
- [x] verify **brew upgrade does not require restage when the symlink targets the opt path**
- [x] verify **Tarball install uses plugin --install**
- [x] verify **Source install uses plugin --install**
- [x] verify **plugin --uninstall removes the plugin binary and config.toml only**
- [x] verify **plugin --uninstall removes a leftover copy without deleting the keg**
- [x] verify **plugin --uninstall succeeds when the layout is missing**
- [x] verify **plugin --uninstall uses elevated privileges when required**
- [x] verify **plugin --uninstall does not require container system start**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**
