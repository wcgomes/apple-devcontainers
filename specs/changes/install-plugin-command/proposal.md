# Proposal: Dedicated `install-plugin` restage command

## Intent

`doctor --repair` mixes host preflight with plugin restage. After an Apple upgrade wipe, users need a PATH-only restage verb that copies the running Mach-O even under `sudo`, and `doctor` must stay a check-only command. This change replaces `doctor --repair` with `adevcontainer install-plugin`.

## Scope

- Change id: **`install-plugin-command`**.
- Affected live domains: [plugin.md](../../plugin.md) **Explicit plugin restage after Apple upgrade wipe**; [core.md](../../core.md) **Doctor preflight**.
- Restage is the `install-plugin` verb only. `--repair` is gone.
- `doctor` still detects a missing plugin and prints PATH `adevcontainer install-plugin` (`sudo` when the destination needs elevation). It MUST NOT print `container dev install-plugin` when the layout is missing.
- `install-plugin` only restages (copy running Mach-O + `config.toml`). It MUST NOT require `container system start` to succeed. It MUST resolve the source via the running executable, not a bare argv0.
- Lifecycle still does not restage. Homebrew, tarball, and source docs use `install-plugin`.

## Non-goals

- Auto-repair on `up` or any other lifecycle command.
- Changing doctor host checks other than removing restage: binary, version, system running, and plugin present remain.
- Wiki edits or edits to archived `specs/changes/archive/20260917-container-dev-plugin/`.
- Waiting on unmerged home-dir plugin discovery ([apple/container#1618](https://github.com/apple/container/pull/1618)).
- ContainerAPIClient / XPC migration.
- First-party ship under Apple bundled `libexec/container/plugins/`.
- Product-code implementation as part of writing these artifacts.

## Approach

Add `install-plugin` to the dispatcher alongside `doctor` / `up` / …. Move restage (copy running Mach-O + `config.toml`, elevation when required) onto that verb. Keep the existing running-executable source resolution (not bare argv0) under `install-plugin`. Strip `--repair` from `doctor` and reject `--repair` as usage with a hint naming `install-plugin`. Point missing-plugin doctor remediation and Homebrew/tarball/source docs at PATH `adevcontainer install-plugin`.

## Decision index

- **Restage is `install-plugin`, not a doctor flag:** Plugin restage after Apple upgrade wipe is a first-class verb in the dispatcher. `doctor` remains checks only.
- **`--repair` is gone:** Any `--repair` MUST fail as usage. The usage hint MUST name `install-plugin`.
- **Missing-plugin remediation is PATH-only:** When the layout is missing, `container dev` cannot start. Doctor MUST print PATH `adevcontainer install-plugin` (`sudo` when the destination needs elevation). It MUST NOT suggest `container dev install-plugin`.
- **`install-plugin` only restages:** It MUST copy the running Mach-O and write `config.toml`. It MUST NOT require `container system start` to succeed. It MUST NOT run doctor’s version/status success path as a restage precondition.
- **Source is the running executable:** Restage MUST resolve the source Mach-O from the running executable (PATH / symlink target as needed). It MUST NOT treat a bare argv0 (for example `sudo adevcontainer`) as a relative path. Keep the existing uncommitted argv0 resolution under `install-plugin`.
- **Lifecycle still does not restage:** `up` and other lifecycle commands MUST NOT copy the executable or `config.toml`.
- **Packaging docs use `install-plugin`:** Homebrew `post_install` still restages the same layout. Caveats, tarball, and source install instructions name `adevcontainer install-plugin` instead of `doctor --repair`. Caveats still tell the user to reinstall this formula after upgrading `container`.
- **No `design.md`:** Verb split, source resolution, and doctor-vs-restage separation remain understandable in this index and in `tasks.md`; the overflow rule is not met.
