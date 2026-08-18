# Change Spec: global-git-author-identity

## MODIFIED Requirements

### Requirement: Clone applies host-resolved git author identity locally and globally
On an initial `adevcontainer clone`, the existing host identity resolution, environment overrides, and TTY confirmation/collection behavior MUST remain unchanged. After a complete chosen `user.name` and `user.email` identity is available, after the in-container full clone succeeds and `<workspaceFolder>/.git` is verified, and before the first create-path lifecycle hook runs, the CLI MUST write both values to `<workspaceFolder>/.git/config` at repository-local scope and MUST write the same values to the resolved connection user's global Git config at `$HOME/.gitconfig` in the created container. The local and global pairs MUST match the chosen identity. The local repository configuration MUST remain present and authoritative for the primary repository; global-only configuration MUST NOT replace it. A failure of the global write MUST be warning-only: clone MUST retain the local behavior, continue the existing create path, run its hooks, and MUST NOT delete the created container or workspace, invoke bring-up recovery or a recovery helper, or prompt solely because the global write failed.

#### Scenario: New clone writes local and global identity before sibling hook
- Given an initial clone creates a fresh workspace volume, resolves the complete identity `Ada Lovelace` / `ada@example.com`, and resolves connection user `alice`
- When the in-container repository is cloned and verified
- Then `<workspaceFolder>/.git/config` contains the chosen local `user.name` and `user.email`, `$HOME/.gitconfig` for `alice` contains the same global values, and a create-path hook that clones a sibling repository as `alice` can inherit that identity when the first hook runs

#### Scenario: Fresh clone does not rely on an existing global config
- Given a new clone container has no prior global author identity and its workspace volume is freshly created
- When clone completes with a complete chosen identity
- Then clone writes both local repository keys and both connection-user global keys from the chosen pair without requiring a persisted HOME or a prior global configuration

#### Scenario: The main repository keeps local precedence
- Given the main clone has local `user.name` and `user.email` and the same connection user's global config also contains author values
- When Git resolves the author identity for the main repository
- Then the repository-local values are selected by Git, and a repository-local override remains effective even when global values exist

#### Scenario: Incomplete initial clone identity keeps current behavior
- Given initial clone identity resolution remains incomplete after the existing non-interactive resolution path
- When clone reaches author application
- Then clone does not write a partial local pair or any global author pair, emits the existing-style warning/collection behavior, and does not invent values; TTY prompting and collection remain governed by the current clone behavior

#### Scenario: Clone global synchronization failure is non-destructive
- Given clone successfully applies the local identity but writing the connection user's global Git config fails
- When clone continues toward create-path hooks
- Then clone emits only the global-write warning, keeps the local identity, runs the configured hook, does not delete the created container or workspace volume, and does not invoke bring-up recovery, create or use a recovery helper, or prompt solely because global synchronization failed

## ADDED Requirements

### Requirement: Rebuild rehydrates global author identity from the existing workspace repository
On an ordinary `adevcontainer rebuild` of an existing managed workspace, in both bind and volume modes, the CLI MUST capture `user.name` and `user.email` from the existing workspace repository's local configuration before replacement begins and before the old container is deleted. Bind mode MAY read the host workspace, but volume mode MUST read the existing workspace inside the old container, or another source that remains valid before old-container deletion, and MUST NOT use a host GitClient path. The captured local pair is the sole source of truth for rebuild synchronization. The CLI MUST use only a complete local pair for synchronization and MUST NOT use global configuration, labels, credential files, or invented values as the source. After the replacement container starts, the CLI MUST complete the existing ownership preparation, credential-forwarding work, and `[DIAG]` work before writing the captured pair to the new container's resolved connection user's global Git config at that user's current `$HOME/.gitconfig`; this write MUST occur before any create-path lifecycle hook runs. Existing global values in the replacement container MUST be updated to match the workspace-local pair. Rebuild MUST NOT rewrite or remove the workspace repository's local identity as part of this synchronization.

#### Scenario: Bind rebuild rehydrates local identity before hooks
- Given an existing bind-mode workspace repository has complete local identity `Ada Lovelace` / `ada@example.com`, and the replacement resolves connection user `alice`
- When ordinary rebuild captures the identity, deletes the old container, creates and starts the replacement, and reaches the create path
- Then capture completed before old-container deletion, the replacement user's `$HOME/.gitconfig` contains the workspace-local pair before the first create-path hook runs, and a hook cloning a sibling repository as `alice` inherits that pair

#### Scenario: Volume rebuild rehydrates local identity before hooks
- Given an existing volume-mode workspace repository has complete local identity `Ada Lovelace` / `ada@example.com` in its retained workspace volume
- When ordinary rebuild reads that repository from the old container before deleting it and starts the replacement
- Then the replacement connection user's global Git config contains the same pair before the first create-path hook runs, without using a host GitClient path, re-cloning, or changing the retained workspace volume

#### Scenario: Rebuild global synchronization follows existing pre-hook work
- Given a replacement container has started and the existing ownership, credential-forwarding, and `[DIAG]` work has run
- When rebuild synchronizes a complete captured local identity
- Then the global write occurs after those existing steps and before the first create-path lifecycle hook

