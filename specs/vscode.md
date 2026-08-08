# adevcontainer — VS Code Integration Specification

## Purpose

VS Code integration: manual attach acceptance, optional `--vscode` best-effort open, postAttachCommand gating after successful open, and CLI apply of config-file `customizations.vscode` settings/extensions (soft-fail, idempotent marker).

## Requirements

### Requirement: VS Code attach acceptance

MVP acceptance for editor integration is:

1. **Manual attach (unchanged core):** After `up` (and equivalently after `clone` / when a managed container is running), the container is running and listable/inspectable so the user can manually use experimental **Attach to Running Apple Container**. The CLI MUST NOT claim full Dev Containers extension parity and MUST NOT fail `up` (or `clone` / `start`) solely because VS Code did not auto-attach or because an optional open was not requested.

2. **Optional best-effort open (additive):** When the user passes `--vscode` on `up`, `start`, or `clone`, the CLI MUST attempt a best-effort open of a new VS Code window on the resolved remote workspace folder per **VS Code best-effort open**. Open failure MUST be soft (warn; lifecycle success preserved **by itself**). Without `--vscode`, no automatic open is required.

3. **CLI attach hook for postAttach:** A successful best-effort open under `--vscode` is the product’s CLI attach hook for gating `postAttachCommand` (see **postAttachCommand policy (CLI-only)**). This is an approximation of IDE attach, not confirmation that the remote session is fully ready.

4. **CLI apply of config-file vscode customizations (additive):** The CLI MUST apply parseable config-file `customizations.vscode.settings` on create-path (not gated on open) and MUST apply parseable `customizations.vscode.extensions` after successful `--vscode` open, per the apply requirements. Manual attach without `--vscode` does not receive CLI extension install. Apply failures are soft-fail and MUST NOT be presented as full Dev Containers parity.

#### Scenario: Running container is attachable target
- Given a successful `up` (or `clone`)
- When the user lists/inspects containers via the CLI
- Then the workspace container is identifiable for manual VS Code attach

#### Scenario: Optional open does not replace manual attach
- Given a successful lifecycle without or with `--vscode`
- When the user chooses not to rely on automatic open (flag omitted, or open soft-failed)
- Then list/inspect still expose enough identity for manual experimental attach
- And the CLI documentation MUST NOT state that full Dev Containers extension parity is provided

#### Scenario: customizations apply does not claim IDE parity
- Given docs or help text describing vscode customizations apply
- When a user reads product documentation for this behavior
- Then the text MUST NOT claim that manual UI attach or full Dev Containers extension-driven apply is implemented
- And it MUST describe soft-fail and the `--vscode` gate for extensions

---

### Requirement: Optional `--vscode` flag on up, start, and clone

The CLI MUST accept an optional boolean flag `--vscode` on:

- `adevcontainer up`
- `adevcontainer start`
- `adevcontainer clone`

When `--vscode` is **absent**, those commands MUST behave as today for editor open (no automatic editor open). When `--vscode` is **present**, after the command’s container lifecycle succeeds and the managed container is running (or already running for a start no-op), the CLI MUST attempt a **best-effort** open of a **new** VS Code window attached to that container at the **resolved remote workspace folder** (see VS Code best-effort open). postAttach gating after that open is specified under **postAttachCommand policy (CLI-only)**.

Unknown or misspelled variants that are not the product flag MUST continue to fail closed per existing usage rules. `--vscode` MUST be combinable with other valid flags for those commands (including `--json` where applicable).

