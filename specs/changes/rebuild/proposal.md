# Proposal: `rebuild` subcommand — recreate a managed container from its current config

## Intent

Today a managed container that has drifted from an edited `devcontainer.json` can only be recreated by deleting it and re-running `up`/`clone` (losing the named volume or requiring manual re-setup) or by `up --recreate`, which is hash-mismatch-triggered and bind-only. This change adds **`adevcontainer rebuild`**, a user-forced recreate of an existing managed container that reads the **current** `devcontainer.json` (committed or not) through the same dual-mode reader used by `start`, runs the full create path like a fresh `up`/`clone`, and — the core invariant — re-creates the container **without deleting or recreating already-declared volumes**: the workspace `*-ws` volume and config `type=volume` named volumes are reused with their data.

## Scope

- Change id: **`rebuild`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/AdevcontainerMain.swift`; tests under `Tests/adevcontainerTests/`
- Realized base contract: union of `specs/<domain>.md`. This delta **adds** the `rebuild` command surface, the strict dual-mode config read, and the forced-recreate/volume-preservation contract; **modifies** the **Unified managed selection for lifecycle commands** model (rebuild joins the `--name`/picker set; `-w` remains usage-error), the **Up lifecycle (create, start, reuse)** recreate/drift policy and create-path hook matrix (rebuild is an explicit user-forced recreate distinct from `up --recreate` hash mismatch), the **Volume-mode workspace mount and labels** freshness rule (re-clone carve-out applies to `clone` only), the **Optional `--vscode` flag** and **postAttachCommand policy (CLI-only)** command lists (rebuild accepts `--vscode` with identical gates), and the **Derived image build** reuse clause (derived-tag reuse when material unchanged applies to rebuild).
- Commands affected: new `rebuild`; existing `up`, `clone`, `start`, `delete` behavior is unchanged.
- Config read mechanism: reuse/extract the existing dual-mode reader in `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift` (`loadBindMode` labels → host file → `ConfigResolver.resolve`; `loadVolumeMode` exec `cat` → temp file → `ConfigResolver.resolve` with `workspaceFolderBasename`) with **strict** semantics for rebuild: unreadable/missing config is a structured `CLIError` (`config_not_found` / `config_parse`), never a silent nil.
- Docs task: README section, usage help row, and `printCommandHelp("rebuild")` updated with the command, flags, selection, and volume-preservation behavior.

## Non-goals

- Changing `up --recreate` trigger semantics (`up --recreate` stays hash-mismatch/forced delete-and-recreate on `up`; rebuild does not alter it)
- Deleting, recreating, or re-populating the workspace `*-ws` volume, or deleting config `type=volume` named volumes, during rebuild (they are reused with data)
- Running git re-clone or `git pull` inside a volume-mode workspace during rebuild (no populate step)
- Config path migration: v1 reads the stamped `devcontainer.config_file` path; a config file that moved is a `config_not_found` error, not a discovery search
- Changing `delete` / `prune` volume semantics (rebuild uses the existing container-only `delete` contract)
- Rebuilding containers that are not managed (`devcontainer.managed=adevcontainer`) or whose labels are missing identity stamps
- Auto-rebuild on drift (drift still requires user action: `up --recreate` or `rebuild`)
- Interactive config editing or edit-confirm prompts beyond the existing selection picker
- Concurrency protection (no rebuild serialization/locking across parallel invocations in v1)
- Full Dev Containers extension parity (no up/rebuild-driver parity claim)

## Approach

Full SDD: this proposal + outcome delta `spec.md` + `design.md` (Full mode) + dependency-ordered `tasks.md`.

1. Extract the dual-mode config reader from `PostAttachConfigLoader` into a shared `ConfigReader` with **strict** and **best-effort** modes; `PostAttachConfigLoader` keeps its tolerant behavior as a wrapper.
2. Add `rebuild` to the CLI surface: dispatch case, `--name` / `--skip-pull` / `--vscode` / `--json`, usage row, and `printCommandHelp("rebuild")`; keep the existing global `-w is only valid for up` gate.
3. Implement `RebuildCommand` in two phases: a non-destructive phase (selection → stamps → strict config read with volume-mode auto-start → resolve → hostRequirements preflight → rosetta consent gate + Features fetch/build with derived-tag reuse) complete **before** the old container is deleted, then a destructive create path (container-only delete of the old container → `ensureVolume` list-then-reuse → create with preserved identity → start → volume-mode git ensure / writable / ssh-forward → create-path hooks with delete-on-fail of the **new** container → settings apply → `--vscode` open → extensions → postAttach fail-keep).
4. Test-first: unit-test `ConfigReader` strict and best-effort modes; command tests with a mocked `AppleContainerRuntime` asserting deletion/volume/no-clone behavior; output and exit parity tests.
5. Document rebuild in README/help and fold the MODIFIED deltas into the domain specs.

## Clarifications

- **Q:** What CLI surface does `rebuild` expose, and does selection differ from `start`?
  **A:** New subcommand `adevcontainer rebuild [--name <container>] [--skip-pull] [--vscode] [--json]`. Selection MUST be identical to `start`: `ManagedContainers.resolveSelection` (`--name` exact match by id or name; auto-select when exactly one managed container; interactive numbered picker when multiple and stdin is a TTY; structured `selection_required` error requesting `--name` when multiple and non-interactive). `-w` / `--workspace` MUST remain a usage error on rebuild (only `up` accepts it).
- **Q:** How is the config read when the volume-mode container is stopped?
  **A:** Rebuild auto-starts it with a **bare runtime start** (no lifecycle hooks — it will be deleted anyway) before reading the config from inside the volume. If start or exec-cat fails, rebuild fails with a structured error **before anything destructive**.
- **Q:** What happens when the resolved config hash equals the stamped `devcontainer.config_hash`?
  **A:** Rebuild always proceeds — it is a user-forced recreate, not drift detection; the derived Features tag reuse (`adev-{base}:{hash12}` when material unchanged) makes the unchanged case cheap.
- **Q:** Which identity do the re-created container and its workspace keep?
  **A:** Identity is seeded from the selected container's stamps — bind mode: `devcontainer.local_folder` + `devcontainer.config_file` re-resolved on host; volume mode: `devcontainer.git_url` + `devcontainer.config_file` (+ `devcontainer.workspace_volume`, `devcontainer.workspace_folder`). The re-created container keeps the **same container name** and mounts the **same `*-ws` workspace volume** with its data. Only `devcontainer.config_hash` (and derived labels: `workspace_folder`, `remote_user`, `config_volumes`) may change. The config path is assumed never to move (v1 reads the stamped path).
- **Q:** What is the volume-preservation invariant?
  **A:** Rebuild MUST NOT delete, recreate, or re-populate the workspace `*-ws` volume and MUST NOT delete config `type=volume` named volumes. Deletion is the existing **container-only** `delete` contract on the old container; create reuses existing volumes via the runtime `ensureVolume` list-then-reuse behavior; new config volumes are created, existing ones reused. No git re-clone and no `git pull` inside the volume.
- **Q:** Does rebuild run the full create path?
  **A:** Yes, with parity to `up`/`clone` fresh create: hostRequirements preflight (fail on shortfall), rosetta consent gate + Features fetch/build with derived-tag reuse when material unchanged, `--skip-pull` honored, onCreate → updateContent → postCreate → postStart with delete-on-fail (of the **new** container), settings apply (not gated), then `--vscode` → open success → extensions apply → postAttach (fail-keep). Volume mode additionally re-injects `git:1` via `FeatureGitEnsure` (clone parity) and re-applies `ensureWorkspaceWritableByRemoteUser` only when the effective `remoteUser` differs from the stamped `devcontainer.remote_user`.
- **Q:** When is the old container deleted?
  **A:** Ordering guarantee: config read + resolution + hostRequirements + Features build complete **before** the old container is deleted. Any failure up to that point leaves the old container running/untouched. After delete, failures follow `up --recreate` semantics: delete-on-fail of the new container plus a status warning that the old container was already removed.
- **Q:** What output and flags are supported?
  **A:** `--json` machine-readable output (parity with `up`/`clone`), exit codes 0/non-zero, `--skip-pull` and `--vscode` supported. Volume-mode `enableSSHForward` on `CreateRequest.fromVolumeMode` only when a host ssh-agent is present (parity with the clone HTTPS branch).
- **Q:** How strict is the config read versus `PostAttachConfigLoader`?
  **A:** Rebuild uses the same dual-mode reader mechanism but with **strict** semantics: unreadable/missing config is a structured `CLIError` (`config_not_found` / `config_parse`), never a silent nil. Design decision point: a shared `ConfigReader` with strict vs best-effort modes is chosen in `design.md` (with rationale) so `PostAttachConfigLoader` keeps its tolerant behavior.