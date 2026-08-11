# Design: rebuild

Lean HOW for the forced-rebuild command. Outcome contract lives in `spec.md`; this file encodes the two-phase ordering, the shared strict config reader, the volume-preserving create path, and the **mode-split recovery** branch (volume helper vs bind host-editor) so implementers do not invent a second read, delete, or fake-helper policy.

## Approach

`RebuildCommand` is a hybrid of `StartCommand` (selection), `PostAttachConfigLoader` (dual-mode config read), and `UpCommand`/`CloneCommand` (create path), with a recovery-session branch that splits by workspace mode. It runs in two phases split at the delete of the old container:

1. **Phase A (non-destructive gate):** `ManagedContainers.resolveSelection` → read stamps → classify recovery eligibility (clone-origin volume vs bind vs none) → (volume mode, stopped) bare runtime start → **strict** config read and resolution (bind: host file; volume: exec `cat` → temp file with stamped basename) → **volume clone-origin only:** persist the exact raw bytes from that read in a secure recovery session and preflight the immutable arm64 Alpine helper image → `hostRequirements` preflight → if resolved features non-empty: rosetta consent gate (`AppleContainerConfig.ensureNativeArmBuild`) + Features fetch/build with derived-tag reuse. Any failure here fails `rebuild` with the old container untouched. Bind Phase A does **not** preflight a helper image and does **not** require a private temp capture of the edit target.
2. **Phase B (destructive create path):** container-only `delete` of the old container (existing `DeleteCommand` contract; stop first if required) → `ensureVolume` list-then-reuse for the workspace volume (volume mode) and for each config `type=volume` source — never delete → create the new container (bind: `CreateRequest.from`; volume: `CreateRequest.fromVolumeMode`) → start → volume-mode post-start steps → create-path hooks (`LifecycleRunner.runCreatePath`) with delete-on-fail of the **new** container → settings apply → `--vscode` open → extensions apply on open success → postAttach gate (fail-keep).
3. **Recovery branch (eligible hard post-delete failure only):** on new create/start or create-path-hook failure, clean and verify any new-container attachment, then branch by mode. For both bind and volume, TTY recovery is **prompt-then-editor**, never auto-open:
   - **Shared TTY gate:** print structured failure on stderr first → prompt `Open the recovery editor now? [Y/n]` (default **Y**) via a single stdin line read → affirmative enters the mode-specific editor loop; decline/EOF/non-affirmative defers with retained recovery state and the same structured details + exact `rebuild --name` retry instructions as non-TTY retain (exit non-zero).
   - **Volume clone-origin:** create/start the marked helper from the preflighted image with the original name/identity and the exact existing `*-ws` volume read-write → TTY gate → (yes) editor/validate/atomic-write/readback/retry loop, or (no/EOF) retain helper+temp + non-TTY-style instructions; non-TTY/`--json` structured instructions only (never prompt or editor). On a retry, write the host edit through the helper before the config reader runs; after lifecycle success verify the final container reads the edited bytes from the same volume, then remove the helper/session.
   - **Bind:** no helper. Share TTY gate, editor resolution, and non-TTY branching with volume recovery. After affirmative prompt, open the editor **directly** on the host stamped path (`local_folder` + `config_file`); validate with bind-mode strict rules; retry rebuild on success; invalid reopens editor; editor cancel leaves host file as-is. Decline/EOF retains host path + resume stamps and prints non-TTY-style details. Non-TTY/`--json` returns structured details (host path, failure kind, shell-quoted edit hint, `rebuild --name` retry) with **no** helper-delete cleanup.
   - Settings/extension soft-fail, VS Code open soft-fail, postAttach failure, and non-clone volume failures do not enter this branch.

