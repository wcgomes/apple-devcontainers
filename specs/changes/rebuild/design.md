# Design: rebuild

Lean HOW for the forced-recreate command. Outcome contract lives in `spec.md`; this file encodes the two-phase ordering, the shared strict config reader, and the volume-preserving create path so implementers do not invent a second read or delete policy.

## Approach

`RebuildCommand` is a hybrid of `StartCommand` (selection), `PostAttachConfigLoader` (dual-mode config read), and `UpCommand`/`CloneCommand` (create path). It runs in two phases split at the delete of the old container:

1. **Phase A (non-destructive gate):** `ManagedContainers.resolveSelection` → read stamps → (volume mode, stopped) bare runtime start → **strict** config read (bind: host file; volume: exec `cat` → temp file) → `ConfigResolver.resolve` → `hostRequirements` preflight → if resolved features non-empty: rosetta consent gate (`AppleContainerConfig.ensureNativeArmBuild`) + Features fetch/build with derived-tag reuse. Any failure here fails `rebuild` with the old container untouched.
2. **Phase B (destructive create path):** container-only `delete` of the old container (existing `DeleteCommand` contract; stop first if required) → `ensureVolume` list-then-reuse for the workspace volume (volume mode) and for each config `type=volume` source — never delete → create the new container (bind: `CreateRequest.from`; volume: `CreateRequest.fromVolumeMode`) → start → volume-mode post-start steps → create-path hooks (`LifecycleRunner.runCreatePath`) with delete-on-fail of the **new** container → settings apply → `--vscode` open → extensions apply on open success → postAttach gate (fail-keep).

