# Tasks: install-plugin-command

Spec ref: `specs/changes/install-plugin-command/`. Execute test-first: write the failing tests and confirm the expected failures before changing production code. Replace `doctor --repair` with `install-plugin`. Keep running-executable source resolution under `install-plugin`. Do not auto-repair on lifecycle commands. Do not edit the wiki. Do not edit archived specs.

## 1. Failing tests for install-plugin restage and doctor checks

- [x] 1.1 Retarget plugin tests so missing-plugin doctor prints PATH `adevcontainer install-plugin` (`sudo` when elevation is required) and never `container dev install-plugin`; `install-plugin` stages this Mach-O plus `config.toml` (`abstract`, no `[servicesConfig]`); bare argv0 restages from the running executable (PATH / symlink target as needed); `--repair` fails as usage and hints `install-plugin` on doctor, install-plugin, and other commands; doctor help/usage no longer document `--repair`; `up`/lifecycle still do not restage (path: `Tests/adevcontainerTests/ContainerPluginTests.swift`)
- [x] 1.2 Retarget doctor command tests so `install-plugin` restages while Apple container services are not running and succeeds without requiring `container system start`; doctor still fails for a non-running system and MUST NOT restage [P] (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 1.3 Run the suite of record and confirm failures are limited to the missing `install-plugin` verb, remaining `--repair` restage, and stale `doctor --repair` remediation (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **install-plugin stages plugin layout**
- [x] verify **install-plugin uses elevated privileges when required**
- [x] verify **install-plugin does not require container system start**
- [x] verify **install-plugin resolves source from the running executable**
- [x] verify **--repair fails as usage and hints install-plugin**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**

## 2. Command surface: reject `--repair`, document `install-plugin`

- [x] 2.1 Reject `--repair` on every command as usage with a hint naming `install-plugin`; add `install-plugin` to usage and per-command help; doctor help/usage MUST NOT document `--repair`; missing-plugin help MUST name PATH `adevcontainer install-plugin` and MUST NOT name `container dev install-plugin` (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)

## Checkpoint

- [x] verify **--repair fails as usage and hints install-plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**

## 3. install-plugin restage and doctor checks only

- [x] 3.1 Implement `install-plugin`: copy the running Mach-O (not bare argv0) and write `config.toml`; use elevated privileges or print PATH `adevcontainer install-plugin` with `sudo` when required; MUST NOT require `container system start` to succeed (path: `Sources/ADevContainerLib/Commands/InstallPluginCommand.swift`)
- [x] 3.2 Stop restaging from `doctor`; keep binary, version, system-running, and plugin-present checks; missing-plugin error MUST name PATH `adevcontainer install-plugin` (`sudo` when elevation is required) and MUST NOT name `container dev install-plugin` [P] (path: `Sources/ADevContainerLib/Commands/DoctorCommand.swift`)
- [x] 3.3 Dispatch `install-plugin` alongside `doctor` / `up` / …; `doctor` MUST NOT accept `--repair`; unknown-command hint MUST include `install-plugin` (path: `Sources/adevcontainer/AdevcontainerMain.swift`)

## Checkpoint

- [x] verify **install-plugin stages plugin layout**
- [x] verify **install-plugin uses elevated privileges when required**
- [x] verify **install-plugin does not require container system start**
- [x] verify **install-plugin resolves source from the running executable**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **--repair fails as usage and hints install-plugin**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**

## 4. Packaging docs use `install-plugin`

- [x] 4.1 Homebrew caveats: keep reinstall-after-upgrade; replace `doctor --repair` with `adevcontainer install-plugin` (`sudo` when `/usr/local/libexec` is not writable); keep `post_install` restaging the same layout (path: `scripts/render-homebrew-formula.sh`)
- [x] 4.2 Tarball install: restage with PATH `adevcontainer install-plugin` after placing PATH `adevcontainer`; MUST NOT tell the user to run `doctor --repair` or `container dev install-plugin` when the plugin is missing [P] (path: `README.md`)
- [x] 4.3 Source install: restage with PATH `adevcontainer install-plugin` (`sudo` when the destination requires it) [P] (path: `CONTRIBUTING.md`)

## Checkpoint

- [x] verify **Homebrew post_install restages the plugin**
- [x] verify **Homebrew caveats tell the user to reinstall after upgrading container**
- [x] verify **Tarball install restages the plugin layout**
- [x] verify **Source install restages the plugin layout**

## 5. Suite of record

- [x] 5.1 Run `swift run adevcontainerTests` and confirm every scenario above maps to a passing test or packaging checkpoint (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **install-plugin stages plugin layout**
- [x] verify **install-plugin uses elevated privileges when required**
- [x] verify **install-plugin does not require container system start**
- [x] verify **install-plugin resolves source from the running executable**
- [x] verify **--repair fails as usage and hints install-plugin**
- [x] verify **Homebrew post_install restages the plugin**
- [x] verify **Homebrew caveats tell the user to reinstall after upgrading container**
- [x] verify **Tarball install restages the plugin layout**
- [x] verify **Source install restages the plugin layout**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**