**Config reader (chosen from the clarified decision point):** extract a shared `ConfigReader` with an explicit **strictness mode** (`strict` vs `bestEffort`), and keep `PostAttachConfigLoader.load` as a thin best-effort wrapper with its existing public signature and nil-on-missing semantics. Rationale: (1) one authoritative dual-mode implementation — bind labels → host file → `ConfigResolver.resolve`, volume exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename` — so rebuild and postAttach can never drift on label parsing or basename rules; (2) strictness is a reading posture, not a mechanism, so a mode parameter keeps one code path; (3) rebuild maps misses to structured `config_not_found` / `config_parse` errors before any destructive step, while `PostAttachConfigLoader` callers keep relying on nil → “postAttach absent”; (4) both modes are unit-testable against the same fixtures. A strict-only variant for rebuild (leaving the loader untouched) was rejected: it would duplicate the dual-mode label/temp/basename logic and let the two readers diverge.

**Alternatives rejected:** a `--rebuild` flag on `up` (muddies `up`'s workspace-path UX; the locked product decision is a `rebuild` subcommand with managed selection, matching `start`); delete + `clone` for volume mode (re-clone loses local edits and re-populates the volume); reusing `loadVolumeMode` verbatim (silent nil on failure); `prune`-style cleanup (deletes volumes); restoring the old container/image after a failure (not available as a reliable rollback boundary); a host bind mount or `container cp` for **volume** recovery editing (breaks the exact-volume/atomic-write contract); inventing a **fake recovery helper for bind** (adds container lifecycle, labels, list/prune rules, and Alpine preflight without restoring a lost capability — the host stamped file is already editable); forcing bind edits through a private temp copy + copy-back when the product preference is direct host path; waiting for IDE attach before the rebuild; running Features build after delete (would destroy the old container before all preconditions pass).

## Significant decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Command surface | New `rebuild` subcommand, `--name`/`--skip-pull`/`--vscode`/`--json` | Forced-rebuild UX; hash mismatch → error + rebuild hint |
| Selection | `ManagedContainers.resolveSelection` (managed-only; `--name`/auto-single/picker/`selection_required`) | Identical to `start`; zero new selection code |
| `-w` gate | Existing global gate applies | `subcommand != "up"` already rejects `-w`; no special case |
| Config read | Shared `ConfigReader` with strict vs best-effort modes | Single dual-mode implementation; rebuild strict (`config_not_found` / `config_parse`), postAttach loader tolerant (nil) |
| Volume-mode stopped container | Bare runtime start before `cat` | Config lives in the volume; no hooks (deleted anyway); errors before anything destructive |
| Config path | Read the stamped `devcontainer.config_file` only | v1: path assumed never to move; no re-discovery |
| Identity | Seed from stamps; keep same name + same `*-ws` volume. New labels = the OLD container's label dict **copied and updated ONLY** for the drift-eligible keys (`config_hash`, `workspace_folder`, `remote_user`, `config_volumes`) — never recomputed via `volumeModeLabels` from a fresh identity (a re-derived human base from an edited config `name` would change `workspace_volume`/`local_folder` label values and disagree with the actually-mounted preserved volume). Bind mode likewise reuses the stamped `local_folder`/`config_file` when building the bind-mode label set | Rebuild must not rename or re-home workspaces; labels must stay byte-identical for identity stamps so labels agree with the preserved name and volume |
| Hash equality | Always proceed (forced rebuild) | User intent overrides drift detection; derived-tag reuse keeps unchanged case cheap |
| Volume preservation | Container-only delete of old container; `ensureVolume` list-then-reuse for ws and config volumes; never delete, replace, or populate | Core invariant; existing `delete` and `ensureVolume` contracts reused |
| No re-clone | No populate step on rebuild | Volume data is preserved; `clone` freshness carve-out unchanged |
| Ordering | All read/resolve/preflight/Features work before delete; volume helper preflight only for clone-origin volume | Old container untouched on any early failure; bind does not block delete on helper image availability |
| Post-delete failures | delete-on-fail of new container + warning old removed; then mode-split recovery for eligible hard failures | Consistent failure posture; UX parity without mechanism parity |
| Features | Same gate/build as fresh create; derived tag `adev-{base}:{hash12}` reused when material unchanged; `FeatureGitEnsure.ensurePresent` re-inject in volume mode | Parity with `up`/`clone`; volume git parity via inject |
| Writable step | `ensureWorkspaceWritableByRemoteUser` only when effective `remoteUser` differs from stamped | Re-chowning an unchanged tree is needless; new user must get access |
| SSH forward | `enableSSHForward` only when `SSH_AUTH_SOCK` non-empty (volume mode) | Clone HTTPS-branch parity; no clone → no hard require |
| Output | `up`-parity success JSON; volume mode MAY add `gitUrl`/`workspaceVolume`; exits 0/non-zero | Machine-readable parity with existing create commands |
| Error codes | Reuse existing `CLIErrorCode.configNotFound` (`config_not_found`) and `CLIErrorCode.configParse` (`config_parse`) for the strict reader; add stable recovery codes `recovery_unavailable`, `recovery_conflict`, `recovery_cancelled`, and `recovery_verification_failed` | Automation can distinguish strict read and recovery outcomes; bind reuses the same codes where applicable (`recovery_cancelled`, `recovery_unavailable`); `recovery_conflict` / helper verification remain volume-oriented |
| Recovery eligibility | Mode-split: (1) managed clone-origin volume (`workspace_mode=volume`, non-empty `git_url`/`workspace_volume`/`config_file`) → helper path; (2) managed bind (`local_folder` + `config_file`, not volume mode) → host-editor path; (3) non-clone volume → no recovery | Shared hard-failure trigger set; mechanism differs by where the stamped config lives |
| Recovery trigger | New create, new start, or `onCreate`/`updateContent`/`postCreate`/`postStart` failure after old-container deletion (both eligible modes) | Settings/extension soft-fail, VS Code open soft-fail, and postAttach failure keep their existing semantics and do not start recovery |
| Helper image | One immutable Alpine image reference pinned to `linux/arm64`; availability verified before delete — **volume path only** | Avoids mutable tags; bind must not invent Alpine preflight |
| Helper primitive | Long-running unprivileged arm64 helper, same original container name, copied managed identity labels plus `devcontainer.recovery=adevcontainer` and opaque session marker, exact `*-ws` volume mounted read-write — **volume path only** | Existing `exec`/named `rebuild` discovery works; marked helper visible in `list` and skipped by ordinary `prune`. Bind MUST NOT create this primitive. |
| List/prune helper rules | Apply only to containers carrying volume recovery markers | Bind creates no helper; no list/prune special case for bind recovery |
| Secure recovery session (volume) | Private `0700` temp directory, raw config `0600` file, SHA-256 baseline/last-applied hashes, secure metadata keyed by opaque session id | Raw config stays out of labels/output; volume conflict detection |
| Bind edit target | Direct host stamped path (`local_folder` + `config_file`); no private temp edit copy required | Product preference: editor points at the real file rebuild will re-read; avoids dual-write drift |
| Bind session metadata | Optional baseline/hash notes only; no helper write path; no required secure temp | Conflict awareness MAY exist without inventing volume-style atomic helper write |
| Failed-container attachment | Delete/stop the failed new container; volume path also verifies no attachment to `*-ws` before helper start | Prevents two writers on volume; bind only needs new-container delete-on-fail |
| Atomic write-back | Volume only: stream exact bytes through helper exec → same-directory temp → atomic rename → readback SHA-256 | Bind has no volume write-back |
| TTY open-editor prompt | Shared bind+volume: after printing structured failure, read one line from stdin TTY; prompt text `Open the recovery editor now? [Y/n]`; default **Y** (empty line / Enter = yes); affirmative = `y`/`Y`/yes-class (trim, case-insensitive prefix rules below); decline = `n`/`N`/no-class; EOF = decline | Operator can read the error and choose fix-now vs later; never auto-open editor |
| Editor process | Shared: first usable `$VISUAL`, `$EDITOR`, `/usr/bin/nano`, `/usr/bin/vi`; pass the mode-appropriate path as a separate final argument and wait; only after affirmative prompt | Deterministic TTY behavior; volume passes secure temp path; bind passes host stamped path |
| TTY retry loop | Shared structure after affirmative prompt: normal editor exit → mode-appropriate strict validation → (volume: atomic helper write/readback) → retry; invalid reopens; interrupt/EOF cancels editor loop | Volume never writes invalid bytes to volume; bind leaves invalid host edits until user fixes or cancels |
| TTY prompt defer | Decline/EOF/non-affirmative: no editor; retain recovery state (volume: helper+session; bind: host file + resume stamps); print non-TTY-equivalent structured recovery details + exact `rebuild --name` retry; exit non-zero (`recovery_cancelled` or equivalent deferred classification) | Later retry works; same information quality as CI/non-TTY retain |
| Non-TTY / JSON | Never prompt (including open-editor prompt) or launch editor; return failure details with shell-quoted edit + named retry; volume also keeps helper/session and helper-delete cleanup; bind has no helper cleanup | CI cannot hang; operators can resume |
| Recovery selection (volume) | Later `rebuild --name` selects the marked helper, writes session temp before reading config, then deletes helper as selected old container | Bind has no helper selection path |
| Final verification/cleanup | Volume: helper removed at retry delete gate; final container hash-verify; remove secure session. Bind: normal lifecycle success after host path already holds the edit; no helper cleanup | Success proves the user edit is visible at the real runtime boundary |
| No filesystem rollback | Recovery does not snapshot, restore, or undo workspace contents changed by failed hooks | The contract is edit access and retry, not a transaction boundary |

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
  classify recovery eligibility:
    clone-origin volume → helper path
    bind (local_folder+config_file) → host-editor path
    else → no recovery
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
        │  parse/resolve fail ──► config_parse        (old container untouched; NO recovery)
        ▼
  [volume eligible] capture exact raw bytes from the volume read into secure host session
                    preflight immutable linux/arm64 Alpine helper image
         │  fail ──► structured error (old container untouched)
  [bind] no helper preflight; host stamped path is already the edit target
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
    │ create/start fails ──► delete/verify NEW attachment
    │                         [volume eligible] create/start HELPER → volume recovery
    │                         [bind eligible]   bind host-editor recovery (NO helper)
    │                         [non-clone volume] structured failure + old-removed warning
         │
         ▼
  [volume-mode] ensureWorkspaceWritableByRemoteUser
        only when effective remoteUser != stamped devcontainer.remote_user
        │
        ▼
  create-path hooks: onCreate → updateContent → postCreate → postStart
    non-zero ──► delete NEW container and verify detached
                 [volume eligible] start HELPER → volume recovery session
                 [bind eligible]   bind host-editor recovery (NO helper)
                 [non-clone volume] structured failure + warn old already removed
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

Shared TTY recovery gate (bind + volume, no --json):
  print structured failure / failure reason on stderr
  (same information quality as non-TTY retain for this mode)
       │
       ▼
  prompt on stderr: "Open the recovery editor now? [Y/n] "
  read one line from stdin (TTY)
       │ empty / y / Y / yes-class ──► affirmative → mode editor loop
       │ n / N / no-class / other non-empty non-yes / EOF ──► defer
       ▼ defer
  retain recovery state (volume: HELPER + secure temp;
                         bind: host file + resume stamps)
  print non-TTY-equivalent structured recovery details +
  exact edit / rebuild --name retry / mode-appropriate cleanup
  exit non-zero (no editor launched)

Volume recovery session (TTY, after affirmative prompt):
  select $VISUAL → $EDITOR → /usr/bin/nano → /usr/bin/vi
       │ editor cancel ──► keep HELPER + secure temp; report commands
       ▼
  open secure host temp file
  strict volume-mode resolve of temp file
       │ invalid ──► report config_parse/config admission; reopen editor
       ▼ valid
  helper exec: stream bytes → same-directory temp → atomic rename
       │ readback/hash mismatch or volume conflict ──► structured recovery error; keep session
       ▼ verified
  retry named rebuild; helper is selected and deleted only after write/readback
       │ retry hard failure ──► clean/verify NEW; replace HELPER; re-enter shared TTY gate
       ▼ lifecycle success
  final container reads/hash-verifies edited config → ensure HELPER absent + remove secure temp

Volume recovery session (non-TTY/--json):
  keep HELPER + secure temp; no editor/prompt (including open-editor prompt);
  return reason, identity, hashes, and exact edit/retry/cleanup commands
  (includes helper container-only delete)

Bind recovery session (TTY, after affirmative prompt):
  select $VISUAL → $EDITOR → /usr/bin/nano → /usr/bin/vi  (shared resolver)
       │ editor cancel ──► NO helper; host file as left; report host path + retry
       ▼
  open host stamped path (local_folder + config_file) DIRECTLY
  strict bind-mode resolve of that path
       │ invalid ──► report config_parse/config admission; reopen editor
       ▼ valid
  retry rebuild (normal bind strict read already sees host edit)
       │ retry hard failure ──► delete NEW; re-enter shared TTY gate
       ▼ lifecycle success
  success (no helper cleanup)

Bind recovery session (non-TTY/--json):
  no helper; no editor/prompt (including open-editor prompt); return host config path,
  failure kind, shell-quoted edit hint, rebuild --name retry;
  cleanup MUST NOT mention helper delete
```