#### Scenario: up with --vscode opens editor on remote workspace folder
- Given a successful `adevcontainer up` path that yields a running managed container and a resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer up … --vscode` (with host `code` available and launch succeeding, or mocks equivalent)
- Then after lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And the overall command still reports lifecycle success when open succeeds and postAttach is absent or exits 0

#### Scenario: start with --vscode opens after managed start
- Given a managed container that `adevcontainer start` can select (`--name` or picker) and that is running after start (including already-running no-op success)
- When the user runs `adevcontainer start … --vscode`
- Then after start success the CLI attempts to open a new VS Code window attached to that container at the resolved remote workspace folder from labels/inspect
- And start lifecycle success is unchanged by a successful open when postAttach is absent or exits 0

#### Scenario: clone with --vscode opens after volume-mode create
- Given a successful `adevcontainer clone <git-url>` that yields a running managed container and resolved `remoteWorkspaceFolder`
- When the user runs `adevcontainer clone <git-url> --vscode`
- Then after clone lifecycle success the CLI attempts to open a new VS Code window attached to that container at the resolved `remoteWorkspaceFolder`
- And clone lifecycle success is unchanged by a successful open when postAttach is absent or exits 0

#### Scenario: without --vscode behavior unchanged
- Given any valid `up`, `start`, or `clone` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of that command
- And manual attach (list/inspect + experimental Attach to Running Apple Container) remains valid

#### Scenario: --json works with --vscode
- Given a successful `up` or `clone` with both `--json` and `--vscode`
- When lifecycle completes successfully and open succeeds and postAttach is absent or exits 0
- Then stdout machine-readable success JSON (shape and fields for that command) remains unchanged by the open side effect
- And open progress or soft-fail warnings MUST NOT corrupt that JSON (warnings/progress on stderr per existing StatusPrinter norms)

---

### Requirement: VS Code best-effort open

When `--vscode` is set and lifecycle has succeeded, the CLI MUST attempt to open VS Code such that:

1. A **new** window is requested (not solely attaching into an arbitrary existing window without folder context).
2. The attachment targets the **managed container** that the command just created, started, or confirmed running.
3. The opened folder is the **resolved remote workspace folder** for that container:
   - Prefer the command’s success result `remoteWorkspaceFolder` when available (`up` / `clone`).
   - For `start`, use inspect/labels: `devcontainer.workspace_folder` (and related inspect fields) already stamped at create.
   - The open path MUST NOT re-parse raw `devcontainer.json` alone to invent a folder. Omit/empty `workspaceFolder` in config is already resolved by the product to the default `/workspaces/<basename>` (bind: host workspace basename; clone: git URL repo basename) and that resolved value MUST be what open uses.
4. Image ref and container id needed for the remote attachment MUST come from create/inspect (or equivalent runtime) results appropriate to the command path — not from user-typed freeform strings beyond normal selection (`--name` / picker / create identity).

**Soft-fail (MUST):**

- If no usable VS Code CLI (`code`) is found, or the open/launch fails for any reason (including missing id, image, or folder inputs needed to build the URI), the CLI MUST:
  - Emit a clear warning on stderr (naming the missing dependency or failure at a high level), and
  - **MUST NOT** change the lifecycle command’s success exit solely because open failed, and
  - **MUST NOT** tear down or alter the container as a consequence of open failure, and
  - **MUST NOT** execute postAttach solely because of that soft-failed open (see postAttachCommand policy).
- The product MAY warn when `code` is missing; it MUST NOT hard-require VS Code for `up` / `start` / `clone` success.

**Host prerequisites (document; soft):**

- VS Code, extension `ms-vscode-remote.remote-containers`, and experimental Apple Container support (`dev.containers.experimentalAppleContainerSupport`) are host prerequisites for a useful open. The CLI SHOULD document them in help and/or README. The CLI MUST NOT claim that `--vscode` provides full Dev Containers extension parity (up/rebuild driver, extension clone-in-volume, etc.).

**Optional nameConfig (MAY/SHOULD):**

- The CLI MAY write a Remote - Containers nameConfig for the container (workspace folder + remote user) when low-risk and useful for attach defaults. Folder-uri open remains the **required** open path; nameConfig MUST NOT be the sole mechanism and MUST NOT cause lifecycle failure if the write fails.

**Approximation (document):**

- Successful host `code` launch is a **CLI-initiated attach approximation**. The CLI MUST NOT wait for VS Code Server fully ready or for IDE-confirmed remote attach before treating open as success for postAttach gating. Detecting manual UI attach is out of scope.

#### Scenario: omitted workspaceFolder uses product default already resolved
- Given a config that omits `workspaceFolder` (or leaves it empty) so resolve yields the product default `/workspaces/<basename>`
- When the user runs `up` or `clone` with `--vscode` after successful lifecycle
- Then the open targets that already-resolved default folder (e.g. `/workspaces/<basename>`), not an empty path and not a re-parse of raw JSON that bypasses the resolver

#### Scenario: soft-fail when code CLI missing
- Given lifecycle would otherwise succeed and `--vscode` is set
- When no usable `code` executable is discoverable on the host
- Then the command still exits successfully for the lifecycle outcome (when postAttach does not run)
- And a stderr warning indicates that VS Code open was skipped or failed because `code` was not found
- And the managed container remains running / created as the lifecycle commanded
- And postAttach MUST NOT execute

#### Scenario: soft-fail when launch fails
- Given lifecycle success, `--vscode` set, and a discoverable `code` that fails when invoked for open
- When open/launch returns failure
- Then the lifecycle command still reports success (when postAttach does not run)
- And a stderr warning indicates the open failure
- And the managed container is not deleted or stopped solely due to that failure
- And postAttach MUST NOT execute

#### Scenario: explicit workspaceFolder is honored for open
- Given a config with an explicit resolved `workspaceFolder` (e.g. `/custom/ws`)
- When `up` or `clone` succeeds with `--vscode`
- Then the open targets `/custom/ws` (the resolved remote workspace folder), not the default `/workspaces/<basename>`

---

### Requirement: postAttachCommand policy (CLI-only)

The CLI MUST parse and admit `postAttachCommand` when present (string or argv array) so configs are not rejected solely for this property. Invalid form (non-string, non-array) MUST still fail resolve with a structured error naming `postAttachCommand` (unchanged).

**When postAttach RUNS**

The CLI MUST execute postAttach only when **all** of the following hold on `up`, `start`, or `clone`:

1. `--vscode` is set, and
2. The best-effort VS Code open outcome is **success** (host `code` launch succeeded per **VS Code best-effort open**).

That successful open is the **CLI attach hook**. Execution MUST occur **after** the successful open attempt completes — never before open when `--vscode` is set.

**What runs**

When the run gate is satisfied, the CLI MUST run:

- Config `postAttachCommand` when present, then
- Feature-contributed postAttach commands (`featurePostAttachCommands` / equivalent merge), in the same merge/order patterns as other feature lifecycle hooks already in product (LifecycleRunner conventions: config hook then feature hooks for that stage).

Each command MUST execute via existing container **exec** lifecycle machinery (same shell-vs-argv rules as `postCreateCommand` / `postStartCommand`), using effective `remoteUser` when set and the resolved workspace folder when set.

**When postAttach is SKIPPED (status line, not executed)**

- **`--vscode` absent** (manual attach path / no CLI attach): if any postAttach is present (config and/or features), the CLI MUST emit a single stderr status line indicating attach is not hooked (e.g. `postAttach skipped (no attach hook)` or a clearer equivalent) and MUST NOT execute postAttach.
- **`--vscode` set but open soft-failed or skipped** (missing `code`, launch fail, missing id/image/folder, or other soft-fail open outcome): the CLI MUST NOT execute postAttach. The CLI SHOULD emit a skip status explaining that attach open did not succeed (in addition to the open soft-fail warning as applicable).
- **No postAttach present** (config and features empty): the CLI MUST NOT emit a postAttach skip line.

**Failure policy**

- If postAttach **runs** and any postAttach command exits non-zero, the lifecycle command (`up` / `start` / `clone`) MUST fail (non-zero) with a clear structured error naming postAttach (property label consistent with other lifecycle hooks, including feature-labeled forms when applicable).
- The CLI MUST NOT delete or stop the container solely due to postAttach failure (container already successfully brought up; VS Code may already be opening). This contrasts with create-path onCreate / updateContent / postCreate / first-create postStart delete-on-fail.
- Open soft-fail still MUST NOT fail the lifecycle command **by itself**. postAttach failure after successful open **does** fail the lifecycle exit.
- On postAttach failure, the command MUST follow the existing error path (no success JSON on stdout for `--json` paths).

**Approximation caveat**

Running postAttach after successful host `code` launch is a **CLI-initiated attach approximation**. The product MUST NOT require IDE-confirmed remote ready, MUST NOT wait for VS Code Server fully ready, and MUST NOT treat manual UI attach as a postAttach trigger. Full IDE attach event integration remains out of scope beyond this gate.

**Consistency**

The gated policy MUST apply consistently on `up`, `start`, and `clone`. Presence of `postAttachCommand` alone MUST NOT fail those commands when postAttach is skipped.

#### Scenario: postAttach runs after successful --vscode open
- Given a valid config with `postAttachCommand` that exits 0, and a successful container lifecycle on `up` (or equivalently `start` / `clone`)
- When the user runs the command with `--vscode` and host `code` launch succeeds (or mocks equivalent)
- Then after the successful open the CLI executes `postAttachCommand` via container exec
- And the command reports lifecycle success
- And success JSON shape (when `--json`) remains unchanged

#### Scenario: postAttach skipped without --vscode
- Given a valid minimal image config that also sets `postAttachCommand` to a command that would exit non-zero if run
- When the user runs `up` (fresh create) without `--vscode`
- Then `up` succeeds without executing `postAttachCommand`
- And stderr includes a one-time skip status for postAttach (e.g. no attach hook)

#### Scenario: postAttach skipped when open soft-fails
- Given a config with `postAttachCommand` present and lifecycle that would otherwise succeed
- When the user runs `up` (or `start` / `clone`) with `--vscode` and open soft-fails (missing `code`, launch failure, or missing open inputs)
- Then the CLI MUST NOT execute `postAttachCommand`
- And the lifecycle command still exits successfully
- And stderr includes open soft-fail warning and SHOULD include a postAttach skip status explaining attach open did not succeed
- And the managed container is not deleted or stopped solely due to open soft-fail

#### Scenario: postAttach failure fails command but keeps container
- Given lifecycle success, `--vscode` set, successful open, and `postAttachCommand` that exits non-zero
- When the user runs `up` (or `start` / `clone`)
- Then the command fails with a structured error naming postAttach
- And the managed container still exists and is not deleted or stopped solely due to that postAttach failure
- And no success JSON is emitted on the error path

#### Scenario: feature postAttach runs after successful open
- Given resolved config with feature-contributed postAttach commands (and optional config `postAttachCommand`) and successful open under `--vscode`
- When postAttach runs
- Then feature postAttach commands execute via container exec after the config hook when both are present (same merge/order spirit as other feature lifecycle hooks)
- And non-zero exit of a feature postAttach fails the command under the same keep-container failure policy as config postAttach

#### Scenario: Invalid postAttach form still fails resolve
- Given `postAttachCommand` set to a non-string, non-array value
- When config is resolved
- Then the CLI fails with a structured error naming `postAttachCommand`

#### Scenario: no skip line when postAttach absent
- Given a config with no `postAttachCommand` and no feature-contributed postAttach commands
- When the user runs `up` without or with `--vscode`
- Then the CLI MUST NOT emit a postAttach skip status line solely for postAttach

---

### Requirement: Parse and retain customizations.vscode extensions and settings

The CLI MUST parse config-file `customizations.vscode` when present and, when the nested shapes are well-formed, MUST retain:

- **`extensions`**: an array of non-empty string extension IDs (e.g. `swiftlang.swift-vscode`). Entries that are not strings MUST be skipped for apply purposes; the CLI SHOULD warn once when skipping malformed entries.
- **`settings`**: a JSON object of VS Code settings keys to values. If `settings` is present but not an object, the CLI MUST soft-skip settings apply for that resolve (SHOULD warn) and MUST NOT fail whole-config resolve solely for that reason when `customizations.vscode` itself is an object.

Presence of a `customizations.vscode` object continues to signal VS Code-oriented intent. The resolved model MUST expose retained extensions and settings to lifecycle apply paths (not only a boolean “has vscode customizations” flag).

**Admission / resilience**

- Top-level `customizations` MUST remain an object when present (wrong type still fails resolve with a structured error naming `customizations` — unchanged).
- When `customizations.vscode` is an object, the CLI MUST NOT fail whole-config resolve solely because nested `extensions` or `settings` have unexpected types; those nested malformations MUST soft-skip the corresponding apply with a clear warning.
- When `customizations.vscode` is present but not an object, the CLI MUST NOT fail whole-config resolve solely for that reason (treat as no applyable vscode customizations; MAY warn).
- Unknown keys under `customizations.vscode` MAY be ignored.
- Other `customizations.*` namespaces remain non-applied metadata (MUST NOT fail parse).

**Identity**

- Retained extensions and settings MUST NOT participate in create identity / config hash material. Editing only `customizations.vscode` MUST NOT by itself force container recreate via identity drift; apply idempotency (marker hash) handles re-apply inside an existing container.

**Merge source (v1)**

- v1 MUST apply only config-file `customizations.vscode` from the resolved devcontainer config used for the command path.
- Feature-contributed customizations and image `devcontainer.metadata` customizations merge are out of scope for this requirement.

#### Scenario: well-formed extensions and settings are retained
- Given a valid minimal image config with `customizations.vscode.extensions` as a string-ID array and `customizations.vscode.settings` as a JSON object
- When config is resolved
- Then resolve succeeds
- And the resolved model retains those extension IDs and settings for later apply

#### Scenario: malformed nested extensions does not fail resolve
- Given a valid minimal image config where `customizations.vscode` is an object and `extensions` is not an array (e.g. a string)
- When config is resolved
- Then resolve succeeds
- And extensions apply is soft-skipped (no hard resolve failure solely for that nested type)

#### Scenario: malformed nested settings does not fail resolve
- Given a valid minimal image config where `customizations.vscode` is an object and `settings` is not an object (e.g. an array)
- When config is resolved
- Then resolve succeeds
- And settings apply is soft-skipped (no hard resolve failure solely for that nested type)

#### Scenario: customizations stay outside create identity hash
- Given two configs that differ only in `customizations.vscode.extensions` or `settings`
- When create identity / config hash material is computed
- Then the identity hash is unchanged solely due to that customizations difference

#### Scenario: empty or absent vscode customizations
- Given a config with no `customizations` key, or `customizations` without a usable `vscode` object, or empty extensions and empty/absent settings
- When config is resolved and lifecycle runs
- Then no vscode customizations apply work is required
- And the CLI MUST NOT emit apply-failure warnings solely for absence

---

### Requirement: Apply vscode settings on create-path (and repair on drift)

When resolved config retains a non-empty well-formed `customizations.vscode.settings` object (or when marker drift requires re-apply of the normalized payload that includes settings), the CLI MUST attempt to merge those settings into the guest **remote Machine** settings file for the effective remote user:

- Target path concept: under the effective `remoteUser` home, `~/.vscode-server/data/Machine/settings.json` (create parent directories as needed).
- Merge semantics: deep-merge or key-merge such that config-declared keys are written into the Machine settings object without wiping unrelated keys already present when feasible; on missing file, create a valid settings JSON object containing at least the declared keys.

**When settings apply RUNS**

1. **Fresh create-path** on `up` and `clone`: after create-path lifecycle hooks for that path have completed successfully (onCreate → updateContent → postCreate → postStart as applicable to the path), and **before** optional `--vscode` open / postAttach.
2. **start / reuse** paths: when config can be loaded and the guest marker indicates the normalized customizations hash does **not** match (drift or never applied), the CLI SHOULD attempt settings repair (and marker update on full successful apply of the normalized payload) without requiring `--vscode`.

**Gates that MUST NOT apply**

- Settings apply MUST NOT be gated on `--vscode`.
- Settings apply MUST NOT require a successful editor open.
- Settings apply MUST NOT run as part of image build or Features Dockerfile generation.

**Soft-fail (MUST)**

- If settings merge fails for any reason (exec failure, permission, disk, invalid existing JSON that cannot be repaired safely, missing user home, etc.), the CLI MUST:
  - Emit a clear warning on stderr, and
  - **MUST NOT** change the lifecycle command’s success exit solely because settings apply failed, and
  - **MUST NOT** delete or stop the container solely due to settings apply failure.
- Soft-fail settings apply is **not** the same policy as postAttach fail-keep: postAttach non-zero still fails the command when postAttach runs.

**Idempotency**

- Settings apply participates in the shared customizations marker/hash (see **Vscode customizations apply idempotency**). When the marker hash already matches the normalized payload, the CLI MUST skip redundant settings write work for that payload.

#### Scenario: settings merge on fresh up create without --vscode
- Given a valid config with well-formed non-empty `customizations.vscode.settings` and a fresh `up` create-path that completes create-path hooks successfully
- When the user runs `up` **without** `--vscode`
- Then the CLI attempts to merge settings into the guest Machine settings path under the effective remote user home
- And `up` still reports lifecycle success when settings apply soft-fails or succeeds
- And the managed container is not deleted solely due to settings apply failure

#### Scenario: settings merge on fresh clone create
- Given a valid clone path with well-formed non-empty `customizations.vscode.settings` and successful create-path hooks
- When the user runs `clone`
- Then the CLI attempts the same Machine settings merge after create-path hooks
- And soft-fail does not fail `clone` or delete the container/volume solely due to settings apply

#### Scenario: settings not gated on open success
- Given well-formed settings and create-path success
- When `--vscode` is omitted or open soft-fails
- Then settings apply still runs (or already ran) on create-path per this requirement
- And extensions apply remains subject to the open gate (see extensions requirement)

#### Scenario: settings soft-fail keeps lifecycle success
- Given create-path would otherwise succeed and settings merge is forced to fail (e.g. mocked exec failure)
- When settings apply runs
- Then stderr includes a warning about settings apply
- And the lifecycle command exit remains success (absent unrelated failures)
- And the container is not deleted or stopped solely due to that failure

#### Scenario: reuse/start repairs settings on marker drift
- Given a running managed container whose guest marker hash does not match the normalized customizations from loadable config (e.g. config settings edited on host without recreate)
- When the user runs `start` or an `up` reuse path that loads config
- Then the CLI attempts settings repair according to the drifted payload
- And soft-fail policy still applies

---

### Requirement: Apply vscode extensions after successful --vscode open

When resolved config retains one or more well-formed extension IDs, the CLI MUST attempt to install any **missing** IDs into the guest remote VS Code Server extensions directory under the effective `remoteUser` home (conceptually under `~/.vscode-server/extensions` or the product-equivalent remote extensions location).

**When extensions apply RUNS**

On `up`, `start`, and `clone`, extensions apply MUST run only when **all** of the following hold:

1. At least one well-formed extension ID is retained (or the normalized payload pending apply includes extensions), and
2. `--vscode` is set, and
3. The best-effort VS Code open outcome is **success** (host `code` launch succeeded per **VS Code best-effort open**), and
4. Idempotency says apply is still needed (marker missing or hash drift — see **Vscode customizations apply idempotency**).

That successful open is the same **CLI attach hook** approximation used for postAttach gating. Extensions apply MUST occur **after** successful open and **MUST NOT** use `postAttachCommand` as the delivery vehicle.

**Order relative to postAttach**

- After open success: run extensions apply (soft-fail), **then** run postAttach per existing **postAttachCommand policy (CLI-only)** (unchanged fail-keep).
- Extensions apply failure MUST NOT by itself skip or fail postAttach; postAttach gating remains solely open-success + presence as specified today.
- Extensions apply MUST NOT run before open when `--vscode` is set.

**When extensions apply is SKIPPED**

- `--vscode` absent (including manual Attach without the flag): MUST NOT install extensions via the CLI; MUST NOT fail the command solely because extensions were not applied.
- `--vscode` set but open soft-failed/skipped: MUST NOT install extensions for that invocation.
- No well-formed extension IDs retained: no extensions install work.
- Marker hash already matches normalized payload (including extensions): MUST skip redundant install work.

**Install behavior**

- Already-installed IDs (folder present in the remote extensions directory with matching identity **and** listed in the Server registry — see **registry visibility** below) MUST be treated as satisfied for that ID. Folder-only without a registry entry is **not** complete: the CLI MUST upsert the registry for that ID.
- The CLI SHOULD prefer an apply mechanism that does **not** require waiting for VS Code Server fully ready when a VSIX download + unpack (or equivalent) path is viable.
- **Transfer path (v1):** host marketplace VSIX download, copy into the guest via tar-pipe (or equivalent directory copy that does **not** embed multi-MB payloads in exec argv/base64), then guest unzip into the extensions directory.
- Marketplace/network/permission failures are soft-fail (below).

**Registry visibility (MUST)**

- Install of an extension ID is **not complete** until the VS Code Server extensions registry file under the remote extensions directory (`~/.vscode-server/extensions/extensions.json` or product-equivalent) lists that extension so the remote UI shows it as installed.
- After each successful unpack (or when a matching folder already exists but is unregistered), the CLI MUST upsert a registry entry for that extension (by identifier id, case-insensitive).
- When the registry was modified, the CLI SHOULD best-effort invalidate the Server extensions user cache (e.g. remove `~/.vscode-server/data/CachedProfilesData/__default__profile__/extensions.user.cache` when present) so a reload can pick up the registry without a full Server reinstall.
- Users MAY need **Developer: Reload Window** once after first apply for the UI to refresh; the CLI is not required to force a reload.

**Transitive `extensionDependencies` (MUST)**

- After each installed (or already-present) extension is processed, the CLI MUST attempt to install that package’s `package.json` `extensionDependencies` string IDs **transitively** (breadth-first or equivalent), with a **cycle guard** (visited bare `publisher.name` set) so mutual or repeated deps do not loop forever.
- Each dependency ID follows the same install + registry rules and the same per-ID soft-fail as config-listed IDs.
- Soft-fail of one dependency ID MUST NOT by itself abort processing of other queued IDs.
- **Marker hash remains config-only:** the normalized payload hash MUST include only config-file extension IDs (+ settings). Transitive dependency installs are side effects of listed IDs and MUST NOT expand the marker hash input. A matching marker still means “config payload already applied”; deps are installed as part of that apply when the payload is pending, not as separate config entries.

**Soft-fail (MUST)**

- If extension install fails for any reason (network, unpack, permission, partial failure of one ID), the CLI MUST:
  - Emit a clear warning on stderr (naming failure at a high level; MAY name the failing ID when known), and
  - **MUST NOT** change the lifecycle command’s success exit solely because extensions apply failed, and
  - **MUST NOT** delete or stop the container solely due to extensions apply failure.
- Partial success (some IDs installed, some failed) MUST still follow soft-fail exit policy; the CLI SHOULD warn about failures and MAY update the marker only when the full normalized payload apply completed successfully (see idempotency). Soft-fail of a transitive dependency counts as partial failure for marker finalization when that ID was required for a successful full apply of the pending work for this invocation.

**Contrast with postAttach**

- Soft-fail extensions apply ≠ postAttach fail-keep. postAttach non-zero after a run still fails the lifecycle command and keeps the container.

#### Scenario: extensions install after successful --vscode open on up
- Given a valid config with well-formed `customizations.vscode.extensions`, successful create-path, and no matching guest marker
- When the user runs `up --vscode` and host `code` launch succeeds
- Then after open success the CLI attempts to install missing extension IDs into the remote extensions directory under the effective remote user home
- And each successfully installed ID is listed in the guest `extensions.json` registry (not folder-only)
- And then postAttach runs per existing policy when present
- And lifecycle success is preserved when extensions apply soft-fails (absent postAttach failure)

#### Scenario: folder unpack alone is not UI-visible without registry
- Given an extension folder already exists under the remote extensions directory but `extensions.json` does not list that extension (registry empty or missing entry)
- When extensions apply runs for that ID (open gate satisfied, marker pending)
- Then the CLI upserts the registry entry for that ID (and SHOULD invalidate extensions user cache when registry changes)
- And install is treated complete for that ID only after registry listing succeeds (folder-only is insufficient)

#### Scenario: transitive extensionDependencies install (Swift → lldb-dap style)
- Given config lists `swiftlang.swift-vscode` (or equivalent) whose unpacked `package.json` declares a hard `extensionDependencies` entry such as `llvm-vs-code-extensions.lldb-dap`
- When extensions apply runs successfully for the config-listed ID
- Then the CLI attempts install of the dependency ID (and further transitive deps) with cycle guard
- And dependency failures soft-fail per ID without failing lifecycle solely due to apply
- And the marker hash input still contains only the config-listed extension IDs (plus settings), not the transitive dependency IDs as extra config entries

#### Scenario: extensions skipped without --vscode
- Given well-formed extensions in config
- When the user runs `up` (or `start` / `clone`) **without** `--vscode`
- Then the CLI MUST NOT install those extensions on that invocation
- And settings may still have been applied on create-path
- And the command is not failed solely because extensions were not applied

#### Scenario: extensions skipped when open soft-fails
- Given well-formed extensions and lifecycle that would otherwise succeed
- When the user runs with `--vscode` and open soft-fails
- Then the CLI MUST NOT install extensions for that invocation
- And lifecycle success is unchanged by open soft-fail alone
- And postAttach remains skipped per existing policy

#### Scenario: extensions soft-fail keeps lifecycle success
- Given open success under `--vscode` and extension install forced to fail
- When extensions apply runs
- Then stderr includes a warning
- And the lifecycle command exit remains success when postAttach is absent or exits 0
- And the container is not deleted or stopped solely due to extensions apply failure

#### Scenario: start with --vscode applies pending extensions
- Given a managed container where settings may already be applied but extensions are still pending (marker missing/drift) and config loads via start config-load paths
- When the user runs `start --vscode` and open succeeds
- Then the CLI attempts pending extensions install after open success
- And soft-fail and idempotency policies apply

#### Scenario: postAttach still fail-keep after extensions apply
- Given open success, extensions apply soft-fails or succeeds, and `postAttachCommand` exits non-zero
- When the user runs `up --vscode` (or start/clone equivalent)
- Then the command fails naming postAttach
- And the container is kept
- And extensions apply soft-fail did not by itself cause that command failure

#### Scenario: manual attach without flag does not apply extensions
- Given well-formed extensions and a running container
- When the user attaches via experimental UI without using `--vscode` on a CLI command
- Then the CLI has not applied extensions solely due to that manual attach (same attach-hook limitation class as postAttach)

---

### Requirement: Vscode customizations apply idempotency

The CLI MUST record successful application of the **normalized** customizations payload (ordered **config-file** extension IDs + canonicalized settings JSON) using a guest marker file under the effective remote user home, e.g. `$HOME/.adevcontainer/vscode-customizations.applied`, whose content is a stable content hash of that normalized payload.

**Rules**

1. Before apply work, the CLI SHOULD read the marker (if present) and compare to the hash of the current normalized payload from resolved/loadable config.
2. When the marker hash **matches**, the CLI MUST skip redundant settings merge and extensions install for that payload.
3. When the marker is **missing** or the hash **differs** (config edited without recreate), the CLI MUST treat apply as pending and run the applicable apply steps (settings per settings requirement; extensions only when the open gate is satisfied).
4. The CLI MUST write/update the marker to the new hash only after the apply steps required for that invocation’s pending work have completed successfully for the full normalized payload. If only settings could run (no open) and extensions remain pending, the CLI MUST NOT claim full-payload success in the marker until extensions are also successfully applied **or** the normalized payload has no extensions. (If payload has both settings and extensions: settings-only success on create-path without open leaves extensions pending — marker MUST NOT match full payload until extensions succeed on a later open, unless product chooses a split marker; v1 MUST ensure extensions still run on first successful open when not yet applied. A single marker for the full payload is acceptable if create-path settings re-merge remains safe/idempotent when extensions later complete and then the full hash is written.)
5. Apply MUST NOT blindly re-run on every postAttach or every successful open when the marker already matches.
6. Marker hash input MUST NOT include transitive `extensionDependencies` IDs discovered at install time — only config-listed extension IDs (normalized) and settings. Transitive installs remain side effects of applying listed IDs when apply runs.

**Normalization**

- Extension IDs MUST be normalized stably (e.g. trim; stable sort for hash input) from the **config-file** list only.
- Settings MUST be canonicalized stably for hash input (stable key order / deterministic JSON serialization).

#### Scenario: matching marker skips re-apply
- Given a guest marker whose hash matches the normalized extensions+settings from config
- When the user runs `up --vscode` (or start/clone) with open success
- Then the CLI skips redundant settings merge and extensions install for that payload
- And does not fail solely due to skip

#### Scenario: hash drift re-applies
- Given a guest marker that does not match the current normalized payload (e.g. extension ID added in config without recreate)
- When a path runs that can apply (settings on create/reuse/start load; extensions on open success)
- Then the CLI attempts apply for the drifted payload per the settings and extensions requirements
- And updates the marker only according to successful full-payload completion rules above

#### Scenario: not every open blindly reinstalls
- Given a matching marker after a prior successful full apply
- When the user runs `start --vscode` again with open success
- Then extensions are not reinstalled solely because open succeeded again

---

### Requirement: Vscode customizations apply is not image build

Applying `customizations.vscode` MUST occur against a **running** (or just-created and running) managed container via guest filesystem/exec operations. The CLI MUST NOT treat vscode extensions/settings apply as part of Features image build, Dockerfile generation, or base image mutation for v1.

#### Scenario: features build path unchanged by customizations apply
- Given a config with both `features` and `customizations.vscode`
- When Features runner builds/reuses a derived image
- Then image build identity and Dockerfile generation are not required to embed those vscode extensions/settings solely to satisfy this change
- And apply still occurs via the runtime apply requirements above

