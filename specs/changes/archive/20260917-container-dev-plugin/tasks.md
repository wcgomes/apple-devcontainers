# Tasks: container-dev-plugin

Spec ref: `specs/changes/container-dev-plugin/`. Execute test-first: write the failing tests and confirm the expected failures before changing production code. Dual-install the same Mach-O as PATH `adevcontainer` and plugin `dev`. Do not auto-repair on lifecycle commands. Do not migrate labels, guest paths, or cache names. Do not treat the plugin binary as Apple `container`. Do not wait on home-dir plugins. Do not edit the wiki.

## 1. Failing tests for plugin contract, invocation, runtime, and doctor

- [x] 1.1 Write failing tests: plugin layout `{install-root}/libexec/container-plugins/dev/{config.toml,bin/dev}`; `config.toml` has `abstract` and omits `[servicesConfig]`; `--repair` writes this executable there; missing layout fails doctor with PATH `adevcontainer doctor --repair` remediation (not `container dev doctor --repair`); `--repair` is doctor-only; `up`/lifecycle do not restage; doctor without a workspace config still runs; plugin argv `dev <subcommand>` runs that subcommand; help/usage/retry hints use `container dev` when invoked as the plugin and `adevcontainer` when invoked as the PATH binary; managed labels stay `adevcontainer` under plugin invocation (path: `Tests/adevcontainerTests/ContainerPluginTests.swift`)
- [x] 1.2 Write failing tests: Apple `container` resolution prefers `/usr/local/bin/container` when that file is executable; the plugin binary `dev` is never selected as Apple `container` [P] (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.3 Extend existing PATH doctor tests so success still reports binary path and version when the plugin layout is present, missing Apple `container` still fails, and a non-running system status tells the user to run `container system start` [P] (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 1.4 Register the new plugin tests in the suite of record (path: `Tests/adevcontainerTests/main.swift`)
- [x] 1.5 Run the suite of record and confirm failures are limited to the missing plugin/invocation/repair behavior before production edits (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **PATH binary remains adevcontainer**
- [x] verify **Plugin layout uses name dev under container install-root**
- [x] verify **config.toml is a CLI plugin**
- [x] verify **Same Mach-O serves both surfaces**
- [x] verify **Plugin invocation runs the subcommand**
- [x] verify **Plugin invocation uses container-dev help and retry hints**
- [x] verify **PATH invocation uses adevcontainer help and retry hints**
- [x] verify **Managed identity stays adevcontainer when invoked as plugin**
- [x] verify **Default Apple container binary prefers usr-local**
- [x] verify **Plugin process does not exec itself as container**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **doctor --repair stages plugin layout**
- [x] verify **doctor --repair uses elevated privileges when required**
- [x] verify **doctor --repair is only valid on doctor**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**

## 2. Runtime: never treat the plugin as Apple container

- [x] 2.1 Keep preferring `/usr/local/bin/container` when executable; never resolve the plugin binary `dev` (or this process path) as Apple `container` (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)

## Checkpoint

- [x] verify **Default Apple container binary prefers usr-local**
- [x] verify **Plugin process does not exec itself as container**

## 3. Invocation prefix and doctor flag surface

- [x] 3.1 Add an invocation command prefix (`container dev` vs `adevcontainer`) from process invocation; use it in usage, per-command help, and CommandSurface retry hints; parse `--repair` and reject it on every command except `doctor`; document `doctor --repair` in doctor help (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)
- [x] 3.2 Dispatch `doctor --repair` and keep PATH `doctor` without `--repair` on the existing verb set when argv is `dev <subcommand> …` (path: `Sources/adevcontainer/AdevcontainerMain.swift`)

## Checkpoint

- [x] verify **Plugin invocation runs the subcommand**
- [x] verify **Plugin invocation uses container-dev help and retry hints**
- [x] verify **PATH invocation uses adevcontainer help and retry hints**
- [x] verify **doctor --repair is only valid on doctor**
- [x] verify **PATH binary remains adevcontainer**
- [x] verify **Dual surface does not rename the SPM product**
- [x] verify **Binary name and package layout**

## 4. Wire remaining retry hints

- [x] 4.1 Use the invocation prefix in connection-hint commands [P] (path: `Sources/ADevContainerLib/Support/StatusPrinter.swift`)
- [x] 4.2 Use the invocation prefix in managed-selection retry hints [P] (path: `Sources/ADevContainerLib/Support/ManagedContainers.swift`)
- [x] 4.3 Use the invocation prefix in occupancy/delete retry hints [P] (path: `Sources/ADevContainerLib/Runtime/ContainerIdentity.swift`)
- [x] 4.4 Use the invocation prefix in `up` retry hints [P] (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 4.5 Use the invocation prefix in `clone` retry hints [P] (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 4.6 Use the invocation prefix in `start` retry hints [P] (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 4.7 Use the invocation prefix in `exec` retry hints [P] (path: `Sources/ADevContainerLib/Commands/ExecCommand.swift`)
- [x] 4.8 Use the invocation prefix in `rebuild` retry hints [P] (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 4.9 Use the invocation prefix in recovery retry/cleanup hints [P] (path: `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift`)
- [x] 4.10 Use the invocation prefix in config-load retry hints [P] (path: `Sources/ADevContainerLib/Commands/ConfigReader.swift`)
- [x] 4.11 Use the invocation prefix in runtime retry hints that name this product [P] (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)

## Checkpoint

- [x] verify **Plugin invocation uses container-dev help and retry hints**
- [x] verify **PATH invocation uses adevcontainer help and retry hints**
- [x] verify **Managed identity stays adevcontainer when invoked as plugin**

## 5. Doctor plugin detection and explicit repair

- [x] 5.1 Detect missing plugin layout from Apple `container`’s install-root; fail doctor without `--repair` with exact PATH `adevcontainer doctor --repair` remediation; do not require `devcontainer.json`; keep missing Apple `container` and non-running `container system start` failures; do not restage unless `--repair` is set (path: `Sources/ADevContainerLib/Commands/DoctorCommand.swift`)
- [x] 5.2 Implement `doctor --repair`: copy this executable to `{install-root}/libexec/container-plugins/dev/bin/dev`, write `config.toml` with `abstract` and without `[servicesConfig]`, and use elevated privileges when the destination requires them (path: `Sources/ADevContainerLib/Commands/DoctorCommand.swift`)

## Checkpoint

- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **doctor --repair stages plugin layout**
- [x] verify **doctor --repair uses elevated privileges when required**
- [x] verify **config.toml is a CLI plugin**
- [x] verify **Same Mach-O serves both surfaces**
- [x] verify **Plugin layout uses name dev under container install-root**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**
- [x] verify **No Node dependency**

## 6. Packaging restage

- [x] 6.1 Homebrew formula: keep PATH `bin.install "adevcontainer"`; add `post_install` that restages `{install-root}/libexec/container-plugins/dev/{config.toml,bin/dev}` from this Mach-O; caveats MUST tell the user to reinstall this formula after upgrading `container` (path: `scripts/render-homebrew-formula.sh`)
- [x] 6.2 Tarball install: after placing PATH `adevcontainer`, restage the plugin layout the same way as `doctor --repair` [P] (path: `README.md`)
- [x] 6.3 Source install: after `swift build`, restage the plugin layout the same way as `doctor --repair` [P] (path: `CONTRIBUTING.md`)
- [x] 6.4 Confirm the SPM executable product remains `adevcontainer` (not a second product named `dev`) (path: `Package.swift`)

## Checkpoint

- [x] verify **Homebrew post_install restages the plugin**
- [x] verify **Homebrew caveats tell the user to reinstall after upgrading container**
- [x] verify **Tarball install restages the plugin layout**
- [x] verify **Source install restages the plugin layout**
- [x] verify **PATH binary remains adevcontainer**
- [x] verify **Dual surface does not rename the SPM product**
- [x] verify **Binary name and package layout**
- [x] verify **Plugin invocation runs the subcommand**

## 7. Suite of record

- [x] 7.1 Run `swift run adevcontainerTests` and confirm every scenario above maps to a passing test or packaging checkpoint (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **PATH binary remains adevcontainer**
- [x] verify **Plugin layout uses name dev under container install-root**
- [x] verify **config.toml is a CLI plugin**
- [x] verify **Same Mach-O serves both surfaces**
- [x] verify **Plugin invocation runs the subcommand**
- [x] verify **Plugin invocation uses container-dev help and retry hints**
- [x] verify **PATH invocation uses adevcontainer help and retry hints**
- [x] verify **Managed identity stays adevcontainer when invoked as plugin**
- [x] verify **Default Apple container binary prefers usr-local**
- [x] verify **Plugin process does not exec itself as container**
- [x] verify **PATH doctor still runs when plugin layout is missing**
- [x] verify **Lifecycle commands do not restage a missing plugin**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **doctor --repair stages plugin layout**
- [x] verify **doctor --repair uses elevated privileges when required**
- [x] verify **doctor --repair is only valid on doctor**
- [x] verify **Homebrew post_install restages the plugin**
- [x] verify **Homebrew caveats tell the user to reinstall after upgrading container**
- [x] verify **Tarball install restages the plugin layout**
- [x] verify **Source install restages the plugin layout**
- [x] verify **Binary name and package layout**
- [x] verify **No Node dependency**
- [x] verify **Dual surface does not rename the SPM product**
- [x] verify **Doctor success**
- [x] verify **Doctor missing binary**
- [x] verify **Doctor does not require devcontainer.json**
- [x] verify **Doctor surfaces container system start when not running**