#### Scenario: Rebuild writes to the replacement HOME
- Given the old container's global Git config is absent or has different values and the replacement container has a different, non-persisted HOME
- When rebuild synchronizes a complete local identity
- Then the replacement connection user's current `$HOME/.gitconfig` is written with the local pair, and synchronization does not depend on copying or retaining the old container HOME

#### Scenario: Manual local changes are reflected on the next rebuild
- Given a user manually changes both local author keys in an existing bind or volume workspace repository after its previous container was created
- When the user runs the next ordinary rebuild
- Then the new container's connection-user global author keys match the manually changed local pair rather than the previous global values

#### Scenario: Missing or incomplete local identity skips rebuild synchronization
- Given an existing workspace repository has a missing or incomplete local `user.name`/`user.email` pair and the replacement container has existing global author values
- When ordinary rebuild runs
- Then rebuild does not prompt, invent, partially synchronize, or alter the existing global values, and it emits at most the existing-style warning while continuing with the normal rebuild path

#### Scenario: Rebuild global synchronization failure is warning-and-continue
- Given rebuild reads a complete local pair but writing the replacement connection user's global Git config fails
- When rebuild reaches the pre-hook identity step
- Then rebuild emits only the global-write warning and continues through the existing replacement flow and create-path hooks, does not delete the new container or workspace volume, and does not invoke bring-up recovery, create or use a recovery helper, or prompt solely because global synchronization failed; the ordinary old-container deletion remains the only expected rebuild deletion

### Requirement: Author identity scope and credential non-regression
Author synchronization MUST affect only the resolved connection user in the created or replacement container. It MUST NOT modify global Git configuration for other container users, any host Git configuration, labels, or credential files. This change MUST NOT alter credential-helper behavior, current credential seeding, current `[DIAG]` work, or existing clone/rebuild hook failure cleanup and recovery semantics. Explicit populate, author-write, hook-failure, recovery, and successful-hook regressions MUST preserve those existing outcomes. `up` fresh-create is outside this change and MUST NOT gain this author synchronization behavior.

#### Scenario: Connection-user isolation and host config remain untouched
- Given a complete local identity, a replacement connection user `alice`, another container user `bob`, and host Git configuration containing different author values
- When clone or rebuild synchronizes the identity
- Then only `alice`'s container global Git config changes, `bob`'s global config and the host Git config remain unchanged, and no label or credential file contains the author identity

#### Scenario: Credential forwarding remains separate
- Given a clone or rebuild also exercises the existing HTTPS credential acquisition/seeding path and its current `[DIAG]` instrumentation
- When author identity synchronization runs
- Then credential-helper configuration, credential seeding, `[DIAG]` output/work, and their existing ordering remain unchanged, and on rebuild the author global write follows those existing steps and precedes the first create-path hook

#### Scenario: Clone populate failure retains cleanup and recovery
- Given clone has created its container and workspace volume but in-container populate or `.git` verification fails
- When clone returns the structured failure
- Then clone deletes the created container and workspace volume, does not report success, and retains the existing eligibility and behavior of clone recovery

#### Scenario: Clone author-write failure does not trigger unrelated cleanup
- Given clone populate succeeds, a local or global author write reports failure, and a create-path hook is configured to succeed
- When clone continues after the author-write warning
- Then clone does not delete the container or workspace volume, does not enter recovery solely for the author failure, and the hook runs

#### Scenario: Clone hook failure after identity work retains cleanup
- Given clone has completed its identity work and a create-path hook fails
- When clone handles the hook failure
- Then clone applies the existing container and workspace-volume cleanup and existing recovery eligibility for hook failure, without a new author-specific cleanup path

#### Scenario: Clone author failure does not bypass later cleanup
- Given clone reports a local or global author-write warning and a later create-path hook fails
- When clone handles the hook failure
- Then clone still applies the existing container and workspace-volume cleanup and existing recovery eligibility, without treating the earlier author warning as a reason to skip cleanup

#### Scenario: Clone successful hooks continue after identity work
- Given clone has a complete identity and one or more create-path hooks that succeed
- When clone completes local and global identity writes
- Then the existing create-path hooks run in their existing order and clone succeeds without cleanup

#### Scenario: Rebuild hook failure retains mode-specific cleanup and recovery
- Given rebuild has synchronized identity in the replacement and a create-path hook fails
- When rebuild handles the hook failure
- Then the failed replacement container is handled by the existing rebuild hook-failure cleanup, bind-mode recovery/retention and volume-mode recovery/retained-workspace semantics remain unchanged, and identity synchronization does not invoke a separate recovery path or delete/repopulate the retained workspace volume

#### Scenario: Rebuild successful hooks continue after identity work
- Given rebuild has captured a complete local identity, synchronized it successfully, and its create-path hooks succeed
- When the replacement create path completes
- Then the existing hooks run in their existing order and rebuild succeeds without deleting the replacement container or retained workspace

## REMOVED Requirements

None.
