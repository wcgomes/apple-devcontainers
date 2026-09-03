# Tasks: workspace-parents-writable

Test-first ordering: each phase writes failing tests first and confirms the failure, then implements. `[P]` marks parallelizable items. Suite of record: `swift run adevcontainerTests` (integration suites skip on Linux).

## 1. Parents-only mode — unit tests (fail first)

- [x] 1.1 Write unit tests for the parents-only scope: script contains `mkdir -p` + non-recursive `chown` of ancestors only; no `chown -R`; no `chown` of the workspace folder itself; nested `/workspaces/a/b/c` walk; break-list stop (`/home/alice/ws` → `/home/alice` chowned, `/home` not); workspace directly under a break-list entry (`/opt/tool` → no ancestor chown, no failure); root/unset user no-op (no exec); exec failure propagates the ownership CLIError (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 Confirm the new tests fail (parents-only API does not exist yet)

### Checkpoint

- [x] New unit tests fail as expected (red)

## 2. Implement parents-only mode

- [x] 2.1 Add a scope parameter (default = current target+parents behavior) to `ensurePathsWritableByRemoteUser` and the `ensureWorkspaceParentsWritableByRemoteUser` convenience (path: `Sources/ADevContainerLib/Commands/WorkspaceOwnership.swift`)
- [x] 2.2 Unit tests from phase 1 pass and existing WorkspaceOwnership unit tests still pass with the default scope

### Checkpoint

- [x] Unit scenarios green: break-list stop; nested workspaceFolder; root/unset no-op; bind target never chowned

## 3. Up bind create — test-first

- [x] 3.1 Write failing command tests: `up` fresh create with non-root user runs exactly one parents-only exec (no `chown -R`, no chown of the bind target) after start and before any hook exec; root user → no exec; parents exec failure → structured error, container deleted, failure eligible for bring-up recovery; reuse and start-stopped run no parents exec (path: `Tests/adevcontainerTests/AllCommandTests.swift`) [P with 4.1]
- [x] 3.2 Implement: call `ensureWorkspaceParentsWritableByRemoteUser` in the UpCommand create path after the named-volume block and before create-path hooks; failure → delete the created container + `BringUpRecovery.eligible` (mirror UpCommand.swift:429-440) (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`) [P with 4.2]
- [x] 3.3 Extend the existing up assertions: exactly-one-`chown -R` count stays true and the parents-only exec is asserted (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

### Checkpoint

- [x] Up scenarios green: up bind fresh create fixes parents before hooks; up bind never chowns the host bind target; root/unset no-op; up reuse and start-stopped do not run the parent fix-up; up parent fix-up failure deletes and stays recovery-eligible

## 4. Rebuild both modes — test-first

- [x] 4.1 Write failing command tests: bind rebuild runs a parents-only exec before hooks and never chowns the target; volume rebuild with connection user == stamped runs a parents-only exec while the recursive workspace chown does NOT run; parents exec failure → warning + continue + rebuild success (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`) [P with 3.1]
- [x] 4.2 Implement: call `ensureWorkspaceParentsWritableByRemoteUser` in RebuildCommand after start and before create-path hooks, both modes, unconditional; failure → stderr warning + continue (mirror RebuildCommand.swift:643-655) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`) [P with 3.2]
- [x] 4.3 Narrow the existing unchanged-user assertion from "no chown exec at all" to "no recursive workspace chown"; keep the changed-user and bind assertions intact (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)

### Checkpoint

- [x] Rebuild scenarios green: rebuild bind fixes parents before hooks and never chowns the target; rebuild volume fixes parents even when the connection user is unchanged; rebuild parent fix-up failure warns and continues

## 5. Clone regression guard

- [x] 5.1 Add regression tests: clone workspace chown script includes the non-recursive `/workspaces` parent chown (parents writable before populate/hooks); no second fix-up exec on clone; workspace-folder chown failure deletes container + `*-ws` volume and stays recovery-eligible (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`) [P with 3 and 4]
- [x] 5.2 Confirm the regression tests pass against current behavior (guard only; no clone implementation change)

### Checkpoint

- [x] Clone scenarios green: clone achieves parents via the existing workspace chown (regression); clone parent outcome failure keeps existing throwing semantics

## 6. Chown-filter audit

- [x] 6.1 Update up tests that filter mock execs by "chown" for the extra parents-only exec (path: `Tests/adevcontainerTests/AllCommandTests.swift`) [P with 4/5]
- [x] 6.2 Update rebuild phase tests that filter mock execs by "chown" for the extra parents-only exec (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`) [P with 4/5]
- [x] 6.3 Audit the chown-mock filter in recovery tests and extend for the parents-only exec (path: `Tests/adevcontainerTests/UpCommandRecoveryTests.swift`) [P with 4/5]

### Checkpoint

- [x] No test asserts an absolute "no chown exec" that the parents-only exec now legitimately violates

## 7. Full validation

- [x] 7.1 `swift build` clean
- [x] 7.2 `swift run adevcontainerTests` — full suite of record green (integration suites skip on Linux)

### Checkpoint

- [x] Every spec scenario maps to a passing test; no `[NEEDS CLARIFICATION]` markers remain in the bundle