### Strict reader contract (HOW)

`ConfigReader.read(labels:containerId:runtime:mode:)` returns a `ResolvedDevContainerConfig?` in best-effort mode (nil when labels/paths are insufficient, mirroring today's `PostAttachConfigLoader`), and throws `config_not_found` (missing label inputs, missing host file, `cat` failure, empty config text) or `config_parse` (JSONC parse/admission failure) in strict mode. Volume-mode read always goes through `cat` on the (auto-started) container into a temp file under `FileManager.default.temporaryDirectory` (cleanup via `defer`, warning-only on cleanup failure), with `workspaceFolderBasename` derived from the stamped `devcontainer.workspace_folder` (fallback `/workspaces`), identical to today's `loadVolumeMode`.

### Recovery mode classification (HOW)

`RecoveryOrchestrator` (or equivalent eligibility helper) classifies once from stamps after selection:

1. **Volume helper recovery** if `managed=adevcontainer`, `workspace_mode=volume`, and non-empty `git_url`, `workspace_volume`, and `config_file`.
2. Else **bind host-editor recovery** if managed and not volume mode, with non-empty `local_folder` and `config_file`.
3. Else **ineligible** (warning-only post-delete path).

The hard-failure trigger predicate is shared for (1) and (2). Pre-delete failures never enter recovery. Soft-fail and postAttach paths never enter recovery.

### Recovery helper primitive (HOW) — volume only

Recovery eligibility for the helper is derived from the selected container's existing clone identity, not from a new config identity. The helper image is one release-pinned Alpine reference whose immutable digest is a checked-in code/config constant, used with an explicit `linux/arm64` platform. The digest is deliberate and MUST never be replaced at runtime with a mutable tag. Phase A asks `AppleContainerRuntime` to inspect the exact image and pull it when the normal pull policy permits; only a verified available image lets the delete gate open for volume-eligible targets.

The helper is a minimal, long-running Alpine process with no privileged flags, no host workspace bind, and no network requirement. It mounts exactly the selected `devcontainer.workspace_volume` source read-write at the stamped effective workspace path and does not mount, delete, replace, or populate config named volumes. It uses the selected container's original name and copies its identity labels byte-for-byte, then adds an opaque `devcontainer.recovery_session` marker and `devcontainer.recovery=adevcontainer`. The original name is available because the old container and any failed new container have been removed before helper creation.

Before mounting the workspace volume, `RecoveryOrchestrator` must clean the failed new container when one exists (stop/force-delete according to the existing container-only policy), then inspect runtime state/mounts and verify that no failed container remains attached to the exact workspace volume. A failed delete or inconclusive attachment check is a recovery-unavailable outcome; the helper is not started and no volume cleanup is attempted. This ordering prevents a failed lifecycle process and helper from concurrently writing the same volume.

The helper is intentionally a recovery endpoint, not a normal development container. `list` includes it because it retains the managed label but renders the recovery marker/state; `exec --name` can target it. `rebuild --name` recognizes the marker and session metadata, writes the session's edited temp file through the live helper before reading config, and deletes the helper only after the pre-delete gate for that retry has succeeded. The original failure path MUST leave the helper running for a later named retry; only a same-process TTY retry may perform the delete as part of its controlled replacement. Ordinary `delete` remains container-only and can be used by the reported cleanup command. `prune` skips any container carrying the recovery marker and skips all of its referenced volumes.

**Bind MUST NOT** call into helper create/start, image preflight, recovery labels, or list/prune helper filtering as part of its recovery path.

### Secure host recovery session and conflict handling (HOW) — volume primary

For an eligible volume target, the volume-mode `ConfigReader` exposes the exact bytes it read before the old container is deleted. `RecoveryConfigSession` creates a private directory with `0700` permissions and a raw config file with `0600` permissions. It stores only non-secret metadata beside it: an opaque session id, target name/id, workspace volume, stamped config path, workspace-folder basename, original SHA-256, current baseline SHA-256, and last-applied SHA-256. The temp path is kept in secure host metadata and returned to the user only because an operator needs it for the edit command; it is never stored in a container label or progress message, and raw config bytes never enter JSON.

Every volume edit attempt reads the host file as a regular, non-symlink file, computes SHA-256, and validates the complete bytes through the same strict volume-mode `ConfigResolver` invocation used by rebuild. The validator uses the stamped workspace-folder basename and identity inputs; it MUST NOT substitute the private temp directory's basename for the clone repository basename. Before write-back, the helper hashes the current target. If it differs from the session baseline/last-applied hash, the session reads the current volume bytes into a second private conflict file, retains the edited temp, reports `recovery_conflict`, and does not overwrite the target in that attempt. The session records the captured current hash as the new acknowledged baseline only for the next explicit retry: TTY recovery reopens the editor with both paths reported, while non-TTY/JSON requires the operator to review the conflict file before invoking the named retry. No implementation may silently discard either version or silently force an overwrite.

The session metadata is validated on every later `rebuild --name` invocation against a helper: owner/mode, session id, target name, workspace volume, and config path must match the helper labels and the live volume. Missing, replaced, symlinked, or hash-inconsistent session files produce a structured recovery-unavailable/conflict error while leaving the helper and volumes intact.

### Shared TTY open-editor prompt (HOW)

Both bind and volume recovery use one prompt implementation (e.g. `RecoveryOrchestrator.promptOpenEditor` or a small shared helper). It runs only when stdin is a TTY **and** `--json` is absent. Non-TTY and `--json` skip this entire step.

**Order (hard requirement):**

1. Emit the structured failure / failure reason on **stderr** first, with the same fields and information quality the mode already uses for non-TTY retain (volume: helper identity, session/temp, failure kind, edit/retry/cleanup commands; bind: host path, failure kind, edit hint, retry). The operator MUST be able to read why rebuild failed before deciding whether to edit now.
2. Write the prompt line to **stderr** (never stdout; keeps `--json` purity habits and avoids mixing with machine-readable streams even on human TTY):

   ```text
   Open the recovery editor now? [Y/n]
   ```

   Trailing space after the closing bracket is allowed. Do not auto-open the editor before this prompt is answered.
3. Read **one line** from stdin (blocking line read). Do not use a raw single-key read that would skip Enter; operators confirm with Enter.
4. Classify the answer after trimming surrounding whitespace:
   - **Affirmative (default Y):** empty line (Enter alone), or a line whose first non-empty token case-insensitively equals `y` or `yes` (accept common yes-class tokens the implementation documents in one place; minimum required set is empty, `y`, `Y`, `yes`, `YES`).
   - **Decline:** EOF on the read; or a line whose first token case-insensitively equals `n` or `no` (minimum required set: `n`, `N`, `no`, `NO`); or any other non-empty input that is not affirmative.
5. **Affirmative** → proceed to the mode-specific editor loop (volume temp path or bind host stamped path) using shared `RecoveryEditor` precedence.
6. **Decline / EOF / non-affirmative** → defer path: do **not** launch an editor; **retain** recovery state (volume: helper + secure temp; bind: host stamped file as left + any resume stamps); print/return the same structured recovery details and exact shell-quoted edit + `adevcontainer rebuild --name ...` retry (+ mode-appropriate cleanup) as the non-TTY retain path; exit non-zero. Prefer `recovery_cancelled` (or a documented equivalent deferred-recovery code that maps to the same operator-facing retain payload) so automation can distinguish “operator deferred edit” from hard `recovery_unavailable`.

**Invariants:**

- Prompt detection and classification MUST be identical for bind and volume.
- The prompt MUST NOT run again inside the invalid-config editor reopen loop (only the initial entry into recovery, and after a later hard retry failure re-enters the recovery branch).
- After a hard retry failure that re-enters recovery, print the new structured failure again, then prompt again (operator may have fixed nothing or may want to defer).
- Never prompt when `--json` is set, even if stdin is a TTY.

### Bind host-editor recovery (HOW)

Bind recovery is intentionally thinner than volume recovery because the stamped config already lives on the host.

1. After eligible hard post-delete failure and new-container delete-on-fail, resolve the host stamped path from stamps (`local_folder` joined with `config_file` using the same rules as bind-mode `ConfigReader`).
2. Branch TTY vs non-TTY/`--json` with the same detection rules as volume recovery (including `--json` forces non-interactive even on a TTY).
3. **TTY:** run the shared open-editor prompt (above) after printing structured failure. On affirmative, `RecoveryEditor` opens the host stamped path directly (shared editor precedence). On normal exit, validate with **bind-mode** strict `ConfigResolver.resolve` against that path. Invalid → report and reopen (no second open-editor prompt). Valid → invoke rebuild retry using the same selected name (no helper to select or delete). Editor cancel → `recovery_cancelled` with host path + retry command; no helper cleanup. Prompt defer (decline/EOF) → retained host path + non-TTY-equivalent details + exit non-zero; no editor. Editor launch failure after candidates exhausted → `recovery_unavailable`.
4. **Non-TTY/`--json`:** build recovery details object with host `configFile` (absolute path), container name/id, failure classification, `editCommand` (shell-quoted editor + host path), `retryCommand` (`adevcontainer rebuild --name <name>`). Omit helper identity, workspace volume, secure temp, and helper-delete cleanup. If a cleanup field is present at all, it MUST NOT mention helper delete. Never run the open-editor prompt.
5. **No private temp edit target by default.** Prefer direct host path so the operator and the next rebuild read the same inode. Optional session metadata (hashes, notes) MAY be recorded for diagnostics without changing the editor target. Do not invent a temp-copy + atomic replace path for bind unless a future conflict case requires it; v1 product preference is direct host path.
6. Retry hard failures re-enter the same bind recovery branch after cleaning the failed new container (structured failure print + prompt again on TTY). There is no helper replacement step.

### Atomic in-container write and readback (HOW) — volume only

Write-back uses the runtime's exec/stdin boundary, never `container cp` and never a host bind mount. The helper receives the exact validated bytes, creates a randomly named temporary file in the **same directory and filesystem** as the stamped config path with `umask 077`/restrictive mode, verifies the stream length/hash, atomically renames the temporary file over the target, and removes the temporary file on every failure path. The helper then reads the target back and returns a SHA-256 (and, in tests, byte comparison) to the host. A write, rename, or readback failure MUST either leave the previous target intact (before rename) or leave a complete replacement (after atomic rename), never a partial config; it always leaves all volumes untouched and the session available for retry or cleanup.

The volume retry ordering is deliberate: successful validation and helper readback happen first, then the recovery-aware `rebuild` path reads the config from the helper-mounted volume. It does not resolve from the host temp file and it does not copy the edit again after final create. The final container mounts the same `*-ws` volume, so final verification reads the stamped config through the final container and compares its bytes/hash with the session's last-applied value. That shared-volume equivalence is the reason a redundant post-success copy is forbidden.

### Editor process and retry loop (HOW) — shared selection, mode-split target

In a TTY/non-JSON flow, the shared open-editor prompt runs **before** any editor process. Only after an affirmative answer does `RecoveryEditor` resolve the first usable candidate in this exact order: `$VISUAL`, `$EDITOR`, `/usr/bin/nano`, `/usr/bin/vi`. “Usable” means the executable can be resolved before launch; an unusable environment candidate falls through to the next candidate. The path argument is mode-specific: volume passes the private temp path; bind passes the host stamped path. The path is passed as a separate final argument, not interpolated into an unquoted shell string. The process is awaited. A normal exit triggers mode-appropriate strict validation; a validation failure prints the structured reason and reopens the same editor without starting rebuild (and without writing the volume on the volume path) and **without** re-asking the open-editor prompt. An interrupt/EOF on the editor is user cancellation of the editor loop. An editor that cannot be launched after candidate resolution is a recovery-unavailable error, not a successful retry. Prompt defer (decline/EOF before any editor) is a separate path: retain state, print non-TTY-equivalent details, exit non-zero, no editor.

For a valid **volume** edit, `RecoveryOrchestrator` performs atomic write and readback, then invokes the normal rebuild retry using the helper as the selected old container. Any retry failure before its delete gate leaves the helper in place. A retry hard create/start/create-path failure repeats failed-container cleanup and helper replacement, preserving the same session, then re-enters the shared TTY gate (print new failure → prompt again).

For a valid **bind** edit, `RecoveryOrchestrator` invokes the normal rebuild retry using the original selected name; the bind strict reader loads the host stamped path. A retry hard failure cleans the new container and re-enters bind recovery via the shared TTY gate.

Settings/extension soft-fail, open soft-fail, and postAttach fail-keep terminate the retry using their existing outcomes rather than opening another recovery session or prompt.

### Non-TTY and JSON flow (HOW)

Non-interactive detection is made before any editor process or open-editor prompt. The same rule applies whenever `--json` is set, even if stdin is a TTY.

**Volume:** The helper remains running and the secure session remains on every returned recovery outcome. The error payload has a recovery object with `status`, opaque `sessionId`, helper `containerId`/`containerName`, `workspaceVolume`, `configFile`, `tempFile`, an optional `conflictFile`, `expectedHash`, failure classification, and shell-quoted commands:

1. `editCommand` invokes the first available `$VISUAL`, `$EDITOR`, `/usr/bin/nano`, or `/usr/bin/vi` with the temp path; if none is available, the payload reports `recovery_editor_unavailable` while preserving the session.
2. `retryCommand` is `adevcontainer rebuild --name <helper-name>`. The recovery-aware named path applies and verifies the temp bytes through the helper before config read.
3. `cleanupCommand` invokes the existing container-only `adevcontainer delete --name <helper-name>` and then removes only the reported temp file/private session directory. It MUST NOT contain a volume delete, global prune, or image rollback command.

**Bind:** No helper remains. The recovery object includes `status`, container name/id, host `configFile`, failure classification, and shell-quoted commands:

1. `editCommand` invokes the first available editor with the **host stamped path**.
2. `retryCommand` is `adevcontainer rebuild --name <original-name>`.
3. `cleanupCommand` is omitted or, if present, MUST NOT mention helper delete, volume delete, or prune of a recovery helper.

Human non-TTY output presents the same commands; JSON keeps them as fields/array values and never places them on stdout alongside a success object. Secrets and raw config content are excluded from both forms.

### Failure and cleanup matrix (HOW)

| Failure point | Eligible clone-origin volume | Eligible bind | Non-clone volume |
|---------------|------------------------------|---------------|------------------|
| Config/read/host/Features before old delete | Old container remains; structured error; no helper; discard volume secure session if created because no recovery boundary was crossed | Old container remains; structured error; no recovery | Old container remains; structured error |
| Helper-image preflight before old delete | Old container remains; recovery-unavailable; no helper | N/A (no preflight) | N/A |
| New create/start or create-path hook after old delete | Clean/verify new attachment, start helper; TTY: print failure → open-editor prompt → editor loop or defer-retain; non-TTY/JSON: retained session only | Delete new container; TTY: print failure → same prompt → host-path editor or defer-retain; non-TTY/JSON: host-path details; **no helper** | Delete new container, structured error, old-removed warning; no recovery |
| Settings/extension soft-fail | Existing soft-fail/status; no recovery | Existing soft-fail/status; no recovery | Existing soft-fail/status |
| VS Code open soft-fail | Existing success/status; no recovery | Existing success/status; no recovery | Existing success/status |
| postAttach failure after successful open | Keep final new container and fail; no recovery | Keep final new container and fail; no recovery | Keep final new container and fail |
| Volume ensure/writable-step or other unlisted post-delete failure | Structured failure plus old-removed warning; no helper | Structured failure plus old-removed warning; no bind recovery | Structured failure plus old-removed warning |
| Helper/failed-attachment/write/readback/final-verify/cleanup failure | Structured recovery-unavailable or rollback-style error; never delete volumes; retain session/helper when possible | N/A for helper paths; bind editor launch failure → recovery-unavailable; cancel → recovery_cancelled | N/A |

The recovery helper/session path never calls workspace/config volume delete, replace, or populate. A normal rebuild retry may still create a newly declared **missing** config named volume through the existing `ensureVolume` contract; it MUST reuse every existing volume and never delete/replace/repopulate it. Recovery also never attempts to restore the old image or old container. If a hook modified workspace files, those modifications remain visible through the helper (volume) or host bind (bind) and any final retry.

Bind mode deliberately has **no recovery helper** because its stamped config remains on the host; inventing a helper would add Alpine preflight, labels, list/prune rules, and a second editing mechanism without restoring a lost capability. The desired product change is **UX parity** (TTY editor loop + non-TTY structured details), not mechanism parity. Settings/extension soft-fail and VS Code open soft-fail leave a usable new container, while postAttach failure intentionally keeps that container under the existing fail-keep contract. Starting recovery for those outcomes would turn advisory/attach behavior into provisioning rollback and would change established success/fail semantics, so they remain outside the recovery trigger set for both modes.

### Post-delete lifecycle wiring (HOW)

- Reuse `LifecycleRunner.runCreatePath` (delete-on-fail already deletes the container on create-path hook failure — that is the **new** container) and `LifecycleRunner.applyPostAttachGate` unchanged.
- The "old container already removed" warning is emitted once on any post-delete failure path (stderr, StatusPrinter), alongside the structured error.
- Settings/extensions/postAttach reuse the existing `VSCodeCustomizationsApply` and `VSCodeOpen` machinery with no behavior change; only the call site (RebuildCommand) is new.
- Route eligible hard post-delete failures through `RecoveryOrchestrator` only after `LifecycleRunner`/runtime cleanup has removed and verified the failed new container. The orchestrator owns mode classification, volume helper/session lifecycle, bind host-editor branch, shared editor/TTY/non-TTY branching, retry and final verification; it does not own volume deletion and MUST NOT create a helper on the bind branch.
- Volume-mode post-start step reuses `ensureWorkspaceWritableByRemoteUser`; extract it from `CloneCommand` into a shared helper (or move) so both commands call one implementation.
- Volume-mode `git` re-inject: call `FeatureGitEnsure.ensurePresent` on the resolved features before the Features gate (same placement as `CloneCommand`), with the same `Ensuring git feature for volume workspace` status line when injecting.

## Artifact changes

| Area | Nature |
|------|--------|
| `Sources/adevcontainer/AdevcontainerMain.swift` | Dispatch `case "rebuild"`; thread `--name`/`--skip-pull`/`--vscode`/`--json`; usage row; `printCommandHelp("rebuild")` case; JsonStatus for rebuild result |
| `Sources/ADevContainerLib/Commands/RebuildCommand.swift` | New: two-phase orchestration plus mode-split recovery-aware retry selection (selection → strict read / volume raw capture+helper preflight → preflight/Features gate → delete old → ensureVolume reuse → create/start → hooks → settings → `--vscode` gate → result/final readback) |
| `Sources/ADevContainerLib/Commands/ConfigReader.swift` | New: shared dual-mode reader with strict/best-effort modes |
| `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift` | Refactor to best-effort wrapper over `ConfigReader` (public behavior unchanged) |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | Extract `ensureWorkspaceWritableByRemoteUser` to a shared helper for rebuild reuse |
| `Sources/ADevContainerLib/Commands/RecoveryHelper.swift` | New: clone-origin eligibility, immutable arm64 Alpine image policy, helper identity/mount/attachment contract (**volume only**) |
| `Sources/ADevContainerLib/Commands/RecoveryOrchestrator.swift` | New: mode classification (volume vs bind vs none), failed-container cleanup, volume helper/session lifecycle, bind host-editor branch, shared TTY open-editor prompt (print failure → `[Y/n]` line read → affirmative/defer), shared TTY/non-TTY branching, retry and final verification |
| `Sources/ADevContainerLib/Commands/RecoveryConfigSession.swift` | New: private temp/session metadata, raw bytes, SHA-256 baselines/conflict files, secure cleanup (**volume primary**; bind optional metadata only) |
| `Sources/ADevContainerLib/Commands/RecoveryEditor.swift` | New: ordered editor selection and awaited TTY process with cancellation handling; path argument is mode-specific (temp vs host stamped); invoked only after affirmative open-editor prompt |
| `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift` | Extend the runtime boundary with image preflight, helper create/start, stdin exec, mount inspection, and readback primitives for the volume path; no direct command shell-outs elsewhere |
| `Sources/ADevContainerLib/Commands/ListCommand.swift` / `PruneCommand.swift` | Render recovery marker/state and skip marked helpers/resources during ordinary prune (**volume helpers only**) |
| `Sources/ADevContainerLib/` (CLIErrorCode / errors) | Reuse `configNotFound`/`configParse`; add structured recovery-unavailable, conflict, cancellation, and final-verification cases with mode-appropriate recovery details |
| `Tests/adevcontainerTests/ConfigReaderTests.swift` | New: strict vs best-effort; bind/volume reads; error mapping; postAttach-loader parity regression |
| `Tests/adevcontainerTests/RebuildCommandTests.swift` | New: selection matrix; auto-start; ordering gate (no delete on early failure); identity/labels; volume preservation (no ws/config-volume delete, no clone/pull); create parity (enableSSHForward, git inject, writable step); hook matrix; output/exit parity |
| `Tests/adevcontainerTests/RecoveryConfigSessionTests.swift` | New: secure permissions, raw-byte/hash/conflict handling, same resolution rules, atomic write/readback contract, cleanup failure |
| `Tests/adevcontainerTests/RecoveryEditorTests.swift` | New: editor precedence, no-editor/no-prompt non-TTY/JSON behavior, cancellation and invalid-config loop; bind host path vs volume temp path argument |
| `Tests/adevcontainerTests/RecoveryOrchestratorTests.swift` | New: failure matrix (volume + bind), failed-container detachment, helper identity/selection (volume), bind no-helper assertions, retry ordering, volume preservation, final-container visibility, and structured commands |
| `Tests/adevcontainerTests/RecoveryHelperTests.swift` / `RecoverySelectionTests.swift` / `RecoveryOutputTests.swift` | New: helper image/identity/mount tests, managed selection/list/prune protection (volume helpers), bind recovery output (host path, no helper cleanup), and human/JSON recovery error/detail contracts |
| `Tests/adevcontainerTests/AllIntegrationTests.swift` | Extend the existing real Apple-container harness with recovery coverage: clone volume hard failure, helper mount/read/write, retry before config read, final readback, cleanup, prune protection, and no-volume-delete assertions; bind hard post-delete recovery (TTY manual / non-TTY structured host path) when gated; gated when runtime/image prerequisites are absent |
| `README.md` / usage / `printCommandHelp` | `rebuild` documented: flags, selection, forced-rebuild, volume preservation, mode-split recovery UX, `--vscode` gate |
| `specs/managed-lifecycle.md`, `specs/core.md`, `specs/clone.md`, `specs/vscode.md`, `specs/features.md` | Fold MODIFIED deltas from `spec.md` into the live contract when the change lands; archive `specs/changes/rebuild/` → `specs/changes/archive/20260810-rebuild/` |
