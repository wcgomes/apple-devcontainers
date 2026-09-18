# Tasks: feature-entrypoint-keep-alive

Spec ref: `specs/changes/feature-entrypoint-keep-alive/`
Base contract: union of `specs/<domain>.md`
Binary: `adevcontainer`
Library: `Sources/ADevContainerLib/`
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. No network / real `container` required for default suite. Do not bump `DerivedImageTag.recipeVersion`. Do not emit Dockerfile `ENTRYPOINT`. Do not apply Feature entrypoints to ownership/recovery helper creates. Do not treat entrypoint as a lifecycle hook. Do not edit `specs/changes/install-plugin-command/`. Do not archive or fold domain specs in this task set.

## 1. Parse Feature metadata entrypoint (failing tests)

- [x] 1.1 Write failing tests: `devcontainer-feature.json` `entrypoint` string parses; absent, empty, and whitespace-only contribute no value (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 Write failing tests: non-string `entrypoint` (number, boolean, array, object, null) fails closed with structured Feature metadata error naming the feature ref and `entrypoint` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — parse tests red

- [x] verify **non-string Feature entrypoint fails closed** encoded as a failing test
- [x] verify empty/absent/whitespace parse coverage for **empty or absent entrypoint keeps sleep-only create argv** / **empty Feature entrypoint contributes nothing**

---

## 2. Merge collect (failing tests)

- [x] 2.1 Write failing tests: collect non-empty Feature `entrypoint` strings in install order; skip omitted/empty; do not require image-label `entrypoint` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 2.2 Write failing tests: Feature `entrypoint` is not appended to feature onCreate / updateContent / postCreate / postStart / postAttach lists (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — merge tests red

- [x] verify **Feature entrypoint is collected in install order**
- [x] verify **empty Feature entrypoint contributes nothing**
- [x] verify **Feature entrypoint is not merged as a lifecycle hook**

---

## 3. Main create argv wrap (failing tests)

- [x] 3.1 Write failing tests: empty Feature entrypoint list → create argv is `--entrypoint /bin/sleep`, image, `infinity` (no `/bin/sh -c` wrap) (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.2 Write failing tests: one non-empty Feature entrypoint → `--entrypoint /bin/sh`, image, `-c`, that line, then `exec /bin/sleep infinity` as final PID 1 (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.3 Write failing tests: two install-ordered entrypoints appear as separate `-c` script lines (A then B); Feature lines are not `exec`-prefixed; only keep-alive is `exec /bin/sleep infinity` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.4 Write failing tests: `${devcontainerId}` in a Feature entrypoint expands with the existing deferred create-time substitution (expanded stem in `-c` script; no leftover token) (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.5 Write failing tests: image Dockerfile `ENTRYPOINT`/`CMD` are not used as create PID 1 with or without Feature entrypoints (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — wrap tests red on new behavior

- [x] verify **empty or absent entrypoint keeps sleep-only create argv**
- [x] verify **single Feature entrypoint wraps then keep-alive**
- [x] verify **multiple Feature entrypoints run as separate lines in install order**
- [x] verify **wrapper does not exec Feature entrypoint lines**
- [x] verify **devcontainerId in Feature entrypoint expands at create**
- [x] verify **image Dockerfile ENTRYPOINT and CMD stay discarded**

---

## 4. Helpers and non-goal regressions (lock tests)

Regression locks: expect pass before wrap exists, and still pass after. Ownership helper lock in 4.2 MUST include a main create that would wrap (non-empty Feature `entrypoint`) so the helper cannot silently inherit wrap argv later.

- [x] 4.1 Write tests: recovery helper create argv stays `--entrypoint /bin/sleep` and `infinity` with no Feature wrap [P] (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 4.2 Write tests: ownership helper create argv stays `--entrypoint /bin/sleep` and `infinity` when the main container would wrap Feature entrypoints [P] (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 4.3 Write tests: Features install Dockerfile has no `ENTRYPOINT`; product `DerivedImageTag.recipeVersion` equals the pre-change constant (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 4.4 Write tests: `overrideCommand: true` remains silent; `overrideCommand: false` remains blocked; neither selects wrap by itself (path: `Tests/adevcontainerTests/CompatibilityPolicyTests.swift`)
- [x] 4.5 Write tests: `runArgs --entrypoint` remains rejected (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 4.6 Write tests: start/resume does not exec Feature `entrypoint` as a remelted lifecycle hook (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — helper and non-goal tests encoded

- [x] verify **ownership helper create stays sleep-only**
- [x] verify **recovery helper create stays sleep-only**
- [x] verify **Features Dockerfile has no ENTRYPOINT and recipeVersion is unchanged**
- [x] verify **overrideCommand policy is unchanged**
- [x] verify **runArgs entrypoint remains rejected**
- [x] verify **start does not remelt Feature entrypoint via exec**

---

## 5. Implement parse

- [x] 5.1 Parse Feature metadata `entrypoint` as string; treat absent/empty/whitespace as no contribution; non-string throws structured `feature_metadata` naming the ref and `entrypoint` (path: `Sources/ADevContainerLib/Features/FeatureMetadata.swift`)
- [x] 5.2 Make tests from §1 green (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — parse green

- [x] verify **non-string Feature entrypoint fails closed**
- [x] verify empty/absent/whitespace parse

---

## 6. Implement merge

- [x] 6.1 Carry collected Feature entrypoint strings on contributions (install order; skip empty; do not copy into lifecycle hook arrays) (path: `Sources/ADevContainerLib/Features/FeatureContributionMerge.swift`)
- [x] 6.2 Persist merged Feature entrypoints on the resolved config (not as lifecycle hook fields) (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 6.3 Make tests from §2 green (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — merge green

- [x] verify **Feature entrypoint is collected in install order**
- [x] verify **empty Feature entrypoint contributes nothing**
- [x] verify **Feature entrypoint is not merged as a lifecycle hook**

---

## 7. Implement main create wrap and substitution

- [x] 7.1 Expand `${devcontainerId}` in Feature entrypoint strings with the existing deferred create-time path used for mounts/`containerEnv` (path: `Sources/ADevContainerLib/Config/VariableSubstitutor.swift`)
- [x] 7.2 Main create argv: empty list → `--entrypoint /bin/sleep` image `infinity`; non-empty → `--entrypoint /bin/sh` image `-c` with each entrypoint as its own line then `exec /bin/sleep infinity`; do not `exec` Feature lines; wire `from` / `fromVolumeMode` from resolved config (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift`)
- [x] 7.3 Make tests from §3 green (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — wrap green

- [x] verify **empty or absent entrypoint keeps sleep-only create argv**
- [x] verify **single Feature entrypoint wraps then keep-alive**
- [x] verify **multiple Feature entrypoints run as separate lines in install order**
- [x] verify **wrapper does not exec Feature entrypoint lines**
- [x] verify **devcontainerId in Feature entrypoint expands at create**
- [x] verify **image Dockerfile ENTRYPOINT and CMD stay discarded**

---

## 8. Keep helpers sleep-only (no Feature wrap)

- [x] 8.1 Keep recovery helper `CreateRequest` on the empty Feature entrypoint list (sleep-only argv) (path: `Sources/ADevContainerLib/Commands/RecoveryHelper.swift`)
- [x] 8.2 Keep ownership helper `CreateRequest` on the empty Feature entrypoint list (sleep-only argv) (path: `Sources/ADevContainerLib/Commands/WorkspaceOwnership.swift`)
- [x] 8.3 Make recovery helper tests from §4 green (path: `Tests/adevcontainerTests/RecoveryHelperTests.swift`)
- [x] 8.4 Make ownership helper tests from §4 green (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint — helpers green

- [x] verify **recovery helper create stays sleep-only**
- [x] verify **ownership helper create stays sleep-only**

---

## 9. Suite / regression gate

- [x] 9.1 Confirm Features Dockerfile generation still emits no `ENTRYPOINT` and `DerivedImageTag.recipeVersion` is unchanged (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`)
- [x] 9.2 Grep regression: Feature `entrypoint` is not copied into lifecycle hook arrays; helpers do not pass Feature entrypoints into create; `runArgs --entrypoint` still rejected (path: `Sources/ADevContainerLib/`)
- [x] 9.3 Run full default suite `swift run adevcontainerTests`; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 9.4 Domain fold + archive are **out of this task set**. Do not move this folder to `specs/changes/archive/` here.

## Checkpoint — initial land done

- [x] verify every scenario in change `spec.md` is covered
- [x] verify default `swift run adevcontainerTests` green
- [ ] verify Non-goals respected (no SSH special-case, no `overrideCommand: false` support, no image ENTRYPOINT/CMD, no Dockerfile ENTRYPOINT, no `recipeVersion` bump, no postStart remelt/exec, no helper wrap, no `clone --ssh`, no `runArgs --entrypoint`, no wiki/archive, no edits to `install-plugin-command`, no workspace `.devcontainer` sshd/postStart local test edits)
