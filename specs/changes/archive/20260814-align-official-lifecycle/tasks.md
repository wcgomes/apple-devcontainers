# Tasks: align-official-lifecycle

Spec ref: `specs/changes/align-official-lifecycle/`  
Base contract: union of `specs/<domain>.md` plus active `specs/changes/vscode-customizations-up-clone-rebuild/spec.md` and this change’s `spec.md` (this change supersedes that delta’s start hook lock and `--vscode`-gated postAttach rows; it does **not** supersede “`start` MUST NOT apply vscode customizations”)  
Tests: `Tests/adevcontainerTests/` (MiniTest; `swift run adevcontainerTests`)  
Package root: repository root

Test-first: write or flip the test, confirm it fails, then implement. Mock runtime/guest/open so the default suite needs no real container or VS Code. Keep string → `sh -lc` and argv-without-shell. Do **not** apply vscode settings/extensions on `start`. Do **not** add cloud `updateContent`, Compose, an IDE attach listener, or last-window-close auto-stop.

## 1. Failing tests — admit official keys

- [x] 1.1 Flip `unknownPropertyFails` off `shutdownAction` (use a truly unknown key). Add admit + resolve tests: valid `initializeCommand` (string / argv / object-map; empty object-map → nil), `waitFor` enum + omitted default `updateContentCommand`, `userEnvProbe` enum + omitted default `loginInteractiveShell`, `shutdownAction` `stopContainer` / omitted default `stopContainer` / `none`. Unknown `waitFor` / `userEnvProbe` / `shutdownAction` and invalid `initializeCommand` form fail resolve with a structured error naming that property. `stopCompose` fails closed (Compose unsupported). Combined core + lifecycle + allowlisted `runArgs` + `hostRequirements` must not hard-error as unknown (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint

- [x] verify **shutdownAction presence does not fail parse** encoded as a failing test (today `unknownPropertyFails` rejects it)
- [x] verify **initializeCommand waitFor userEnvProbe shutdownAction admit** encoded as a failing test
- [x] verify **Lifecycle / runArgs / hostRequirements property set does not hard-error as unknown** encoded
- [x] verify **stopCompose fails closed** encoded
- [x] verify unknown `waitFor` / `userEnvProbe` / `shutdownAction` and invalid `initializeCommand` form fail resolve naming the property
- [x] verify **Invalid postAttach form still fails resolve** remains encoded (`invalidPostAttachFormFails`)
- [x] verify **Lifecycle command forms** remains encoded (`lifecycleCommandFormsParse`)

## 2. Implement admission + resolved model

- [x] 2.1 Add `initializeCommand`, `waitFor`, `userEnvProbe`, and `shutdownAction` to the supported-key set (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [x] 2.2 [P] Add resolved fields + parse/defaults: `initializeCommand` via `LifecycleCommand.parse`; `waitFor` / `userEnvProbe` / `shutdownAction` enums with official defaults; unknown / `stopCompose` fail closed naming the property. Include `initializeCommand`, `waitFor`, and `userEnvProbe` in `hashMaterial` (omit `shutdownAction`, same spirit as postAttach). Do not change `LifecycleCommand.execArguments` shell rules (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 2.3 Wire the new keys through `buildResolved` so they are available to lifecycle paths (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)

## Checkpoint

- [x] verify **shutdownAction presence does not fail parse**
- [x] verify **initializeCommand waitFor userEnvProbe shutdownAction admit**
- [x] verify **Lifecycle / runArgs / hostRequirements property set does not hard-error as unknown**
- [x] verify **stopCompose fails closed**
- [x] verify **Lifecycle command forms** (regression)
- [x] verify **Invalid postAttach form still fails resolve** (regression)

## 3. Failing tests — object-map parallel

- [x] 3.1 Add `LifecycleRunner` tests: two named `onCreateCommand` entries that each exit 0 must overlap in flight (latch: first exec blocks until the second starts); stage succeeds only after both exit 0. Restart-path `postStartCommand` object-map with one non-zero entry fails the stage and MUST NOT delete (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint

- [x] verify **Lifecycle object-map runs in parallel** encoded as a failing test (today `runIfPresent` is sequential sorted-by-name)
- [x] verify **Lifecycle object-map stage fails if any entry fails** encoded as a failing test

## 4. Implement parallel object-map

- [x] 4.1 Run `.parallel` named entries concurrently; stage succeeds only if every entry exits 0. Keep leaf string/argv invocation unchanged. Apply the same policy to host `initializeCommand` when that runner is added (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)

## Checkpoint

- [x] verify **Lifecycle object-map runs in parallel**
- [x] verify **Lifecycle object-map stage fails if any entry fails**

## 5. Failing tests — initializeCommand host execution

- [x] 5.1 Fresh `up`: `initializeCommand` that writes a host marker (or is observed via a host-process seam) runs on the workspace **before** `create`; create-path exec order remains onCreate → updateContent → postCreate → postStart. `up` reuse of a running bind container still runs host initialize and MUST NOT exec onCreate / updateContent / postCreate / postStart. `up` start-stopped runs host initialize then postStart only. Failing initialize on a missing container fails naming `initializeCommand` and MUST NOT `create` (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 5.2 [P] Bind `start` of a stopped container with stamped `local_folder` runs host initialize **before** runtime `start`; already-running `start` does not. Failing initialize on a stopped container fails naming `initializeCommand` and leaves it stopped (no `start` call) (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 5.3 [P] Volume-mode `start` with no usable host workspace skips initialize, warns that the host command cannot run, and still starts. Clone with `initializeCommand` runs it on the config-fetch / retained-checkout host directory before create (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 5.4 [P] Rebuild create-path runs host initialize on the stamped / retained host path **before** creating the new container; first create-path hook failure still deletes only the new container (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)

## Checkpoint

- [x] verify **up runs initializeCommand on the host before create** encoded as a failing test
- [x] verify **clone runs initializeCommand on the host checkout** encoded as a failing test
- [x] verify **real bind start runs initializeCommand from stamped host path** encoded as a failing test
- [x] verify **volume-mode start without host workspace skips initializeCommand** encoded as a failing test
- [x] verify **already-running start does not run initializeCommand** encoded as a failing test
- [x] verify **up reuse still runs initializeCommand on the host** encoded as a failing test
- [x] verify **initializeCommand failure blocks create** encoded as a failing test
- [x] verify **initializeCommand failure leaves a stopped container stopped** encoded as a failing test
- [x] verify **rebuild hook matrix row applies** includes host initialize before the new container’s create-path hooks

## 6. Implement initializeCommand

- [x] 6.1 Add a host-only initialize runner (cwd = host workspace; string/`argv`/object-map; object-map concurrent; failure → structured error naming `initializeCommand`; not delete-on-fail). Inject a `ProcessRunning` seam so tests do not need a live shell side effect. Skip + warn when the caller reports no usable host workspace (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)
- [x] 6.2 Run host initialize at the start of `up` (fresh, reuse, start-stopped) when `resolved.workspacePath` exists; on initialize failure do not `create`, and on reuse do not stop/delete the running container (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 6.3 [P] Run host initialize on the config-fetch or retained-checkout directory before create when that host path exists (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 6.4 [P] Run host initialize on the stamped bind folder or retained clone checkout before creating the new container (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 6.5 [P] On a real start, load config from labels (hooks/open/postAttach only — never settings/extensions). Run host initialize from stamped `local_folder` / config **before** `runtime.start` when a host workspace exists; volume-mode with no host path skips + warns. Already-running MUST NOT run initialize. Initialize failure MUST NOT start the stopped container (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)

## Checkpoint

- [x] verify **up runs initializeCommand on the host before create**
- [x] verify **clone runs initializeCommand on the host checkout**
- [x] verify **real bind start runs initializeCommand from stamped host path**
- [x] verify **volume-mode start without host workspace skips initializeCommand**
- [x] verify **already-running start does not run initializeCommand**
- [x] verify **up reuse still runs initializeCommand on the host**
- [x] verify **initializeCommand failure blocks create**
- [x] verify **initializeCommand failure leaves a stopped container stopped**
- [x] verify **Fresh create runs full hook order** (initialize on host, then onCreate → updateContent → postCreate → postStart)
- [x] verify **rebuild hook matrix row applies**

## 7. Failing tests — waitFor readiness

- [x] 7.1 Default (omitted) `waitFor`: capture Ready on stderr after `updateContentCommand` succeeds and **before** `postCreateCommand`’s exec returns (latch the postCreate handler). `waitFor` `postCreateCommand` MUST NOT emit Ready / open / postAttach until postCreate finishes; postStart is still initiated after postCreate. `--json`: success JSON MUST NOT appear before updateContent succeeds and MAY appear before postCreate finishes; process must not return 0 until remaining hooks succeed. After Ready, a failing postCreate still exits non-zero and deletes the new container. Resume (`up` start-stopped and `start`) with default `waitFor` MUST NOT block Ready / open / postAttach on onCreate / updateContent / postCreate; this invocation’s postStart still runs (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint

- [x] verify **default waitFor allows Ready before postCreate** encoded as a failing test
- [x] verify **waitFor postCreateCommand delays Ready until postCreate** encoded as a failing test
- [x] verify **success JSON waits for waitFor not for later hooks** encoded as a failing test
- [x] verify **background create-path hook failure still deletes** encoded as a failing test
- [x] verify **resume does not re-wait create-path waitFor** encoded as a failing test

## 8. Implement waitFor

- [x] 8.1 Split create-path so Ready / optional open / postAttach can run once the named stage inclusive has succeeded, while later create-path hooks continue. Process still waits for remaining hooks before returning so delete-on-fail and the exit code stay correct. First-create postStart still starts after postCreate even when `waitFor` is `updateContentCommand`. Resume treats create-path stages as already satisfied; only `waitFor` `postStartCommand` waits on this invocation’s postStart. Restart-class failure MUST NOT delete (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)
- [x] 8.2 Emit Ready (and, when `--json`, success JSON) at the waitFor point from the command path — `AdevcontainerMain` currently prints JSON only after `UpCommand.run` returns; do not wait until process exit to emit, and do not emit a later success JSON if a background hook then fails. Open MAY happen after waitFor and MUST NOT wait for later background hooks solely to open (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 8.3 [P] Apply the same waitFor / Ready / JSON / open / postAttach split on clone fresh create (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 8.4 [P] Apply the same waitFor / Ready / JSON / open / postAttach split on rebuild’s new-container create-path (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 8.5 [P] Resume `start`: do not re-wait create-path `waitFor`; if `waitFor` is `postStartCommand`, hold Ready / open / postAttach until this start’s postStart finishes (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)

## Checkpoint

- [x] verify **default waitFor allows Ready before postCreate**
- [x] verify **waitFor postCreateCommand delays Ready until postCreate**
- [x] verify **success JSON waits for waitFor not for later hooks**
- [x] verify **background create-path hook failure still deletes**
- [x] verify **resume does not re-wait create-path waitFor**
- [x] verify **Create-path hook failure deletes container** (regression, including first-create postStart)
- [x] verify **Create then reuse** still emits success JSON with `containerId` and `remoteWorkspaceFolder`

## 9. Failing tests — userEnvProbe

- [x] 9.1 Omitted `userEnvProbe`: mock the remote user’s login-interactive probe to export a recognizable variable; `postCreateCommand` exec and a following `adevcontainer exec` both see it merged. `userEnvProbe` `none` performs no probe exec and does not fail. Probe exec uses `remoteUser` `alice`, not `containerUser` `bob`. Probe failure exits non-zero naming `userEnvProbe` and MUST NOT `delete` (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint

- [x] verify **default probe merges into postCreate and exec** encoded as a failing test
- [x] verify **none skips probe** encoded as a failing test
- [x] verify **probe uses remote connection user not containerUser** encoded as a failing test
- [x] verify **probe failure keeps the container** encoded as a failing test
- [x] verify **exec is not attach** encoded (exec MUST NOT run `postAttachCommand`)

## 10. Implement userEnvProbe

- [x] 10.1 After the container is running and before the first in-container lifecycle exec of that invocation, probe the remote connection user’s shell when `userEnvProbe` is not `none`; merge probed variables into subsequent lifecycle exec env. `none` skips. Probe failure → structured error naming `userEnvProbe`, keep container (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)
- [x] 10.2 [P] Before injecting `adevcontainer exec`, probe (unless `none`) and merge into that exec’s env. Exec is not attach — do not run postAttach (path: `Sources/ADevContainerLib/Commands/ExecCommand.swift`)

## Checkpoint

- [x] verify **default probe merges into postCreate and exec**
- [x] verify **none skips probe**
- [x] verify **probe uses remote connection user not containerUser**
- [x] verify **probe failure keeps the container**
- [x] verify **exec is not attach**

## 11. Failing tests — shutdownAction stop behavior

- [x] 11.1 `shutdownAction` `stopContainer` or omitted: `adevcontainer stop` still stops. `shutdownAction` `none`: explicit `stop` still stops (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint

- [x] verify **stopContainer config still stops on stop** encoded (may already pass once admit lands; keep as regression)
- [x] verify **none does not disable explicit stop** encoded as a failing-or-regression test

## 12. Implement shutdownAction stop behavior

- [x] 12.1 Keep explicit `stop` stopping the managed container regardless of `shutdownAction` `stopContainer` / omitted / `none`. Do not claim last-window-close auto-stop (path: `Sources/ADevContainerLib/Commands/StopCommand.swift`)

## Checkpoint

- [x] verify **stopContainer config still stops on stop**
- [x] verify **none does not disable explicit stop**

## 13. Failing tests — start postStart + feature remelt

- [x] 13.1 Flip `startStoppedManagedNoHooks`: volume-mode real start with config `postStartCommand` (and remeltable feature postStart via image `devcontainer.metadata`) MUST exec config then feature postStart; MUST NOT exec onCreate / updateContent / postCreate; MUST NOT `create`. Keep `startAlreadyRunningNoOp` (no `start`, no initialize, no postStart). Keep picker coverage (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 13.2 [P] Bind `start` of a stopped container runs config `postStartCommand` after runtime start. Already-running `start` does not run postStart. Restart postStart non-zero fails `start` and MUST NOT delete. `start` still MUST NOT apply settings/extensions (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 13.3 [P] `up` start-stopped remelts feature postStart from image metadata (Features not re-run); onCreate / updateContent / postCreate do not run. Restart postStart failure still keeps the container (`restartPostStartFailureDoesNotDelete`) (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 13.4 [P] When `start` recovery delegates to `rebuild`, rebuild’s create-path runs postStart; StartCommand MUST NOT exec postStart again after `rebuildOverride` / `RebuildCommand.run` returns (path: `Tests/adevcontainerTests/StartCommandRecoveryTests.swift`)
- [x] 13.5 [P] `PostAttachConfigLoader` / metadata remelt populates `featurePostStartCommands` the same way it already remelts postAttach (`configReaderTests` metadata case) (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)

## Checkpoint

- [x] verify **Volume-mode start runs postStart** encoded (replaces **Volume-mode start runs no hooks**)
- [x] verify **volume-mode start remelts feature postStart** encoded as a failing test
- [x] verify **Bind-mode start runs postStart** encoded as a failing test
- [x] verify **up start-stopped remelts feature postStart** encoded as a failing test
- [x] verify **Feature postStart remelts on start** encoded as a failing test
- [x] verify **start recovery via rebuild does not double-run postStart** encoded as a failing test
- [x] verify **Start stopped managed container** / **Start already running is no-op success** / **Start interactive picker when multiple** remain encoded
- [x] verify **start does not apply vscode customizations** remains encoded
- [x] verify **Start stopped runs postStart on up** / **Restart postStart failure does not delete container** remain encoded

## 14. Implement start postStart + feature remelt

- [x] 14.1 Remelt feature `postStart` (not only postAttach) from image/container `devcontainer.metadata` into `featurePostStartCommands` on resume loads (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`)
- [x] 14.2 After a successful real start: remelt feature postStart, run config then feature postStart (`failKeepContainer`), then postAttach per the CLI-attach gate. Already-running: no initialize / postStart. Recovery that delegates to rebuild returns without a second postStart. Config load remains hooks/open/postAttach only — never settings/extensions apply (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 14.3 [P] On `up` start-stopped, remelt feature postStart into the reuse config before `runRestartPostStart` (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)

## Checkpoint

- [x] verify **Volume-mode start runs postStart**
- [x] verify **volume-mode start remelts feature postStart**
- [x] verify **Bind-mode start runs postStart**
- [x] verify **up start-stopped remelts feature postStart**
- [x] verify **Feature postStart remelts on start**
- [x] verify **start recovery via rebuild does not double-run postStart**
- [x] verify **Start stopped managed container**
- [x] verify **Start already running is no-op success** (no initialize, no postStart)
- [x] verify **Start interactive picker when multiple**
- [x] verify **start does not apply vscode customizations**
- [x] verify **Start stopped runs postStart on up**
- [x] verify **Restart postStart failure does not delete container**
- [x] verify **Reuse running skips create-path and postStart** (initialize + postAttach still allowed)
- [x] verify **Create then reuse still stable with hooks**
- [x] verify **Feature lifecycle hooks run on fresh create via exec** (regression)

## 15. Failing tests — postAttach CLI attach

- [x] 15.1 Flip `upPostAttachSkippedWithoutVSCode`, `upPostAttachSkippedWhenOpenSoftFails`, and `postAttachAdmittedButNotRunOnUp`: CLI-attach `up` runs postAttach after waitFor even without `--vscode`; open soft-fail MUST NOT skip; absent postAttach emits no skip line (`upNoPostAttachWhenAbsent`). Flip real-start `startPostAttachSkippedWithoutVSCode` / `startPostAttachSkippedWhenOpenSoftFails` to **run** postAttach. Add already-running `start` without successful `--vscode` open: skip + one status line; already-running `start --vscode` success: postAttach after open, no initialize / postStart; already-running open soft-fail: success, warn, no postAttach. Keep fail-keep / no success JSON. Feature postAttach after config. CLI-attach postAttach exec uses `remoteUser` `alice`, not `containerUser` `bob` (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 15.2 [P] Flip `startPostAttachSkippedWithoutVSCode` the same way (real start runs postAttach; still no settings/extensions). Keep `startWithVSCodeOpensWithoutApplyingCustomizations` and already-running `startWithoutVSCodeDoesNotInstallExtensions` (no postStart / postAttach on already-running without open) (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 15.3 [P] Flip rebuild-without-`--vscode` and rebuild-open-soft-fail so postAttach **runs** (CLI attach). Keep postAttach failure fail-keep on the new container / no recovery session. Rebuild `--vscode` success still runs postAttach after open (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 15.4 [P] Clone without `--vscode` runs postAttach after waitFor; clone open soft-fail still runs postAttach; temp cleanup and create-path hook delete-container+volume unchanged (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)

## Checkpoint

- [x] verify **postAttach runs at end of up without --vscode** encoded as a failing test
- [x] verify **up without --vscode still runs postAttach** encoded as a failing test
- [x] verify **postAttach runs after real start without --vscode** encoded as a failing test
- [x] verify **already-running start skips postAttach without successful open** remains encoded (move off the real-start fixtures)
- [x] verify **already-running start runs postAttach after successful --vscode open** encoded
- [x] verify **open soft-fail does not suppress CLI-attach postAttach** encoded as a failing test
- [x] verify **postAttach still runs after successful --vscode open on CLI-attach paths** remains encoded
- [x] verify **postAttach failure fails command but keeps container** remains encoded
- [x] verify **feature postAttach runs on CLI attach** encoded
- [x] verify **no skip line when postAttach absent** remains encoded
- [x] verify **clone runs postAttach without --vscode** encoded as a failing test
- [x] verify **soft-fail when code CLI missing on CLI-attach path** encoded as a failing test
- [x] verify **soft-fail when launch fails on already-running start** encoded

## 16. Implement postAttach CLI attach

- [x] 16.1 Replace the open-only gate: CLI-attach paths (`up` / `clone` / `rebuild` / real `start`) run config then feature postAttach after waitFor; `--vscode` open (success or soft-fail) MUST NOT skip. Already-running `start`: run only after successful open; otherwise one skip status when postAttach is present; no skip line when absent. Soft-fail open on already-running MUST NOT execute postAttach. Failure: fail-keep, no success JSON (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`)
- [x] 16.2 [P] Treat every `up` finish path (fresh, reuse, start-stopped) as CLI attach for postAttach (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 16.3 [P] Treat successful clone as CLI attach for postAttach (not `--vscode`-gated) (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 16.4 [P] Treat rebuild’s new container as CLI attach for postAttach; non-zero postAttach keeps the new container and MUST NOT start recovery (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 16.5 [P] Real start: postAttach after postStart (waitFor-aware) even without `--vscode`; already-running only after successful open. Still never apply settings/extensions (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)

## Checkpoint

- [x] verify **postAttach runs at end of up without --vscode**
- [x] verify **up without --vscode still runs postAttach**
- [x] verify **postAttach runs after real start without --vscode**
- [x] verify **already-running start skips postAttach without successful open**
- [x] verify **already-running start runs postAttach after successful --vscode open**
- [x] verify **open soft-fail does not suppress CLI-attach postAttach**
- [x] verify **postAttach still runs after successful --vscode open on CLI-attach paths**
- [x] verify **postAttach failure fails command but keeps container**
- [x] verify **feature postAttach runs on CLI attach**
- [x] verify **no skip line when postAttach absent**
- [x] verify **postAttach runs as remote connection user not containerUser**
- [x] verify **clone runs postAttach without --vscode**
- [x] verify **--vscode still only gates open not apply on up**
- [x] verify **--vscode on already-running start opens without applying customizations**
- [x] verify **without --vscode behavior unchanged for open**
- [x] verify **soft-fail when code CLI missing on CLI-attach path**
- [x] verify **soft-fail when launch fails on already-running start**

## 17. Help and remaining matrix

- [x] 17.1 Rewrite usage + `up` / `start` / `clone` / `rebuild` help: `start` runs initialize (when a host workspace exists) + postStart + remelted feature postStart on a real start; already-running is a no-op for those hooks; `start` still does not apply settings/extensions; `--vscode` is best-effort open (and postAttach only for already-running `start`); postAttach is CLI attach on `up` / `clone` / `rebuild` / real `start`. MUST NOT claim full Dev Containers extension parity or last-window-close auto-stop (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)
- [x] 17.2 [P] Extend `usageAndCommandHelpDoNotGateApplyOnVSCode` so help no longer says start does not run postStart or that postAttach runs only after successful open / is `--vscode`-gated, while start still MUST say it does not apply settings or extensions (path: `Tests/adevcontainerTests/VSCodeCustomizationsCommandTests.swift`)
- [x] 17.3 [P] Confirm existing clone populate-hook order, temp cleanup, and hook-failure delete container+volume still pass with initialize + waitFor + ungated postAttach (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)

## Checkpoint

- [x] verify **Create-path hooks run after populate**
- [x] verify **Temp dirs always cleaned up**
- [x] verify **Hook failure deletes container and workspace volume**
- [x] verify **Running container is attachable target**
- [x] verify **Optional open does not replace manual attach** (docs MUST NOT claim full extension parity)
- [x] verify help no longer says `start` skips postStart or that postAttach is `--vscode`-only
- [x] verify **start does not apply vscode customizations** still stated in help

## 18. Failing tests — volume-mode rebuild initialize without host workspace

- [x] 18.1 Volume-mode / clone-origin `rebuild` with no usable host workspace: `initializeCommand` of the form `bash .devcontainer/…` runs on the host; cwd is a temporary workspace root that contains the guest `.devcontainer/` directory; initialize runs before the old container is deleted and before the new container is created; after success the temp root is gone; success MUST NOT depend on other guest paths such as `./scripts/…` being on the host (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 18.2 [P] Guest config is root `.devcontainer.json` with no `.devcontainer/` directory (host-global `initializeCommand`): hook still runs (MUST NOT skip); temp root contains that json. `initializeCommand` non-zero: fail naming `initializeCommand`, MUST NOT create the new container, old container remains, temp root is gone after failure (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 18.3 [P] Clone-origin `rebuild` with a usable retained host checkout still uses that durable cwd (not a temp root created solely for the hook). Volume-mode `start` with no usable host workspace still skips initialize + warns (do not flip) (paths: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`, `Tests/adevcontainerTests/CloneInVolumeTests.swift`)

## Checkpoint

- [x] verify **volume-mode rebuild without host workspace still runs initializeCommand** encoded as a failing test
- [x] verify **volume-mode rebuild initialize temp is removed after failure** encoded as a failing test
- [x] verify **missing .devcontainer directory does not skip initializeCommand on volume rebuild** encoded as a failing test
- [x] verify **volume-mode rebuild initialize is not a full workspace checkout** encoded as a failing test
- [x] verify **volume-mode rebuild with a retained host checkout uses that path** encoded as a failing test
- [x] verify **volume-mode start without host workspace skips initializeCommand** remains encoded

## 19. Implement volume-mode rebuild initialize staging

- [x] 19.1 On volume-mode / clone-origin `rebuild`, when `initializeCommand` is present and no usable host workspace exists: after guest files are already readable for config read, place the current guest `.devcontainer/` directory (and root `.devcontainer.json` if that is the config) onto a host temporary workspace root; run host initialize with that cwd; remove the temp after the hook (success or fail; removal failure warns only). Missing `.devcontainer` MUST NOT skip. Do not materialize the rest of the guest workspace. Do not re-fetch git. Do not rely on Apple `container cp` of named volumes. Failure MUST NOT create the new container and MUST leave the old container in place (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 19.2 [P] Keep volume-mode `start` skip+warn (do not start solely to obtain guest files). Keep durable host workspace cwd when a usable stamped / retained path exists (paths: `Sources/ADevContainerLib/Commands/StartCommand.swift`, `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint

- [x] verify **volume-mode rebuild without host workspace still runs initializeCommand**
- [x] verify **volume-mode rebuild initialize temp is removed after failure**
- [x] verify **missing .devcontainer directory does not skip initializeCommand on volume rebuild**
- [x] verify **volume-mode rebuild initialize is not a full workspace checkout**
- [x] verify **volume-mode rebuild with a retained host checkout uses that path**
- [x] verify **volume-mode start without host workspace skips initializeCommand** (regression)
- [x] verify **rebuild hook matrix row applies** (host initialize still before the new container’s create-path hooks)
- [x] verify **initializeCommand failure blocks create** still holds on this rebuild path (no new container; old remains)

## 20. Failing tests — remelt/bake holes

- [x] 20.1 Derived-image bake: Features Dockerfile `LABEL devcontainer.metadata` includes **base-image** postStart/postAttach unioned with feature hooks (not features-only). FeaturesRunner build path same (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 20.2 [P] `PostAttachConfigLoader.load` with unreadable config still remelts image metadata postStart/postAttach into a feature-only stub (no initialize, no vscode apply). `mergeFeaturePostAttach` unions apply-time hooks with remelted ones (path: `Tests/adevcontainerTests/ConfigReaderTests.swift`)
- [x] 20.3 [P] Real `start` with missing stamped config still execs metadata postStart then CLI-attach postAttach (`failKeepContainer`); MUST NOT exec onCreate / updateContent / postCreate; MUST NOT delete (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 20.4 [P] Fresh `up` with **empty features** runs image-metadata onCreate/updateContent/postCreate/postStart/postAttach. `up` finish remelt keeps apply-unioned base-image postAttach when the remelt source is features-only (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint

- [x] verify **derived-image LABEL includes base-image postStart/postAttach after Features build** encoded as a failing test
- [x] verify **start with unreadable config still runs metadata postStart** encoded as a failing test
- [x] verify **no-features up runs image-metadata postCreate/postStart** encoded as a failing test
- [x] verify **up finish still has base-image postAttach after remelt** encoded as a failing test

## 21. Implement remelt/bake union

- [x] 21.1 Bake the **unioned** contributions (base-image metadata + features) onto derived `LABEL devcontainer.metadata`; `FeatureDockerfileGenerator.write` accepts the already-unioned `contributions` from FeaturesRunner (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`, `Sources/ADevContainerLib/Features/FeaturesRunner.swift`)
- [x] 21.2 [P] On `start`, if config load is nil, still remelt container+image metadata into a feature-only stub and run feature-only postStart (`failKeepContainer`); postAttach same when the CLI-attach gate would run. Do not remelt onCreate/updateContent/postCreate on resume. Do not apply vscode customizations. `initializeCommand` stays host/config-only (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`)
- [x] 21.3 [P] Fresh `up` / `rebuild` / `clone` with **empty features** still apply base-image metadata create-path + resume hooks via `FeatureContributionMerge.applyFromImage` (paths: `Sources/ADevContainerLib/Commands/UpCommand.swift`, `Sources/ADevContainerLib/Commands/RebuildCommand.swift`, `Sources/ADevContainerLib/Commands/CloneCommand.swift`, `Sources/ADevContainerLib/Features/FeatureContributionMerge.swift`)
- [x] 21.4 [P] `up` / `rebuild` finish remelt unions remelted hooks with apply-time arrays (does not replace-away base-image postAttach). Rebuild finish passes container labels (path: `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift`, `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)

## Checkpoint

- [x] verify **derived-image LABEL includes base-image postStart/postAttach after Features build**
- [x] verify **start with unreadable config still runs metadata postStart**
- [x] verify **start with unreadable config still runs metadata postAttach on CLI attach**
- [x] verify **no-features up runs image-metadata postCreate/postStart**
- [x] verify **up finish still has base-image postAttach after remelt**
- [x] verify **volume-mode start without host workspace skips initializeCommand** (unchanged)
- [x] verify **start does not apply vscode customizations** (regression)
