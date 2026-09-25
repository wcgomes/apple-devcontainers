# Tasks: install-plugin-command

Spec ref: `specs/changes/archive/20260925-install-plugin-command/`.

Corrected before archive. This checklist no longer mandates a Mach-O copy, `install-plugin`, or Homebrew `post_install` restage. The authoritative contract, and the implementation tasks that realized it, are `specs/changes/archive/20260925-plugin-symlink-install/`. Do not edit the wiki. Do not edit other archived specs.

## 1. Align overlapping requirements to the symlink contract

- [x] 1.1 Rewrite this change so its requirements match the symlink contract: `plugin --install` / `plugin --uninstall`; absolute symlink, not a copy; Homebrew opt target `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`; uninstall removes layout entries only; `post_install` does not write Apple’s install-root; doctor hints PATH `adevcontainer plugin --install`; `install-plugin` is not a command; `--repair` does not restage (path: `specs/changes/archive/20260925-install-plugin-command/spec.md`)

## Checkpoint

- [x] verify **plugin --install creates an absolute symlink and writes config.toml**
- [x] verify **Homebrew install links the opt path**
- [x] verify **plugin --uninstall removes the plugin binary and config.toml only**
- [x] verify **Homebrew post_install does not write Apple's install-root**
- [x] verify **Doctor reports missing plugin layout with exact remediation**
- [x] verify **install-plugin is not a command**
- [x] verify **--repair fails as usage and hints plugin --install**