**Config reader (chosen from the clarified decision point):** extract a shared `ConfigReader` with an explicit **strictness mode** (`strict` vs `bestEffort`), and keep `PostAttachConfigLoader.load` as a thin best-effort wrapper with its existing public signature and nil-on-missing semantics. Rationale: (1) one authoritative dual-mode implementation — bind labels → host file → `ConfigResolver.resolve`, volume exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename` — so rebuild and postAttach can never drift on label parsing or basename rules; (2) strictness is a reading posture, not a mechanism, so a mode parameter keeps one code path; (3) rebuild maps misses to structured `config_not_found` / `config_parse` errors before any destructive step, while `PostAttachConfigLoader` callers keep relying on nil → “postAttach absent”; (4) both modes are unit-testable against the same fixtures. A strict-only variant for rebuild (leaving the loader untouched) was rejected: it would duplicate the dual-mode label/temp/basename logic and let the two readers diverge.

**Alternatives rejected:** a `--rebuild` flag on `up` (muddies `up`'s workspace-path UX and `--recreate` semantics; the locked product decision is a subcommand, matching `start`-style managed selection); delete + `clone` for volume mode (re-clone loses local edits and re-populates the volume); reusing `loadVolumeMode` verbatim (silent nil on failure); `prune`-style cleanup (deletes volumes); waiting for IDE attach before recreating; running Features build after delete (would destroy the old container before all preconditions pass).

## Significant decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Command surface | New `rebuild` subcommand, `--name`/`--skip-pull`/`--vscode`/`--json` | Distinct forced-recreate UX; `up --recreate` hash-trigger semantics untouched |
| Selection | `ManagedContainers.resolveSelection` (managed-only; `--name`/auto-single/picker/`selection_required`) | Identical to `start`; zero new selection code |
| `-w` gate | Existing global gate applies | `subcommand != "up"` already rejects `-w`; no special case |
| Config read | Shared `ConfigReader` with strict vs best-effort modes | Single dual-mode implementation; rebuild strict (`config_not_found` / `config_parse`), postAttach loader tolerant (nil) |
| Volume-mode stopped container | Bare runtime start before `cat` | Config lives in the volume; no hooks (deleted anyway); errors before anything destructive |
| Config path | Read the stamped `devcontainer.config_file` only | v1: path assumed never to move; no re-discovery |
| Identity | Seed from stamps; keep same name + same `*-ws` volume. New labels = the OLD container's label dict **copied and updated ONLY** for the drift-eligible keys (`config_hash`, `workspace_folder`, `remote_user`, `config_volumes`) — never recomputed via `volumeModeLabels` from a fresh identity (a re-derived human base from an edited config `name` would change `workspace_volume`/`local_folder` label values and disagree with the actually-mounted preserved volume). Bind mode likewise reuses the stamped `local_folder`/`config_file` when building the bind-mode label set | Rebuild must not rename or re-home workspaces; labels must stay byte-identical for identity stamps so labels agree with the preserved name and volume |
| Hash equality | Always proceed (forced recreate) | User intent overrides drift detection; derived-tag reuse keeps unchanged case cheap |
| Volume preservation | Container-only delete of old container; `ensureVolume` list-then-reuse for ws and config volumes; never delete/recreate/populate | Core invariant; existing `delete` and `ensureVolume` contracts reused |
| No re-clone | No populate step on rebuild | Volume data is preserved; `clone` freshness carve-out unchanged |
| Ordering | All read/resolve/preflight/Features work before delete | Old container untouched on any early failure |
| Post-delete failures | `up --recreate` semantics: delete-on-fail of new container + warning old removed | Consistent failure posture across recreate paths |
| Features | Same gate/build as fresh create; derived tag `adev-{base}:{hash12}` reused when material unchanged; `FeatureGitEnsure.ensurePresent` re-inject in volume mode | Parity with `up`/`clone`; volume git parity via inject |
| Writable step | `ensureWorkspaceWritableByRemoteUser` only when effective `remoteUser` differs from stamped | Re-chowning an unchanged tree is needless; new user must get access |
| SSH forward | `enableSSHForward` only when `SSH_AUTH_SOCK` non-empty (volume mode) | Clone HTTPS-branch parity; no clone → no hard require |
| Output | `up`-parity success JSON; volume mode MAY add `gitUrl`/`workspaceVolume`; exits 0/non-zero | Machine-readable parity with existing create commands |
| Error codes | Reuse existing `CLIErrorCode.configNotFound` (`config_not_found`) and `CLIErrorCode.configParse` (`config_parse`) for the strict reader — consumed, not added; no new `CLIErrorCode` cases | Automation can distinguish strict read failures with existing codes; `selection_required`/`container_not_found` also reused |

## Flow

```text
adevcontainer rebuild [--name X] [--skip-pull] [--vscode] [--json]
        │
        ▼
  resolveSelection (managed only; --name | auto-single | picker | selection_required)
        │
        ▼
  read stamps: workspace_mode, local_folder|git_url, config_file,
               workspace_folder, remote_user, workspace_volume, config_hash
        │
        ▼
  [volume-mode & stopped] runtime start (bare; NO hooks; deleted anyway)
        │  fail ──► structured error (old container untouched)
        ▼
  strict config read via ConfigReader
    bind:   ConfigResolver.resolve(local_folder, config_file)
    volume: exec cat <stamped config> → temp file →
            ConfigResolver.resolve(temp, workspaceFolderBasename=stamped folder basename)
        │  missing/unreadable ──► config_not_found
        │  parse/resolve fail ──► config_parse        (old container untouched)
        ▼
  hostRequirements preflight ── fail on shortfall/unreadable/parse (old untouched)
        │
        ▼
  features non-empty?
    │ yes
    ▼
  FeatureGitEnsure.ensurePresent (volume mode: re-inject git:1 when uncovered)
  rosetta consent gate (build.rosetta=false, same as up/clone)
  fetch/build Features → derived tag adev-{base}:{hash12}
      material unchanged ──► reuse tag (no build); --skip-pull skips pull
      fail ──► structured error (old container untouched)
    │ no
    ▼
  ════════ DELETE GATE — everything above succeeded ════════
  delete OLD container only (stop first if required; NO volume/image deletes)
        │
        ▼
  ensureVolume list-then-reuse: ws volume (volume mode) + each config
  type=volume source (create missing; reuse existing; NEVER delete)
        │
        ▼
  new labels = OLD container's label dict copied + updated ONLY for
  drift-eligible keys (config_hash, workspace_folder, remote_user,
  config_volumes) — NEVER recomputed from a fresh identity
        │
        ▼
  create NEW container
    bind:   CreateRequest.from          (preserved host workspace bind)
    volume: CreateRequest.fromVolumeMode (same ws volume mount;
            enableSSHForward iff SSH_AUTH_SOCK non-empty)
        │
        ▼
  start
        │
        ▼
  [volume-mode] ensureWorkspaceWritableByRemoteUser
        only when effective remoteUser != stamped devcontainer.remote_user
        │
        ▼
  create-path hooks: onCreate → updateContent → postCreate → postStart
    non-zero ──► delete NEW container (delete-on-fail) + warn old already removed
        │
        ▼
  settings apply (customizations.vscode.settings; NOT gated; soft-fail)
        │
        ▼
  --vscode? ──no──► postAttach absent? ──► success JSON (exit 0)
        │                │ present
        │                ▼
        │           status: postAttach skipped (no attach hook)
        │ yes
        ▼
  best-effort open
    │ soft-fail ──► warn + skip postAttach (status) ──► success JSON
    │ success
    ▼
  extensions apply (soft-fail; marker idempotency)
        │
        ▼
  postAttach gate (config then feature; exec)
    │ non-zero ──► structured error naming postAttach; KEEP new container
    │ ok
    ▼
  success JSON / human lines (exit 0)
