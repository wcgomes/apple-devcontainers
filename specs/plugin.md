# adevcontainer — Plugin Specification

## Purpose

Apple `container` CLI plugin surface: dual install of the same Mach-O as PATH `adevcontainer` and plugin `container dev`, invocation-aware help and retry hints with stable `adevcontainer` managed identity, subprocess targeting of Apple `container` (never the plugin), and explicit plugin restage after Apple upgrade wipe.

## Requirements

### Requirement: Dual install as Apple CLI plugin `dev`

The same Mach-O MUST be installed as PATH `adevcontainer` and as an Apple `container` CLI plugin invoked as `container dev <subcommand>`. The plugin name, directory, and binary MUST be `dev`.

On Unix, install-root MUST be the parent of Apple `container`’s `bin/` directory (typically `/usr/local`). The staged plugin layout MUST be:

- `{install-root}/libexec/container-plugins/dev/config.toml`
- `{install-root}/libexec/container-plugins/dev/bin/dev`

`config.toml` MUST include `abstract` and MUST omit `[servicesConfig]` so Apple treats it as a CLI plugin. Apple discovers plugins by that directory layout, not PATH. When Apple dispatches the plugin, process argv MUST begin with `dev` followed by the product subcommand. The product MUST NOT ship under Apple’s bundled `libexec/container/plugins/`. The SPM executable product name MUST remain `adevcontainer`; dual install MUST be a second copy of that Mach-O, not a second package product.

#### Scenario: PATH binary remains adevcontainer
- Given a successful install of this product
- When the user runs the PATH binary
- Then the executable name is `adevcontainer`

#### Scenario: Plugin layout uses name dev under container install-root
- Given Apple `container` is installed at `{install-root}/bin/container`
- When the plugin is staged
- Then `{install-root}/libexec/container-plugins/dev/config.toml` and `{install-root}/libexec/container-plugins/dev/bin/dev` exist

#### Scenario: config.toml is a CLI plugin
- Given the plugin is staged
- When `config.toml` is read
- Then it includes `abstract` and omits `[servicesConfig]`

#### Scenario: Same Mach-O serves both surfaces
- Given PATH `adevcontainer` and the plugin binary are both installed
- When the two files are compared
- Then the plugin binary is a copy of the same Mach-O as the PATH executable

#### Scenario: Plugin invocation runs the subcommand
- Given the plugin is staged and Apple can dispatch plugins
- When the user runs `container dev` with a product subcommand
- Then that subcommand runs

---

### Requirement: Invocation-aware help and retry hints

Help, usage, and retry hints MUST use `container dev …` when the process is invoked as the Apple CLI plugin. They MUST use `adevcontainer …` when the process is invoked as the PATH binary. Managed labels, guest paths, and cache names MUST remain `adevcontainer` under both invocations. The product MUST NOT migrate identity strings to `dev`.

#### Scenario: Plugin invocation uses container-dev help and retry hints
- Given the process is invoked as the Apple CLI plugin
- When the user requests help or receives a retry hint
- Then printed command examples use the prefix `container dev`

#### Scenario: PATH invocation uses adevcontainer help and retry hints
- Given the process is invoked as the PATH binary `adevcontainer`
- When the user requests help or receives a retry hint
- Then printed command examples use the prefix `adevcontainer`

#### Scenario: Managed identity stays adevcontainer when invoked as plugin
- Given the process is invoked as the Apple CLI plugin
- When the product stamps managed labels, guest paths, or cache names
- Then those values remain `adevcontainer` and are not rewritten to `dev`

---

### Requirement: Apple container subprocess is never the plugin

The product MUST keep shelling out to Apple `container` as a subprocess. It MUST prefer `/usr/local/bin/container` when that binary exists. It MUST NOT treat the plugin binary as Apple `container` (no recursive self-exec). It MUST NOT migrate host runtime interaction to ContainerAPIClient or XPC.

#### Scenario: Default Apple container binary prefers usr-local
- Given `/usr/local/bin/container` exists and is executable
- When the product resolves the Apple `container` binary
- Then it uses `/usr/local/bin/container`

#### Scenario: Plugin process does not exec itself as container
- Given the process is the plugin binary `dev`
- When the product shells out to Apple `container`
- Then the subprocess executable is Apple `container`, not the plugin binary

---

### Requirement: Explicit plugin restage after Apple upgrade wipe

Apple installer or Homebrew keg replacement of `libexec` wipes user plugins under `container-plugins/` ([apple/container#1617](https://github.com/apple/container/issues/1617)). PATH `adevcontainer` survives. `container dev` then fails until the plugin layout is restaged.

The product MUST NOT restage the plugin layout on `up` or any other lifecycle command. `doctor` MUST detect a missing plugin layout and MUST print exact remediation naming PATH `adevcontainer doctor --repair`, including elevated privileges when the destination requires them. It MUST NOT suggest `container dev doctor --repair` for a missing layout.

Explicit `doctor --repair` MUST copy this executable and `config.toml` into the plugin layout, using elevated privileges when the destination requires them. `--repair` MUST be valid only on `doctor`.

Homebrew formula `post_install` MUST restage that same layout. Homebrew caveats MUST tell the user to reinstall this formula after upgrading `container`. Tarball install and source install MUST restage the same layout. The product MUST NOT wait on unmerged home-dir plugin discovery.

#### Scenario: PATH doctor still runs when plugin layout is missing
- Given PATH `adevcontainer` is installed and the plugin layout is missing
- When the user runs `adevcontainer doctor`
- Then doctor runs as the PATH binary and reports the missing plugin layout

#### Scenario: Lifecycle commands do not restage a missing plugin
- Given the plugin layout is missing
- When the user runs `up` or another lifecycle command
- Then the product does not copy the executable or `config.toml` into the plugin layout

#### Scenario: Doctor reports missing plugin layout with exact remediation
- Given the plugin layout is missing
- When the user runs `adevcontainer doctor` without `--repair`
- Then doctor exits non-zero and prints exact remediation naming `adevcontainer doctor --repair` (with elevated privileges when required), not `container dev doctor --repair`

#### Scenario: doctor --repair stages plugin layout
- Given the current executable and a writable plugin destination derived from Apple `container`’s install-root
- When the user runs `doctor --repair`
- Then the product writes this executable to `{install-root}/libexec/container-plugins/dev/bin/dev` and writes `config.toml` with `abstract` and without `[servicesConfig]`

#### Scenario: doctor --repair uses elevated privileges when required
- Given the plugin destination is not writable by the current user
- When the user runs `doctor --repair`
- Then the product copies using elevated privileges or prints exact remediation that uses them

#### Scenario: doctor --repair is only valid on doctor
- Given any command other than `doctor`
- When the user passes `--repair`
- Then the command fails as a usage error

#### Scenario: Homebrew post_install restages the plugin
- Given the Homebrew formula is installed
- When `post_install` runs
- Then it restages the plugin layout under Apple `container`’s install-root

#### Scenario: Homebrew caveats tell the user to reinstall after upgrading container
- Given the Homebrew formula is installed
- When caveats are shown
- Then they tell the user to reinstall this formula after upgrading `container`

#### Scenario: Tarball install restages the plugin layout
- Given the user installs from the release tarball onto PATH
- When install instructions are followed
- Then the plugin layout is restaged the same way as `doctor --repair`

#### Scenario: Source install restages the plugin layout
- Given the user builds from source
- When install instructions are followed
- Then the plugin layout is restaged the same way as `doctor --repair`
