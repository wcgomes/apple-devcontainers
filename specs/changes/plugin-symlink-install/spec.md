# Change Spec: plugin-symlink-install

This delta supersedes the overlapping requirements in the still-active `specs/changes/install-plugin-command/spec.md`. Do not edit or archive that change as part of this work. Where both active deltas speak, this change is the contract.

## ADDED Requirements

### Requirement: Plugin uninstall removes layout entries only

`plugin --uninstall` MUST remove `{install-root}/libexec/container-plugins/dev/bin/dev` when that path is a symlink or a regular file, and MUST remove `{install-root}/libexec/container-plugins/dev/config.toml`. It MUST NOT delete the symlink target of `bin/dev`, MUST NOT delete the Homebrew keg or the opt-path executable, and MUST NOT remove any other path, including the plugin directory itself. Removing `config.toml` MUST unlink that path and MUST NOT delete a symlink target if `config.toml` is a symlink. When `bin/dev` and `config.toml` are already absent, uninstall MUST succeed. Uninstall MUST NOT require `container system start`.

When the destination is not writable, uninstall MUST re-exec with elevated privileges to complete the removal, or MUST print exact remediation naming PATH `adevcontainer plugin --uninstall` including `sudo`. That remediation MUST NOT name `container dev plugin --uninstall`.

#### Scenario: plugin --uninstall removes the plugin binary and config.toml only

- Given `bin/dev` is a symlink to an existing executable and `config.toml` exists, and the plugin directory contains another file
- When the user runs `plugin --uninstall`
- Then `bin/dev` and `config.toml` are gone, the symlink target still exists, and the other file remains

#### Scenario: plugin --uninstall removes a leftover copy without deleting the keg

- Given `bin/dev` is a regular file left by an older copy install, and the Homebrew keg and opt-path executable exist elsewhere
- When the user runs `plugin --uninstall`
- Then the leftover `bin/dev` and `config.toml` are removed and the keg and opt-path executable are unchanged

#### Scenario: plugin --uninstall succeeds when the layout is missing

- Given Apple `container` is installed and the plugin layout is already absent
- When the user runs `plugin --uninstall`
- Then the command succeeds and does not create the layout

#### Scenario: plugin --uninstall uses elevated privileges when required

- Given the plugin destination is not writable by the current user
- When the user runs `plugin --uninstall`
- Then the product re-execs with elevated privileges or prints exact remediation naming PATH `adevcontainer plugin --uninstall` with `sudo`, and MUST NOT name `container dev plugin --uninstall`

#### Scenario: plugin --uninstall does not require container system start

- Given Apple `container` is installed and Apple container services are not running
- When the user runs `adevcontainer plugin --uninstall`
- Then uninstall completes and MUST NOT fail because `container system start` has not been run

## MODIFIED Requirements

### Requirement: Dual install as Apple CLI plugin `dev`

The same Mach-O MUST be reachable as PATH `adevcontainer` and as an Apple `container` CLI plugin invoked as `container dev <subcommand>`. The plugin name, directory, and binary MUST be `dev`. The plugin binary MUST be an absolute symlink to the installed executable, not a second copy of the Mach-O.

On Unix, install-root MUST be the parent of Apple `container`’s `bin/` directory (typically `/usr/local`). The staged plugin layout MUST be:

- `{install-root}/libexec/container-plugins/dev/config.toml`
- `{install-root}/libexec/container-plugins/dev/bin/dev`

`config.toml` MUST be a regular file, MUST include `abstract`, and MUST omit `[servicesConfig]` so Apple treats it as a CLI plugin. Apple discovers plugins by that directory layout, not PATH. When Apple dispatches the plugin, process argv MUST begin with `dev` followed by the product subcommand. The product MUST NOT ship under Apple’s bundled `libexec/container/plugins/`. The SPM executable product name MUST remain `adevcontainer`. Dual install MUST be that absolute symlink, not a second package product and not a second copy of the Mach-O. The Homebrew formula name MUST remain `adevcontainer`.

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
- Then it is a regular file, includes `abstract`, and omits `[servicesConfig]`

#### Scenario: Plugin binary is an absolute symlink to the installed executable

- Given PATH `adevcontainer` is installed and the plugin is staged
- When the plugin binary path is inspected
- Then `{install-root}/libexec/container-plugins/dev/bin/dev` is an absolute symlink to the installed executable, not a second copy of the Mach-O

#### Scenario: Plugin invocation runs the subcommand

- Given the plugin is staged and Apple can dispatch plugins
- When the user runs `container dev` with a product subcommand
- Then that subcommand runs