```

### Strict reader contract (HOW)

`ConfigReader.read(labels:containerId:runtime:mode:)` returns a `ResolvedDevContainerConfig?` in best-effort mode (nil when labels/paths are insufficient, mirroring today's `PostAttachConfigLoader`), and throws `config_not_found` (missing label inputs, missing host file, `cat` failure, empty config text) or `config_parse` (JSONC parse/admission failure) in strict mode. Volume-mode read always goes through `cat` on the (auto-started) container into a temp file under `FileManager.default.temporaryDirectory` (cleanup via `defer`, warning-only on cleanup failure), with `workspaceFolderBasename` derived from the stamped `devcontainer.workspace_folder` (fallback `/workspaces`), identical to today's `loadVolumeMode`.

### Post-delete lifecycle wiring (HOW)

- Reuse `LifecycleRunner.runCreatePath` (delete-on-fail already deletes the container on create-path hook failure — that is the **new** container) and `LifecycleRunner.applyPostAttachGate` unchanged.
- The "old container already removed" warning is emitted once on any post-delete failure path (stderr, StatusPrinter), alongside the structured error.
- Settings/extensions/postAttach reuse the existing `VSCodeCustomizationsApply` and `VSCodeOpen` machinery with no behavior change; only the call site (RebuildCommand) is new.
- Volume-mode post-start step reuses `ensureWorkspaceWritableByRemoteUser`; extract it from `CloneCommand` into a shared helper (or move) so both commands call one implementation.
- Volume-mode `git` re-inject: call `FeatureGitEnsure.ensurePresent` on the resolved features before the Features gate (same placement as `CloneCommand`), with the same `Ensuring git feature for volume workspace` status line when injecting.

## Artifact changes

| Area | Nature |
|------|--------|
| `Sources/adevcontainer/AdevcontainerMain.swift` | Dispatch `case "rebuild"`; thread `--name`/`--skip-pull`/`--vscode`/`--json`; usage row; `printCommandHelp("rebuild")` case; JsonStatus for rebuild result |
| `Sources/ADevContainerLib/Commands/RebuildCommand.swift` | New: two-phase orchestration (selection → strict read → preflight/Features gate → delete old → ensureVolume reuse → create/start → hooks → settings → `--vscode` gate → result) |
| `Sources/ADevContainerLib/Commands/ConfigReader.swift` | New: shared dual-mode reader with strict/best-effort modes |
| `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift` | Refactor to best-effort wrapper over `ConfigReader` (public behavior unchanged) |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | Extract `ensureWorkspaceWritableByRemoteUser` to a shared helper for rebuild reuse |
| `Sources/ADevContainerLib/` (CLIErrorCode / errors) | No new cases — the strict reader consumes the existing `configNotFound` (`config_not_found`) / `configParse` (`config_parse`) cases |
| `Tests/adevcontainerTests/ConfigReaderTests.swift` | New: strict vs best-effort; bind/volume reads; error mapping; postAttach-loader parity regression |
| `Tests/adevcontainerTests/RebuildCommandTests.swift` | New: selection matrix; auto-start; ordering gate (no delete on early failure); identity/labels; volume preservation (no ws/config-volume delete, no clone/pull); create parity (enableSSHForward, git inject, writable step); hook matrix; output/exit parity |
| `README.md` / usage / `printCommandHelp` | `rebuild` documented: flags, selection, forced-recreate, volume preservation, `--vscode` gate |
| `specs/managed-lifecycle.md`, `specs/core.md`, `specs/clone.md`, `specs/vscode.md`, `specs/features.md` | Fold MODIFIED deltas from `spec.md` into the live contract when the change lands; archive `specs/changes/rebuild/` → `specs/changes/archive/20260809-rebuild/` |