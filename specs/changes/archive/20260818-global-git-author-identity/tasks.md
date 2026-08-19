# Tasks: global-git-author-identity

Spec ref: `specs/changes/archive/20260818-global-git-author-identity/`. Test-first ordering: write each failing test, confirm it fails, then implement. The suite of record is `swift run adevcontainerTests`; integration suites retain their existing runtime skips. Current source anchors are `RebuildCommand.swift:423-438` for the Phase B/old-container deletion boundary, `:635-698` for ownership and credential work, `:700-777` for `[DIAG]`, `:843-851` for `runCreatePathThroughWaitFor`, and `CloneCommand.swift:487-559` plus `:880-915` for populate, author application, and hooks. Do not edit the `git-credential-forwarding` bundle, wiki, or unrelated source/test artifacts during this planning task.

## 1. Contract tests — fail first

- [x] 1.1 Extend the clone runtime fixture to record local/global author writes, the resolved connection user, populate verification, and hook events; assert a complete initial identity writes matching local and global pairs in local-first order before the first `-lc` hook while leaving the primary repository local configuration present (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [ ] 1.2 Add failing clone scenarios for fresh-volume sibling inheritance, local-over-global precedence, incomplete non-interactive identity, and global-write failure; assert incomplete input writes no partial or invented pair, while global failure is warning-only, does not delete the container or workspace volume, does not invoke BringUpRecovery, create/use a recovery helper, or prompt, and still runs the configured hook (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 1.3 Extend `RebuildScenario` with separate injectable host-reader and old-container guest-reader fixtures; the guest fixture MUST return complete/incomplete local pairs from the old container workspace, record the old-container read event, and make the volume test fail if a host GitClient/path is consulted (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [ ] 1.4 Add failing bind and volume rebuild order scenarios that assert `old-container-local-read < old-container-delete < replacement-create < replacement-start < ownership work < credential-seeding work < [DIAG] work < replacement-global-write < first create-path hook`; include replacement HOME, manual local changes, complete-pair gating, and no-prompt/no-invention cases (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 1.5 Add failing bind and volume rebuild global-write failure scenarios with a complete captured pair; assert exactly one warning for the identity failure, no deletion of the replacement container or workspace volume beyond the expected old-container deletion, no BringUpRecovery/helper/prompt, successful continuation through the replacement flow, and execution of the first hook (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [ ] 1.6 Add explicit clone cleanup regressions for populate/`.git` verification failure, local/global author-write failure followed by a failing hook, author-write failure with a successful hook, and successful hook continuation; populate and later-hook failure MUST delete the created container and `*-ws` volume and retain existing clone recovery eligibility, while author failure alone MUST not cause unrelated cleanup or suppress hooks (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [ ] 1.7 Add explicit rebuild hook regressions for failed-hook replacement cleanup (`rebuildHookFailureDeletesNewContainer`), bind recovery/retention (`rebuildBindPostCreateNonTTYOffersHostPathRecovery` and `rebuildBindTTYRecoveryEditsHostAndRetries`), volume recovery/retained-workspace behavior (`rebuildVolumeHookFailureRetainsWorkspaceAndRecovery`), and successful hook continuation (`rebuildHookOrderOnNewContainer`); identity synchronization MUST not suppress, reroute, or change these existing outcomes (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 1.8 Add unit-level failing coverage for the local-only reader and shared writer seams: `--local` versus `--global` scope, host versus old-container guest execution, resolved-user execution, value transport, complete-pair gating, connection-user isolation, and failure reporting without host config, labels, credential files, or credential-helper changes (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 1.9 Add a command-level boundary regression that `up` fresh-create never invokes author identity synchronization while its existing ownership, credential seeding, `[DIAG]`, and recovery assertions remain valid (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint

- [ ] The new identity, ordering, source-selection, failure, precedence, HOME, isolation, hook-continuation, and `up` boundary tests are red on the current implementation; unchanged cleanup/recovery regression tests establish their current green baseline, and any identity-enabled variants fail only for the missing identity behavior.

## 2. Identity boundary primitives — implementation after red

- [x] 2.1 Add a local-only host author reader to the Git client boundary, distinct from clone's host-resolved `resolveAuthorIdentity`, that obtains both fields with `git -C <workspace> config --local --get` and maps missing/empty fields to an incomplete `GitAuthorIdentity` without consulting global/includeIf values (path: `Sources/ADevContainerLib/Git/GitClient.swift`)
- [x] 2.2 Add an injectable `RebuildLocalIdentityReader` boundary with separate host-workspace and old-container guest-workspace operations; bind mode may delegate to the host local reader, while volume mode MUST execute the local Git reads through `AppleContainerRuntime` against the existing old container and MUST never route through a host GitClient/path; missing repositories, missing fields, and guest-read errors become incomplete identity rather than rebuild failure (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 2.3 Add a narrowly scoped guest author-identity writer that accepts a complete `GitAuthorIdentity`, container id, resolved user, and runtime; writes only global `user.name` and `user.email` through the connection user's current HOME using argv-safe Git commands, rejects incomplete input without a partial pair, and exposes failures to callers (path: `Sources/ADevContainerLib/Git/GitAuthorIdentitySync.swift`)

## Checkpoint

- [x] The reader uses the workspace-local pair as its only source, the volume implementation has no host-path fallback, and the shared writer changes only the resolved user's global author keys without credential-helper, label, credential-file, or persisted-HOME behavior.

## 3. Initial clone local-plus-global application

- [x] 3.1 Extend `CloneCommand.applyAuthorIdentityInContainer` at `CloneCommand.swift:880-915` after the existing local application: preserve the complete-pair gate and current local warnings, invoke the shared global writer only after both local writes succeed, use the same resolved connection user, and catch global-write failure as a warning-only continuation that cannot throw into clone cleanup/recovery or suppress hooks (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [ ] 3.2 Update clone handlers only as needed to observe the shared writer's global commands and exact hook order, then make the fresh-volume, sibling-inheritance, local-precedence, incomplete, author-failure, global-failure, cleanup, recovery, and successful-hook scenarios pass (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)

## Checkpoint

- [ ] Clone's complete identity writes local and global values in order; incomplete and local-write failures retain current behavior; global failure is warning-only and non-destructive; populate and hook failures retain existing cleanup/recovery; the existing in-container credential store/approve path remains the sole clone credential mechanism.

## 4. Rebuild local capture and replacement synchronization

- [x] 4.1 Inject the local identity reader and capture a complete local-only pair before the Phase B boundary at `RebuildCommand.swift:423` and before old-container deletion at `:425-438`; bind mode reads the stamped host workspace, volume mode reads the existing workspace inside the old container using the runtime/guest seam, and neither mode reads global configuration, labels, credential files, or invented values (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 4.2 Invoke the shared global writer on the replacement container's resolved connection user after the existing ownership block (`RebuildCommand.swift:635-678`), credential-seeding block (`:680-698`), and `[DIAG]` block (`:700-777`), and immediately before `runCreatePathThroughWaitFor` (`:843-851`); write to the replacement user's current HOME without rewriting local config or changing the retained volume (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 4.3 Make global synchronization failure warning-only: continue the existing replacement flow and hooks, preserve the one expected old-container deletion, perform no replacement-container or workspace-volume deletion, and do not invoke BringUpRecovery, a recovery helper, or a prompt solely for this failure; if a later hook failure legitimately enters existing rebuild recovery, retry must re-read the workspace-local source before replacement rather than use replacement global config (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [ ] 4.4 Update the rebuild phase fixtures to distinguish the old-container local read from replacement-container global write and assert the exact event order for bind and volume modes, including soft-skipped/soft-failed ownership or credential work and the `[DIAG]` probe before identity sync and the first hook (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [ ] 4.5 Verify manual local changes win on the next rebuild, incomplete pairs skip global synchronization without prompt or invention, only the replacement connection user changes, and a successful identity sync leaves the local workspace pair unchanged (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)

## Checkpoint

- [ ] Bind and volume rebuilds capture the complete local pair before old-container deletion and rehydrate it into the replacement connection user's current HOME after existing pre-hook work and before hooks; volume mode never uses a host GitClient path; incomplete pairs skip without prompting or invention; global failure warns and continues without replacement/workspace deletion or identity-specific recovery.

## 5. Regression and scope audit

- [ ] 5.1 Keep explicit clone tests for `cloneTempCleanupOnPopulateFailure`, `clonePopulateVerifyFailsWhenGitMissing`, `cloneHookFailureDeletesContainer`, and successful hook continuation, and add named `cloneAuthorWriteFailureKeepsContainerAndRunsHook` and `cloneAuthorThenHookFailureCleansContainerAndVolume` cases that assert no unrelated deletion/recovery for author failure alone and normal cleanup/recovery after a later hook failure (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [ ] 5.2 Keep explicit rebuild tests for `rebuildHookFailureDeletesNewContainer`, `rebuildBindPostCreateNonTTYOffersHostPathRecovery`, `rebuildBindTTYRecoveryEditsHostAndRetries`, `rebuildVolumeHookFailureRetainsWorkspaceAndRecovery`, and `rebuildHookOrderOnNewContainer`, with identity sync enabled, so failed-hook cleanup/recovery and successful hook continuation are directly asserted rather than inferred from an ordering review (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [ ] 5.3 Confirm the active rebuild credential-seeding scenarios still pass, including bind host-remote discovery, volume stamped-URL discovery, silent missing-URL skip, seed-before-hook order, and soft-fail/no-recovery behavior; keep current `[DIAG]` assertions intact and assert identity sync follows those steps (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 5.4 Audit `up` fresh-create and recovery tests for accidental author-sync expectations; retain the explicit out-of-scope boundary and existing ownership/credential/[DIAG] recovery behavior (path: `Tests/adevcontainerTests/UpCommandRecoveryTests.swift`)
- [ ] 5.5 Verify only `proposal.md`, `spec.md`, and `tasks.md` in this bundle changed during this planning task, no active change bundle or wiki file was modified, and the bundle contains no unresolved clarification marker (path: `specs/changes/archive/20260818-global-git-author-identity/`)

## Checkpoint

- [ ] All credential, ownership, lifecycle, recovery, host-config, user-isolation, cleanup, hook-continuation, and `up` non-regression behavior remains unchanged outside the new author global write, with each spec scenario mapped to an explicit test task.

## 6. Build and suite validation

- [x] 6.1 Run `swift build` and resolve all compile or warning regressions caused by the implementation (path: `Package.swift`)
- [x] 6.2 Run `swift run adevcontainerTests` as the suite of record; confirm every spec scenario maps to a passing test and existing integration/runtime skips remain expected (path: `Tests/adevcontainerTests/main.swift`)
- [ ] 6.3 Review the final implementation diff for exact pre-hook ordering, local-first semantics, warning-only/no-recovery behavior, connection-user isolation, untouched credential/[DIAG] behavior, explicit clone/rebuild cleanup and recovery regressions, and no edits outside the new spec bundle during this planning task (path: `specs/changes/archive/20260818-global-git-author-identity/`)

## Checkpoint

- [ ] Build and the full suite pass, the bundle is analyze-ready with zero unresolved clarification markers, every requirement/scenario has concrete test coverage, and no implementation has been performed in this planning task.
