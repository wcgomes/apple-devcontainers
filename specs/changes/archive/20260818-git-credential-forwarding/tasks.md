# Tasks: git-credential-forwarding

Test-first ordering: each phase writes failing tests first and confirms the failure, then implements. `[P]` marks parallelizable items. Suite of record: `swift run adevcontainerTests` (integration suites skip on Linux).

> **Amendment 1 (2026-08-18):** username-agnostic container-side credential helper — decision B. Appended phases 8–11 supersede the `credential.helper store` wording of phases 1–7 where it conflicts (phases 1–7 record completed work under the superseded mechanism). NOTE: temporary [DIAG] instrumentation (added 2026-08-18, present in the working tree) MUST be removed in phase 11.

## 1. Seeding helper unit tests (fail first)

- [x] 1.1 Write unit tests for `GuestGitCredentialSeed`: remote parsing from `git -C <hostWorkspace> remote -v` output (unique fetch URLs only); HTTPS-only classification (SSH remotes skipped); one fill call per unique HTTPS remote; approve entries dedupe per (protocol, host, username) and carry no path; credentials travel via environment/stdin and NEVER in argv; silent skip on empty remotes / nil fill / missing host git; volume mode seeds from a single `git_url`; error text redacts URL userinfo and credential material (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 Confirm the new tests fail (the `GuestGitCredentialSeed` API does not exist yet)

### Checkpoint

- [x] New unit tests fail as expected (red)

## 2. Implement GuestGitCredentialSeed

- [x] 2.1 Implement `GuestGitCredentialSeed`: injectable `GitCredentialProviding` (default `HostGitCredential()`) + injectable host process runner and `gitPathOverride` (mirror `HostGitClient.init` at GitClient.swift:58-64); bind mode enumerates unique HTTPS fetch URLs via `git -C <hostWorkspace> remote -v`; volume mode takes the single stamped `devcontainer.git_url`; fill per URL via the existing `fillHTTPS` contract; classify with `GitURLClassifier.httpsCredentialFields`; dedupe (protocol, host, username); emit an in-container script `git config --global credential.helper store` + `printf 'protocol=…\nhost=…\nusername=…\npassword=…\n\n' | git credential approve` per entry with secrets in env, never argv; redact failures via `HostGitClient.redactURLUserinfo` (path: `Sources/ADevContainerLib/Git/GuestGitCredentialSeed.swift`)
- [x] 2.2 Unit tests from phase 1 pass; existing unit tests still pass

### Checkpoint

- [x] Unit scenarios green: dedupe; sibling-repo coverage; silent skip (nil fill, no remotes, missing host git); SSH skipped; secrets not in argv

## 3. Up bind create — test-first

- [x] 3.1 Write failing command tests: `up` bind fresh create runs exactly one seeding exec after start (and after the ownership block) and before the first hook exec; reuse and start-stopped run no seeding exec; seeding exec failure → warning on stderr + `up` continues + success + container NOT deleted + no recovery prompt; fill nil → silent skip (no exec); missing host git → silent skip; captured argv never contains credential material (path: `Tests/adevcontainerTests/AllCommandTests.swift`) [P with 4.1]
- [x] 3.2 Implement: add `credentials: any GitCredentialProviding = HostGitCredential()` to UpCommand.run (mirror CloneCommand.swift:44) and call `GuestGitCredentialSeed` in the create path after the ownership block and before create-path hooks; failures → stderr warning + continue (soft-fail) (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`) [P with 4.2]

### Checkpoint

- [x] Up scenarios green: up bind fresh create seeds the store before hooks; sibling repos covered; duplicate remote lines dedupe; no host credentials skip silently; no repo/remotes skip silently; missing host git skips silently; seeding failure soft-fails; non-create paths never seed; secrets redacted; SSH remotes not seeded; seeding runs as the resolved connection user

## 4. Rebuild both modes — test-first

- [x] 4.1 Write failing command tests: bind rebuild seeds from host remotes before the first hook exec; volume rebuild seeds from the stamped `devcontainer.git_url` without host remote enumeration; missing/empty `git_url` → silent skip; seeding failure → warning + continue + rebuild success; no seeding on the pre-change (start) path (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`) [P with 3.1]
- [x] 4.2 Implement: add the `credentials` seam and call `GuestGitCredentialSeed` in RebuildCommand after ownership and before create-path hooks, both modes (volume source: stamped `devcontainer.git_url`); failures → stderr warning + continue (mirror the rebuild soft-fail warning at RebuildCommand.swift:643-655) (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`) [P with 3.2]

### Checkpoint

- [x] Rebuild scenarios green: rebuild bind seeds from host remotes; rebuild volume seeds from the stamped git URL; missing git_url skips silently; seeding failure soft-fails

## 5. Clone regression guard

- [x] 5.1 Add regression tests: clone populate still configures `credential.helper store` + approve before hooks via its own mechanism; no seeding exec runs on clone; existing HTTPS populate scenarios stay green (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`) [P with 3/4]
- [x] 5.2 Confirm the regression tests pass against current behavior (guard only; no clone implementation change)

### Checkpoint

- [x] Clone scenarios green: clone keeps a single populate mechanism (regression)

## 6. Exec-sequence audit

- [x] 6.1 Audit up tests that assert the full exec sequence after start for the new pre-hook seeding exec; extend exact-sequence assertions (path: `Tests/adevcontainerTests/AllCommandTests.swift`) [P with 4/5]
- [x] 6.2 Audit rebuild phase tests for exec-order assertions that the new seeding exec legitimately changes (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`) [P with 4/5]
- [x] 6.3 Audit clone tests to confirm no seeding exec is introduced on clone (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`) [P with 4/5]

### Checkpoint

- [x] No test asserts an absolute exec sequence that the seeding exec now legitimately violates

## 7. Full validation

- [x] 7.1 `swift build` clean
- [x] 7.2 `swift run adevcontainerTests` — full suite of record green (integration suites skip on Linux)

### Checkpoint

- [x] Every spec scenario maps to a passing test; no `[NEEDS CLARIFICATION]` markers remain in the bundle

## 8. Credential helper unit tests (fail first)

- [x] 8.1 Write functional unit tests that execute the GENERATED helper script via `sh` (test env is Linux), covering: get with username mismatch (returns credentials with the QUERIED username); get exact match; get no-match silent (empty output, exit 0); store write + dedupe + round-trip of raw values including `@`/`:`; scoping (unseeded host → nothing); config command shape (`--add`, absolute path); file modes 0700/0600 (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [ ] 8.2 Confirm the new tests fail (the helper script is not yet emitted by the seed)

### Checkpoint

- [ ] New helper tests fail as expected (red)

## 9. Implement the helper generator

- [x] 9.1 Implement in `GuestGitCredentialSeed` (path: `Sources/ADevContainerLib/Git/GuestGitCredentialSeed.swift` only — script generator + helper embedding; command call sites unchanged): the seed exec writes the POSIX-sh helper script (get/store/erase semantics, store file handling, modes 0700/0600, connection-user ownership) to `$HOME/.adevcontainer/git-credential-adev`, configures `git config --global --add credential.helper <absolute-path>` (append, never replace), and keeps `git credential approve` per unique (protocol, host, username) as before
- [x] 9.2 New unit tests from phase 8 pass; existing unit tests still pass

### Checkpoint

- [x] Helper unit scenarios green: username-mismatch get; exact-match get; silent no-match; store write/dedupe/round-trip; scoping; config shape; file modes

## 10. Adapt affected existing tests

- [x] 10.1 Adapt script-shape assertions that pin `credential.helper store` to the helper mechanism (script write + `--add` config; append preserves pre-existing helper entries) and adjust env/exec assertions; keep the temporary [DIAG] instrumentation in place until user verification (path: `Tests/adevcontainerTests/AllCommandTests.swift`, `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`, `Tests/adevcontainerTests/AllUnitTests.swift`, `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [ ] 10.2 `swift run adevcontainerTests` — full suite green with [DIAG] still present

### Checkpoint

- [ ] Suite green; clone regression scenarios unchanged and passing

## 11. User verification and cleanup

- [x] 11.1 User verification on a real `rebuild`: postCreateCommand clone of the sibling succeeds; `git credential fill` with the URL-forced username succeeds under hook env; helper script and store file perms (0700/0600, connection-user-owned)
- [x] 11.2 Remove ALL [DIAG] instrumentation (added 2026-08-18, present in the working tree) and revert the temporary test adaptations; `swift run adevcontainerTests` — full suite of record green

### Checkpoint

- [x] User confirmed the real-rebuild verification; no [DIAG] instrumentation remains in the working tree; every spec scenario maps to a passing test
