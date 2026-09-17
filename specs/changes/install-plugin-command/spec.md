# Change Spec: install-plugin-command

## MODIFIED Requirements

### Requirement: Explicit plugin restage after Apple upgrade wipe

Apple installer or Homebrew keg replacement of `libexec` wipes user plugins under `container-plugins/` ([apple/container#1617](https://github.com/apple/container/issues/1617)). PATH `adevcontainer` survives. `container dev` then fails until the plugin layout is restaged.

The product MUST NOT restage the plugin layout on `up` or any other lifecycle command. `doctor` MUST detect a missing plugin layout and MUST print exact remediation naming PATH `adevcontainer install-plugin`, including `sudo` when the destination requires elevation. It MUST NOT suggest `container dev install-plugin` for a missing layout.

The product MUST provide `install-plugin` as a command. Explicit `install-plugin` MUST copy the running Mach-O and `config.toml` into the plugin layout, using elevated privileges when the destination requires them. `install-plugin` MUST NOT require `container system start` to succeed. `install-plugin` MUST resolve the source Mach-O from the running executable; it MUST NOT treat a bare argv0 as the source path.

`--repair` MUST NOT restage. Any `--repair` MUST fail as a usage error whose hint names `install-plugin`.

Homebrew formula `post_install` MUST restage that same layout. Homebrew caveats MUST tell the user to reinstall this formula after upgrading `container`. Homebrew, tarball, and source install docs MUST name `adevcontainer install-plugin` for restage. The product MUST NOT wait on unmerged home-dir plugin discovery.

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
- When the user runs `adevcontainer doctor`
- Then doctor exits non-zero and prints exact remediation naming `adevcontainer install-plugin` (with `sudo` when the destination requires elevation), not `container dev install-plugin`

#### Scenario: install-plugin stages plugin layout

- Given the running executable and a writable plugin destination derived from Apple `container`’s install-root
- When the user runs `install-plugin`
- Then the product writes this executable to `{install-root}/libexec/container-plugins/dev/bin/dev` and writes `config.toml` with `abstract` and without `[servicesConfig]`

#### Scenario: install-plugin uses elevated privileges when required

- Given the plugin destination is not writable by the current user
- When the user runs `install-plugin`
- Then the product copies using elevated privileges or prints exact remediation that uses them naming PATH `adevcontainer install-plugin`

#### Scenario: install-plugin does not require container system start

- Given Apple `container` is installed and Apple container services are not running
- When the user runs `adevcontainer install-plugin`
- Then the product restages the plugin layout and MUST NOT fail because `container system start` has not been run

#### Scenario: install-plugin resolves source from the running executable

- Given the process is invoked with a bare executable name (for example under `sudo`)
- When the user runs `install-plugin`
- Then the product copies the running Mach-O into the plugin layout and MUST NOT treat the bare name as a relative source path

#### Scenario: --repair fails as usage and hints install-plugin

- Given any command, including `doctor` and `install-plugin`
- When the user passes `--repair`
- Then the command fails as a usage error and the hint names `install-plugin`

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
- Then the plugin layout is restaged the same way as `install-plugin`

#### Scenario: Source install restages the plugin layout

- Given the user builds from source
- When install instructions are followed
- Then the plugin layout is restaged the same way as `install-plugin`

---

### Requirement: Doctor preflight

`adevcontainer doctor` MUST verify host readiness before users rely on `up`: Apple `container` binary presence (default path `/usr/local/bin/container` or PATH resolution), invokability, and a reported version suitable for machine use. Doctor MUST also verify the Apple CLI plugin layout for `dev` under the install-root parent of Apple `container`’s `bin/`. Doctor MUST emit a clear pass/fail summary. Doctor MUST NOT require a `devcontainer.json`.

PATH invocation of `adevcontainer doctor` MUST keep the existing missing-binary failure. Success MUST still report Apple `container` binary path and version and MUST require the plugin layout to be present. When Apple container services are not running, doctor MUST surface that `container system start` is required (Apple needs it to list/dispatch plugins). Doctor MUST NOT restage the plugin layout. Doctor MUST NOT accept `--repair`. When the plugin layout is missing, doctor MUST fail and print PATH `adevcontainer install-plugin` remediation as specified in **Explicit plugin restage after Apple upgrade wipe**.

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
