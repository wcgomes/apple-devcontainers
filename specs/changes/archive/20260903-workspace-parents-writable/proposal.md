# Proposal: Workspace parents writable on create paths

## Intent

Bind-mode fresh `up` with a non-root connection user fails inside create-path lifecycle hooks: hooks exec as `config.connectionUser` (LifecycleRunner.swift:175), and in a fresh container rootfs the directories above the workspace bind mount are owned by root, so a hook that creates sibling paths fails, e.g. `fatal: could not create work tree dir '/workspaces/PlantSuite-GitOps': Permission denied` from `postCreateCommand`. Volume mode already avoids this because the existing workspace-folder chown non-recursively walks parents; bind mode performs no workspace and no parent chown at all today (UpCommand only chowns config named-volume targets). This change guarantees that on every managed create path — `up` fresh create (bind), `clone` (volume), `rebuild` replacement create (bind and volume) — the container-rootfs parent directories of the resolved workspace folder are made writable by the resolved connection user before lifecycle hooks run, while the bind-mode workspace folder (the host bind target) is never chowned.

## Scope

- Create-path guarantee: parents of the resolved container workspace folder writable by the resolved connection user before create-path hooks run, via `mkdir -p` as needed plus the existing non-recursive parent-chown walk with its system-top break list (`/`, `/home`, `/Users`, `/var`, `/usr`, `/opt`, `/tmp`, `/root`, `/etc`, `/mnt`, `/media`, `/dev`, `/proc`, `/sys`, `/run`, `/boot`, `/lib`, `/lib64`, `/bin`, `/sbin`).
- New mechanism only where today's mechanisms do not already deliver the outcome: `up` fresh create (bind) and `rebuild` replacement create (bind; and volume-mode parents on the fresh container rootfs, which is distinct from the volume data tree). `clone` (volume) is covered-by-design by the existing workspace-folder chown and its parent walk — regression scenarios and tests only, no new call.
- Per-command failure semantics: `up` — hard-fail, delete the created container, remain eligible for bring-up recovery; `rebuild` — soft-fail, warn on stderr and continue; `clone` — unchanged throwing semantics.
- DELTA: ADDED requirements in `specs/core.md` (routing rationale in Decision index (c)); no MODIFIED and no REMOVED requirements.
- Follow-up implementation and tests per `tasks.md`; suite of record is `swift run adevcontainerTests` (integration suites skip on Linux).

## Non-goals

- Never chowning the bind-mode workspace folder (host bind target) on any path, including under this change.
- Changing volume-mode recursive workspace-folder chown gating: rebuild keeps "run only when the resolved connection user differs from the stamped `devcontainer.remote_user`" (archived `20260810-rebuild` contract).
- Applying the fix-up on non-create paths: `up` reuse of a running matching container, `up` start-stopped, and bare `start` run no parent fix-up.
- Changing the break list, the named-volume chown behavior, populate, bring-up recovery flows, or the clone mechanism.
- Repairing containers created before this change on reuse/start (recorded rejected alternative in Decision index (a)).
- Wiki edits, archiving, or source-code changes in this bundle.

## Approach

Extend `WorkspaceOwnership.ensurePathsWritableByRemoteUser` (Sources/ADevContainerLib/Commands/WorkspaceOwnership.swift:57) with a parents-only scope so the single one-exec script builder and the break-list walk stay single-sourced, and add a thin convenience wrapper `ensureWorkspaceParentsWritableByRemoteUser`. Add two calls: UpCommand create path after the named-volume block and before create-path hooks (throwing → delete → `BringUpRecovery.eligible`, mirroring UpCommand.swift:429-440), and RebuildCommand after start and before create-path hooks, both modes, unconditional (soft-fail warning + continue, mirroring RebuildCommand.swift:643-655). CloneCommand gets no new call — its existing workspace chown (CloneCommand.swift:469) already walks parents in volume mode.

## Live-contract check

Read: all eight realized specs (`core.md`, `managed-lifecycle.md`, `clone.md`, `lifecycle-hooks.md`, `vscode.md`, `features.md`, `runargs-host.md`, `terminal-output.md`); the only active change delta `specs/changes/friendly-container-name/{proposal,spec}.md`; `wiki/index.md`, `wiki/architecture.md`, `wiki/conventions/cli-runtime-boundary.md` (ownership section); archived `20260810-rebuild` and `20260814-bring-up-recovery` specs. Findings:

