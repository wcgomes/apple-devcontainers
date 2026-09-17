# Proposal: Apple CLI plugin `container dev`

## Intent

Users need this product as both a PATH binary `adevcontainer` and an Apple `container` CLI plugin `container dev …`. Apple discovers plugins from a `libexec` directory layout that its installer and Homebrew keg replace, wiping user plugins ([apple/container#1617](https://github.com/apple/container/issues/1617)). This change records dual install, invocation-aware help, and explicit plugin restage without changing managed identity.

## Scope

- Change id: **`container-dev-plugin`**.
- Affected live domain: [core.md](../../../core.md) **Product identity and packaging** and **Doctor preflight**.
- Dual surface: the same Mach-O installed as PATH `adevcontainer` and as Apple CLI plugin `container dev <subcommand>`.
- Invocation-aware help, usage, and retry hints; managed labels, guest paths, and cache names stay `adevcontainer`.
- Doctor detects a missing plugin layout and restages only via explicit `doctor --repair`; Homebrew `post_install` and tarball/source install restage the same layout.
- Runtime keeps shelling out to Apple `container` (prefer `/usr/local/bin/container`) and MUST NOT treat the plugin binary as `container`.

## Non-goals

- First-party ship under Apple bundled `libexec/container/plugins/`.
- Changing create-name, managed labels, guest paths, or cache names.
- Docker Compose.
- Notarize / codesign.
- Plugin shell completions via Apple’s `container` generator (those completions need not include plugin verbs).
- Auto-repair on `up` or any other lifecycle command.
- Waiting on unmerged home-dir plugin discovery ([apple/container#1618](https://github.com/apple/container/pull/1618)).
- ContainerAPIClient / XPC migration away from subprocess `container`.
- Wiki edits or archive of this change as part of specification creation.

## Approach

Keep the SPM executable product named `adevcontainer`. Install that same Mach-O a second time as Apple plugin `dev` under `{install-root}/libexec/container-plugins/dev/`, where install-root is the parent of Apple `container`’s `bin/` (typically `/usr/local`). Detect plugin vs PATH invocation and print `container dev …` or `adevcontainer …` in help, usage, and retry hints only. Extend `doctor` to check that layout and to restage it solely when the user passes `--repair` (elevated privileges when required). Homebrew `post_install` restages; caveats tell the user to reinstall this formula after upgrading `container`; tarball and source install document the same restage. Do not restage from `up` or other lifecycle commands.

## Decision index

- **Dual surface:** The same Mach-O is PATH `adevcontainer` and Apple CLI plugin `container dev <subcommand>`. One binary, two install locations.
- **Plugin name is `dev`:** Plugin directory and binary MUST be `dev` so invocation is `container dev <subcommand>`. Built-in Apple subcommands shadow plugins; `dev` is the chosen name, not a bundled Apple verb.
- **Layout is Apple’s install-root, not PATH and not the Homebrew keg:** Unix layout, install-root = parent of `container`’s `bin/` (typically `/usr/local`): `{install-root}/libexec/container-plugins/dev/config.toml` and `{install-root}/libexec/container-plugins/dev/bin/dev`. Apple discovers plugins by that directory layout. Homebrew may place the PATH binary in a keg; `post_install` still restages into Apple’s layout.
- **`config.toml` is a CLI plugin:** MUST include `abstract`. MUST omit `[servicesConfig]`.
- **Dispatch argv:** Apple `execvp`s the plugin; argv becomes `dev <subcommand> …`. Subcommand handling stays the existing verb set.
- **Invocation-aware hints, stable identity:** Help, usage, and retry hints MUST use `container dev …` when invoked as the plugin and `adevcontainer …` when invoked as the PATH binary. Managed labels, guest paths, and cache names MUST remain `adevcontainer` (no identity migration).
- **Missing-plugin remediation is PATH-only:** When the plugin layout is missing, `container dev` cannot start. Doctor remediation MUST name PATH `adevcontainer doctor --repair` (with elevated privileges when required), never `container dev doctor --repair`.
- **Runtime target is Apple `container`, never the plugin:** Prefer `/usr/local/bin/container`. MUST NOT treat the plugin binary as `container` (no recursion). No ContainerAPIClient/XPC migration.
- **`container system start`:** Required for Apple to list/dispatch plugins. Doctor MUST surface that when Apple container services are not running.
- **No Apple-generated plugin completions:** Out of scope; Apple `container` completions need not include plugin verbs.
- **Upgrade wipe, explicit repair only:** Apple installer/Homebrew keg replace of `libexec` drops user plugins in `container-plugins/` ([apple/container#1617](https://github.com/apple/container/issues/1617)). PATH `adevcontainer` survives; `container dev` fails until restaged. MUST NOT auto-repair on `up`/lifecycle. Doctor MUST detect a missing layout and print exact remediation. Explicit `doctor --repair` MUST copy this executable and `config.toml` into the plugin layout (elevated privileges when needed). Homebrew formula `post_install` restages; caveats MUST tell the user to reinstall this formula after upgrading `container`. Tarball/source install MUST restage the same layout. Do not wait on unmerged [#1618](https://github.com/apple/container/pull/1618).
- **`--repair` is doctor-only:** Valid only on `doctor`. Other commands MUST reject it as usage.
- **No `design.md`:** Dual layout, invocation prefix, no-recursion runtime, and explicit restage remain understandable in this index and in `tasks.md`; the overflow rule is not met.

## Clarifications

- **Q:** PATH binary, Apple plugin, or both?
  **A:** Dual surface. The same Mach-O is installed as PATH `adevcontainer` and as Apple CLI plugin `container dev <subcommand>`.

- **Q:** What is the plugin name and directory?
  **A:** MUST be `dev` (name, directory, and binary) so invocation is `container dev <subcommand>`. Layout (Unix, install-root = parent of `container`’s `bin/`, typically `/usr/local`): `{install-root}/libexec/container-plugins/dev/config.toml` and `{install-root}/libexec/container-plugins/dev/bin/dev`.

- **Q:** How does Apple discover and dispatch the plugin?
  **A:** By that directory layout, not PATH. `container` `execvp`s the plugin; argv becomes `dev <subcommand> …`. Built-in Apple subcommands shadow plugins.

- **Q:** What MUST `config.toml` contain?
  **A:** MUST include `abstract`. MUST omit `[servicesConfig]` so Apple treats it as a CLI plugin.

- **Q:** Do help and identity strings follow the plugin name?
  **A:** Help, usage, and retry hints MUST use `container dev …` when invoked as the plugin and `adevcontainer …` when invoked as the PATH binary. Managed labels, guest paths, and cache names MUST remain `adevcontainer` (no identity migration).

- **Q:** What does doctor print when the plugin layout is missing?
  **A:** Exact remediation naming PATH `adevcontainer doctor --repair` (and elevated privileges when required). MUST NOT suggest `container dev doctor --repair`, because Apple cannot dispatch a missing plugin.

- **Q:** Does the runtime call Apple `container` through the plugin?
  **A:** No. It MUST keep shelling out to Apple `container` (prefer `/usr/local/bin/container`) and MUST NOT treat the plugin binary as `container` (no recursion). No ContainerAPIClient/XPC migration.

- **Q:** Must `container system start` be running for the plugin?
  **A:** Yes, Apple requires it to list/dispatch plugins. Doctor MUST surface that when relevant. Completions generated by Apple `container` need not include plugin verbs.

- **Q:** What happens when Apple upgrades wipe `libexec`?
  **A:** User plugins in `container-plugins/` are lost ([apple/container#1617](https://github.com/apple/container/issues/1617)). PATH `adevcontainer` survives. `container dev` fails until restaged. MUST NOT auto-repair on `up`/lifecycle. Doctor MUST detect the missing layout and print exact remediation. Explicit `doctor --repair` MUST copy this executable and `config.toml` into the plugin layout (elevated privileges when needed). Homebrew `post_install` restages; caveats MUST tell the user to reinstall this formula after upgrading `container`. Tarball/source install MUST restage the same layout. Do not wait on unmerged [#1618](https://github.com/apple/container/pull/1618).

- **Q:** Is `--repair` a global flag?
  **A:** No. `--repair` MUST be valid only on `doctor`.