### Requirement: Explicit plugin restage after Apple upgrade wipe

Apple installer or Homebrew keg replacement of `libexec` wipes user plugins under `container-plugins/` ([apple/container#1617](https://github.com/apple/container/issues/1617)). PATH `adevcontainer` survives. `container dev` then fails until the plugin layout is installed again.

The product MUST NOT restage the plugin layout on `up` or any other lifecycle command. `doctor` MUST detect a missing plugin layout and MUST print exact remediation naming PATH `adevcontainer plugin --install`, including `sudo` when the destination requires elevation. It MUST NOT suggest `container dev plugin --install` for a missing layout. A present layout is `config.toml` plus `bin/dev`, including when `bin/dev` is a symlink. Doctor MUST NOT require `bin/dev` to be a regular file and MUST NOT restage.

The product MUST provide `plugin` with `--install` and `--uninstall`. It MUST NOT provide `install-plugin` as a command or as an alias. `plugin` with neither flag, or with both flags, MUST fail as a usage error that names `--install` and `--uninstall` and states that exactly one is required. Usage and `plugin` help MUST document both flags and MUST NOT document `install-plugin` or `--repair`.

`plugin --install` and `plugin --uninstall` MUST derive install-root from the parent of Apple `container`’s `bin/` directory. If that binary cannot be resolved, they MUST fail with the existing missing-runtime error. They MUST NOT require `container system start` to succeed.

`plugin --install` MUST create `{install-root}/libexec/container-plugins/dev/bin/dev` as an absolute symlink and MUST write `config.toml` as a regular file with `abstract` and without `[servicesConfig]`. It MUST remove `bin/dev` first when that path is a regular file or a symlink whose target string is not the required absolute path, including a relative symlink that would resolve to the same file, and MUST NOT delete the old symlink’s target. If `bin/dev` is already an absolute symlink whose target string equals the required path, `--install` MUST succeed without replacing that symlink. It MUST still write `config.toml` as a regular file. If an existing `config.toml` is a symlink, `--install` MUST replace that path with a regular file and MUST NOT write through the symlink.

The required symlink target depends on how this product is installed. When the running executable is Homebrew formula `adevcontainer` — including when its path is a versioned Cellar path, and including when the process is invoked under `sudo` with a bare argv0 — the target MUST be the absolute path `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`. It MUST NOT be a versioned Cellar path and MUST NOT be the result of resolving symlinks in the keg. If that opt path cannot be formed, `--install` MUST fail and MUST NOT fall back to a Cellar path or a realpath-resolved path. When the running executable is not that Homebrew formula, the target MUST be the running executable’s path with no realpath resolution. A bare argv0 MUST NOT be treated as a relative source path.

When argv0 or the identified executable path is the plugin binary `{install-root}/libexec/container-plugins/dev/bin/dev` — an absolute path or the process name `dev` — `--install` MUST NOT create a symlink whose target is that plugin path. It MUST resolve the installed executable instead. If `bin/dev` is already an absolute symlink to a different path, apply the Homebrew vs non-Homebrew target rules to that link text: do not realpath a Cellar keg; a Cellar link becomes the opt path; an already-correct opt link is kept. If `bin/dev` is a regular file, a relative symlink, or a self-symlink, locate PATH `adevcontainer` or the Homebrew opt binary if present and link to that. If no installed executable other than `bin/dev` can be identified, `--install` MUST fail and MUST NOT create a self-symlink. PATH `adevcontainer plugin --install` is unchanged. Doctor missing-plugin remediation MUST still name PATH `adevcontainer plugin --install` and MUST NOT name `container dev plugin --install`.

`--install` MUST NOT copy the Mach-O into the plugin layout and MUST NOT change the mode or contents of the symlink target.

When the destination is not writable, `--install` MUST re-exec with elevated privileges to complete the install, or MUST print exact remediation naming PATH `adevcontainer plugin --install` including `sudo`. That remediation MUST NOT name `container dev plugin --install`.

`--repair` MUST NOT restage. Any `--repair` MUST fail as a usage error whose hint names `plugin --install` and MUST NOT name `install-plugin`.

Homebrew formula `post_install` MUST NOT write Apple’s install-root plugin layout (`/usr/local/libexec/...` or any other Apple `container` install-root `container-plugins` path) and MUST NOT copy or chmod the formula binary into that layout. Homebrew caveats MUST tell the user to run `sudo adevcontainer plugin --install` once after install, and again only after upgrading Apple `container`. Caveats MUST NOT tell the user to `brew reinstall` or `brew upgrade` this formula in order to restage the plugin. When the plugin symlink already targets `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`, `brew upgrade adevcontainer` MUST NOT require `plugin --install` again. README and source-install docs MUST name `adevcontainer plugin --install` (with `sudo` when the destination requires elevation) and MUST NOT name `install-plugin`. The product MUST NOT wait on unmerged home-dir plugin discovery.

#### Scenario: PATH doctor still runs when plugin layout is missing

- Given PATH `adevcontainer` is installed and the plugin layout is missing
- When the user runs `adevcontainer doctor`
- Then doctor runs as the PATH binary and reports the missing plugin layout

#### Scenario: Lifecycle commands do not restage a missing plugin

- Given the plugin layout is missing
- When the user runs `up` or another lifecycle command
- Then the product does not create the plugin symlink or write `config.toml` into the plugin layout

#### Scenario: Doctor reports missing plugin layout with exact remediation

- Given the plugin layout is missing
- When the user runs `adevcontainer doctor`
- Then doctor exits non-zero and prints exact remediation naming PATH `adevcontainer plugin --install` (with `sudo` when the destination requires elevation), not `container dev plugin --install`

#### Scenario: plugin --install creates an absolute symlink and writes config.toml

- Given the running executable and a writable plugin destination derived from Apple `container`’s install-root
- When the user runs `plugin --install`
- Then `bin/dev` is an absolute symlink to the required target, and `config.toml` is a regular file with `abstract` and without `[servicesConfig]`

#### Scenario: plugin --install replaces a copied plugin binary

- Given `bin/dev` is a regular file
- When the user runs `plugin --install`
- Then the product removes that regular file and creates an absolute symlink to the required target

#### Scenario: plugin --install replaces a symlink to the wrong target

- Given `bin/dev` is a relative symlink, or an absolute symlink whose target string is not the required path
- When the user runs `plugin --install`
- Then the product removes that symlink without deleting its target and creates an absolute symlink to the required target

#### Scenario: plugin --install keeps an already-correct symlink

- Given `bin/dev` is already an absolute symlink whose target string equals the required path
- When the user runs `plugin --install`
- Then the command succeeds without replacing that symlink, and `config.toml` is a regular file with `abstract` and without `[servicesConfig]`

#### Scenario: plugin --install writes config.toml as a regular file

- Given an existing `config.toml` is a symlink
- When the user runs `plugin --install`
- Then `config.toml` is replaced with a regular file that includes `abstract` and omits `[servicesConfig]`, and the previous symlink target is unchanged

#### Scenario: Homebrew install links the opt path

- Given the running executable is Homebrew formula `adevcontainer`, including a versioned Cellar path and including invocation under `sudo` with a bare argv0
- When the user runs `plugin --install`
- Then `bin/dev` is an absolute symlink to `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`, not a versioned Cellar path and not the result of resolving symlinks in the keg
- And if that opt path cannot be formed, the command fails and does not create a Cellar-path or realpath-resolved symlink

#### Scenario: Non-Homebrew install links the running executable path

- Given the running executable is not Homebrew formula `adevcontainer`
- When the user runs `plugin --install`
- Then `bin/dev` is an absolute symlink to the running executable’s path, and that path is not realpath-resolved

#### Scenario: plugin --install does not symlink bin/dev to itself

- Given argv0 is the plugin binary `{install-root}/libexec/container-plugins/dev/bin/dev` or the process name `dev`
- When the user runs `plugin --install`
- Then `bin/dev` is not a symlink whose target is that plugin path
- And if `bin/dev` was already an absolute symlink to a different path, the target follows the Homebrew or non-Homebrew rule for that link text (a Cellar link becomes the opt path; an already-correct opt link is kept; the keg is not realpath-resolved)
- And if `bin/dev` is a regular file, a relative symlink, or a self-symlink, the target is PATH `adevcontainer` or the Homebrew opt binary when one of those is present
- And if no installed executable other than `bin/dev` can be identified, the command fails and does not create a self-symlink

#### Scenario: plugin --install does not treat a bare argv0 as a relative source path

- Given a non-Homebrew install invoked with a bare executable name (for example under `sudo`)
- When the user runs `plugin --install`
- Then the symlink target is the running executable’s absolute path and MUST NOT be the bare name as a relative path

#### Scenario: plugin --install does not mutate the symlink target

- Given a symlink target that is the installed executable, including a Homebrew keg binary
- When the user runs `plugin --install`
- Then the product does not copy the Mach-O into the plugin layout and does not change the mode or contents of that target

#### Scenario: plugin --install uses elevated privileges when required

- Given the plugin destination is not writable by the current user
- When the user runs `plugin --install`
- Then the product re-execs with elevated privileges or prints exact remediation naming PATH `adevcontainer plugin --install` with `sudo`, and MUST NOT name `container dev plugin --install`

#### Scenario: plugin --install does not require container system start

- Given Apple `container` is installed and Apple container services are not running
- When the user runs `adevcontainer plugin --install`
- Then the product installs the plugin layout and MUST NOT fail because `container system start` has not been run

#### Scenario: plugin with neither flag is a usage error

- Given the user invokes `plugin` with neither `--install` nor `--uninstall`
- When the command parses
- Then it fails as a usage error that names both flags and states that exactly one is required

#### Scenario: plugin with both flags is a usage error

- Given the user invokes `plugin` with both `--install` and `--uninstall`
- When the command parses
- Then it fails as a usage error that names both flags and states that exactly one is required

#### Scenario: install-plugin is not a command

- Given the product command surface
- When the user runs `install-plugin`
- Then the command fails as an unknown command, is not an alias for `plugin --install`, and the hint names `plugin` and does not list `install-plugin` as a valid command

#### Scenario: --repair fails as usage and hints plugin --install

- Given any command, including `doctor` and `plugin`
- When the user passes `--repair`
- Then the command fails as a usage error and the hint names `plugin --install` and does not name `install-plugin`

#### Scenario: Homebrew post_install does not write Apple's install-root

- Given the Homebrew formula rendered by `scripts/render-homebrew-formula.sh`
- When `post_install` is inspected
- Then it does not write Apple’s install-root plugin layout and does not copy or chmod the formula binary into that layout

#### Scenario: Homebrew caveats name plugin --install

- Given the Homebrew formula is installed
- When caveats are shown
- Then they tell the user to run `sudo adevcontainer plugin --install` once after install, and again only after upgrading Apple `container`
- And they do not tell the user to `brew reinstall` or `brew upgrade` this formula in order to restage the plugin

#### Scenario: brew upgrade does not require restage when the symlink targets the opt path

- Given `bin/dev` is an absolute symlink to `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`
- When the user upgrades formula `adevcontainer`
- Then the symlink remains valid without running `plugin --install` again

#### Scenario: Tarball install uses plugin --install

- Given the user installs from the release tarball onto PATH
- When install instructions are followed
- Then the plugin layout is installed with PATH `adevcontainer plugin --install` (with `sudo` when the destination requires elevation), not with `install-plugin` and not by copying the Mach-O into the plugin layout

#### Scenario: Source install uses plugin --install

- Given the user builds from source
- When install instructions are followed
- Then the plugin layout is installed with PATH `adevcontainer plugin --install` (with `sudo` when the destination requires elevation), not with `install-plugin`

### Requirement: Doctor preflight

`adevcontainer doctor` MUST verify host readiness before users rely on `up`: Apple `container` binary presence (default path `/usr/local/bin/container` or PATH resolution), invokability, and a reported version suitable for machine use. Doctor MUST also verify the Apple CLI plugin layout for `dev` under the install-root parent of Apple `container`’s `bin/`. Doctor MUST emit a clear pass/fail summary. Doctor MUST NOT require a `devcontainer.json`.

PATH invocation of `adevcontainer doctor` MUST keep the existing missing-binary failure. Success MUST still report Apple `container` binary path and version and MUST require the plugin layout to be present, including when `bin/dev` is a symlink. When Apple container services are not running, doctor MUST surface that `container system start` is required (Apple needs it to list/dispatch plugins). Doctor MUST NOT restage the plugin layout. Doctor MUST NOT accept `--repair`. When the plugin layout is missing, doctor MUST fail and print PATH `adevcontainer plugin --install` remediation as specified in **Explicit plugin restage after Apple upgrade wipe**.

#### Scenario: Doctor success

- Given Apple `container` is installed and runnable and the plugin layout is present
- When the user runs `adevcontainer doctor`
- Then the command exits 0 and reports binary path and version

#### Scenario: Doctor missing binary

- Given `container` is not on PATH and not at the default path
- When the user runs `adevcontainer doctor`
- Then the command exits non-zero with a structured error explaining the missing runtime

#### Scenario: Doctor does not require devcontainer.json

- Given a directory with no `devcontainer.json`
- When the user runs `adevcontainer doctor`
- Then doctor does not fail for missing configuration

#### Scenario: Doctor surfaces container system start when not running

- Given Apple `container` is installed and the system status is not running
- When the user runs `adevcontainer doctor`
- Then doctor exits non-zero and tells the user to run `container system start`