- **friendly-container-name (only active delta):** create-name identity, occupancy, and `${devcontainerId}` routing — no ownership overlap. No conflict.
- **Realized specs:** no requirement forbids bind-mode parent chown and none currently requires it (pure gap). All-ADDED delta is sufficient; no MODIFIED needed.
- **Archived `20260810-rebuild`:** "the writable step MUST run only when the effective remoteUser differs from the stamped one … when equal, it MUST be skipped (existing tree is left as is)" constrains the recursive data-tree chown only. The new parents-only fix-up is a distinct mechanism whose walk starts above the workspace mount point and never touches the volume data tree, so the archived requirement and its scenario `volume rebuild writable step runs only when remoteUser changed` remain satisfied. This is a flagged reading, not a conflict.
- **`managed-lifecycle.md`:** the bring-up trigger set already lists `workspace-ownership`; the `up` failure semantics (throw → delete → eligible) are consistent. No change.
- **Test-level expectations (not spec text):** `RebuildCommandPhaseTests` (a)-case asserts no chown exec at all when volume user is unchanged — must be narrowed to "no recursive workspace chown" once the parents-only exec exists; `AllCommandTests` asserts exactly one `chown -R` exec on `up` (stays true — parents-only scripts contain no `chown -R`) and should be extended to assert the new exec; `UpCommandRecoveryTests` filters execs containing "chown" and needs an audit. Handled in `tasks.md` phase 6.

## Decision index

- **(a) Scope — create paths only:** the fix-up runs on `up` fresh create, `clone` (covered-by-design), and `rebuild` replacement create only; `up` reuse, `up` start-stopped, and bare `start` never run it. Rejected alternative: also running it on reuse/start-stopped would repair pre-change containers, but it would re-chown ancestors the user may have deliberately changed on every resume, add an exec per resume, and the reported failure is create-path-only; containers created after this change are fixed at create. Repair of pre-change containers on resume is a possible future change.
- **(b) Failure semantics per command:** `up` — throw → delete the created container → `BringUpRecovery.eligible` (mirrors UpCommand.swift:429-440 and is consistent with the realized `workspace-ownership` recovery trigger). `rebuild` — soft-fail: warning + continue (mirrors RebuildCommand.swift:643-655 and is consistent with archived rebuild "writable-step failures are not recovery triggers"). `clone` — no new mechanism; existing throwing semantics unchanged (CloneCommand.swift:469-485: hard-fail, delete container + `*-ws` volume, bring-up recovery eligible).
- **(c) Routing / merge target — `specs/core.md`:** the guarantee is a shared create-path invariant; core.md already owns the shared create-path contract (Up lifecycle requirements, connection-user resolution, non-empty `remote_user` stamping with cross-command clone/rebuild scenarios). `managed-lifecycle.md` owns selection/recovery and its `workspace-ownership` trigger is unchanged; `clone.md` owns volume-mode specifics whose parent outcome is already realized — clone contributes regression scenarios that merge into core.md alongside the cross-command scenarios already there. ADDED-only delta.
- **(d) Implementation shape:** extend `ensurePathsWritableByRemoteUser` with a parents-only scope parameter (default = current target+parents behavior) instead of a sibling script builder, keeping the break-list walk and one-exec-per-call builder single-sourced; add the `ensureWorkspaceParentsWritableByRemoteUser` convenience. Call sites: UpCommand create path (after the named-volume block, before create-path hooks); RebuildCommand (after start, before create-path hooks; bind and volume; **unconditional** — volume-mode parents-only also runs when the connection user is unchanged because the fresh container rootfs ancestors are root-owned again, while the archived skip-when-unchanged rule governs only the recursive data-tree chown and the parents-only walk never touches the volume tree); CloneCommand none.
- **No design.md:** the parents-only mode, the two new call sites, and the per-command failure semantics fit the decision index plus tasks.md without overflow.

## Clarifications

None — the handoff resolved all ambiguity; no `[NEEDS CLARIFICATION]` markers.
