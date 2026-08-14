# Change Spec: vscode-customizations-up-clone-rebuild

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply. `--vscode` open and realized **postAttachCommand policy (CLI-only)** (CLI attach model) remain in force; this change MUST NOT re-gate postAttach on `--vscode` or lock `start` as runtime-only / no postStart. **Vscode customizations apply is not image build** remains in force unchanged. `start` MUST NOT apply vscode customizations.

## ADDED Requirements

### Requirement: Apply vscode extensions on up, clone, and rebuild

When resolved config retains one or more well-formed extension IDs, the CLI MUST attempt to install any **missing** IDs into the guest remote VS Code Server extensions directory under the **resolved remote connection user** home (conceptually under `~/.vscode-server/extensions` or the product-equivalent remote extensions location) — not create-only `containerUser` when `remoteUser` differs.

**When extensions apply RUNS**

On `up`, `clone`, and `rebuild` only, extensions apply MUST run when **all** of the following hold:

1. At least one well-formed extension ID is retained (or the normalized payload pending apply includes extensions), and
2. The command is `adevcontainer up`, `adevcontainer clone`, or `adevcontainer rebuild` (fresh create-path, `up` reuse of a running matching container, or `up` start-stopped), and
3. Idempotency says apply is still needed (marker missing or hash drift — see **Vscode customizations apply idempotency**).

Extensions apply MUST NOT be gated on `--vscode`. Extensions apply MUST NOT be gated on open success. Open omitted or soft-fail MUST NOT prevent extensions apply on `up` / `clone` / `rebuild`. Extensions apply MUST NOT use `postAttachCommand` as the delivery vehicle.

**Timing**

1. **Fresh create-path** on `up`, `clone`, and `rebuild`: after create-path lifecycle hooks for that path have completed successfully (onCreate → updateContent → postCreate → postStart as applicable), and **before** optional `--vscode` open / postAttach.
2. **`up` reuse** (running, matching identity/hash) and **`up` start-stopped** (after `postStartCommand` when that hook runs): when config is loadable and apply is still needed, the CLI MUST attempt extensions apply without requiring `--vscode`, then optional open / postAttach as today.

**Order relative to open and postAttach**

- On `up` / `clone` / `rebuild` with `--vscode`: run extensions apply (soft-fail) **before** best-effort open, **then** open, **then** postAttach per realized **postAttachCommand policy (CLI-only)** (fail-keep; CLI attach is not gated on open success).
- On `up` / `clone` / `rebuild` without `--vscode`: run extensions apply; MUST NOT open; postAttach follows realized **postAttachCommand policy (CLI-only)**.
- Extensions apply failure MUST NOT by itself skip or fail open or postAttach; postAttach remains as specified in the realized policy.
- Extensions apply MAY complete (and finalize the marker when full apply succeeds) even when `--vscode` is absent or open later soft-fails.

**When extensions apply is SKIPPED**

- Command is `adevcontainer start` (with or without `--vscode`, including already-running no-op): MUST NOT install extensions via the CLI on that invocation.
- Manual experimental UI attach by itself: MUST NOT install extensions solely because the user attached.
- No well-formed extension IDs retained: no extensions install work.
- Marker hash already matches normalized payload (including extensions): MUST skip redundant install work.

**Install behavior (unchanged mechanism)**

- Already-installed IDs (folder present in the remote extensions directory with matching identity **and** listed in the Server registry — see **registry visibility** below) MUST be treated as satisfied for that ID. Folder-only without a registry entry is **not** complete: the CLI MUST upsert the registry for that ID.
- The CLI SHOULD prefer an apply mechanism that does **not** require waiting for VS Code Server fully ready when a VSIX download + unpack (or equivalent) path is viable.
- **Transfer path (v1):** host marketplace VSIX download, copy into the guest via tar-pipe (or equivalent directory copy that does **not** embed multi-MB payloads in exec argv/base64), then guest unzip into the extensions directory.
- **Guest-platform VSIX (MUST):** Marketplace download MUST target the **guest/remote** OS/arch (`targetPlatform`), not the host Mac. Multi-arch extensions (e.g. `ms-dotnettools.csharp`, `ms-dotnettools.csdevkit` natives) ship platform-specific VSIX assets; a host (darwin/win32) asset leaves broken natives inside the Linux Apple container guest.
  - Detect guest platform once per extensions apply under the remote connection user context (e.g. `uname -m` + `/etc/os-release`): at least `linux-arm64` / `linux-x64`; `alpine-arm64` / `alpine-x64` when `ID=alpine` is reliably detectable.
  - Version resolve MUST prefer a gallery version row whose `targetPlatform` matches the guest (not blind `versions[0]`). Universal / platform-agnostic rows (missing, empty, `undefined`, or `universal` platform) are an allowed fallback when no exact match exists.
  - The VSIX asset URL MUST include the marketplace platform qualifier (`?targetPlatform=<id>` on the `assetbyname/…VSIXPackage` URL) when the chosen gallery row is **platform-specific**. Universal / platform-agnostic assets MUST **omit** `?targetPlatform=` (Marketplace returns 404 when the query is present on universal assets).
  - If guest platform detection fails or the arch is unsupported, the CLI MUST **soft-fail** extensions apply with a clear warning and MUST **not** silently download a host-platform VSIX.
- Marketplace/network/permission failures are soft-fail (below).
- Apply MUST occur against a **running** (or just-created and running) managed container via guest filesystem/exec operations. The CLI MUST NOT treat vscode extensions apply as part of Features image build, Dockerfile generation, or base image mutation.

**Registry visibility (MUST)**

- Install of an extension ID is **not complete** until the VS Code Server extensions registry file under the remote extensions directory (`~/.vscode-server/extensions/extensions.json` or product-equivalent) lists that extension so the remote UI shows it as installed.
- After each successful unpack (or when a matching folder already exists but is unregistered), the CLI MUST upsert a registry entry for that extension (by identifier id, case-insensitive).
- Registry `metadata.pinned` MUST be **false** by default for bare `publisher.name` IDs and **true** only when the config ID is version-pinned (`publisher.name@version`).
- When the registry was modified, the CLI SHOULD best-effort invalidate the Server extensions user cache (e.g. remove `~/.vscode-server/data/CachedProfilesData/__default__profile__/extensions.user.cache` when present) so the Server can pick up the registry without a full reinstall.
- Install-before-open is intended to make the registry visible on first attach; users MAY still need **Developer: Reload Window** in residual cases. The CLI is not required to force a reload.

**Transitive `extensionDependencies` ∪ `extensionPack` (MUST)**

- After each installed (or already-present) extension is processed, the CLI MUST attempt to install that package’s `package.json` **`extensionDependencies` and `extensionPack`** string IDs **transitively** (breadth-first or equivalent), with a **shared cycle guard** (visited bare `publisher.name` set) covering both fields so mutual or repeated IDs do not loop forever.
- Each dependency or pack-member ID follows the same install + registry rules and the same per-ID soft-fail as config-listed IDs.
- Soft-fail of one dependency or pack-member ID MUST NOT by itself abort processing of other queued IDs (pack and deps share the same soft-fail policy — neither hard-fails lifecycle).
- **Marker hash remains config-only:** the normalized payload hash MUST include only config-file extension IDs (+ settings). Transitive dependency and pack-member installs are side effects of listed IDs and MUST NOT expand the marker hash input. A matching marker still means “config payload already applied”; transitive IDs are installed as part of that apply when the payload is pending, not as separate config entries.

**Soft-fail (MUST)**

- If extension install fails for any reason (network, unpack, permission, partial failure of one ID), the CLI MUST:
  - Emit a clear warning on stderr (naming failure at a high level; MAY name the failing ID when known), and
  - **MUST NOT** change the lifecycle command’s success exit solely because extensions apply failed, and
  - **MUST NOT** delete or stop the container solely due to extensions apply failure.
- Partial success (some IDs installed, some failed) MUST still follow soft-fail exit policy; the CLI SHOULD warn about failures and MAY update the marker only when the full normalized payload apply completed successfully (see idempotency). Soft-fail of a transitive dependency counts as partial failure for marker finalization when that ID was required for a successful full apply of the pending work for this invocation.

**Contrast with postAttach**

- Soft-fail extensions apply ≠ postAttach fail-keep. postAttach non-zero after a run still fails the lifecycle command and keeps the container.

#### Scenario: extensions install on fresh up without --vscode
- Given a valid config with well-formed `customizations.vscode.extensions`, successful create-path hooks, and no matching guest marker
- When the user runs `up` **without** `--vscode`
- Then the CLI attempts to install missing extension IDs into the remote extensions directory under the resolved remote connection user home
- And each successfully installed ID is listed in the guest `extensions.json` registry (not folder-only)
- And the CLI MUST NOT invoke a host VS Code open as part of that command
- And postAttach follows realized **postAttachCommand policy (CLI-only)**
- And lifecycle success is preserved when extensions apply soft-fails (absent unrelated failures)

#### Scenario: extensions install on fresh clone without --vscode
- Given a valid clone path with well-formed extension IDs, successful create-path hooks, and no matching guest marker
- When the user runs `clone` **without** `--vscode`
- Then the CLI attempts the same guest extensions install after create-path hooks
- And soft-fail does not fail `clone` or delete the container/volume solely due to extensions apply
- And the CLI MUST NOT open VS Code solely because extensions were applied
- And postAttach follows realized **postAttachCommand policy (CLI-only)**

#### Scenario: extensions install on rebuild without --vscode
- Given a successful `rebuild` create-path on the new container, well-formed extension IDs, and no matching guest marker
- When the user runs `rebuild` **without** `--vscode`
- Then the CLI attempts guest extensions install after create-path hooks on the **new** container
- And rebuild still reports success when apply soft-fails
- And the CLI MUST NOT open VS Code solely because extensions were applied
- And postAttach follows realized **postAttachCommand policy (CLI-only)**

#### Scenario: extensions still apply on up when --vscode is set
- Given a valid config with well-formed extensions, successful create-path, and no matching guest marker
- When the user runs `up --vscode` and host `code` launch succeeds
- Then the CLI attempts to install missing extension IDs **before** open
- And then open runs, then postAttach runs per existing policy when present
- And lifecycle success is preserved when extensions apply soft-fails (absent postAttach failure)

#### Scenario: start never applies extensions
- Given well-formed extensions, a managed container that `start` can select, and a guest marker missing or drifted
- When the user runs `start` **without** `--vscode`
- Then the CLI MUST NOT install those extensions on that invocation
- And start lifecycle success is unchanged solely because extensions were not applied

#### Scenario: start with --vscode still does not apply extensions
- Given well-formed extensions, a managed container that `start` can select, and a guest marker missing or drifted
- When the user runs `start --vscode`
- Then the CLI MUST NOT install those extensions on that invocation
- And after start success the CLI still attempts best-effort open
- And postAttach follows realized **postAttachCommand policy (CLI-only)**
- And resume hooks still follow realized **Start managed container**

#### Scenario: up reuse applies pending extensions without --vscode
- Given a running managed container whose guest marker hash does not match the normalized customizations from loadable config (e.g. an extension ID added in config without rebuilding)
- When the user runs `up` (matching identity/hash reuse) **without** `--vscode`
- Then the CLI attempts pending extensions install according to the drifted payload
- And soft-fail policy still applies

#### Scenario: up start-stopped applies pending extensions without --vscode
- Given a matching stopped managed container, loadable config with well-formed extensions, and a guest marker missing or drifted
- When the user runs `up` (start-stopped path)
- Then after `postStartCommand` (when present) the CLI attempts pending extensions install
- And `--vscode` is not required for that apply
- And soft-fail policy still applies

#### Scenario: marketplace VSIX targets guest platform not host
- Given a Linux guest (e.g. aarch64 Apple container → `linux-arm64`) and a multi-arch extension ID pending install on `up`
- When extensions apply downloads a marketplace VSIX
- Then version resolve prefers a gallery row whose `targetPlatform` matches the guest (not an arbitrary host/first row)
- And the asset URL includes the guest `targetPlatform` qualifier when that row is platform-specific (universal assets omit the query)
- And the CLI does not silently install a darwin/win32 host VSIX into the guest

#### Scenario: unknown guest platform soft-fails extensions apply
- Given guest architecture cannot be mapped to a marketplace `targetPlatform` on an `up` / `clone` / `rebuild` apply
- When extensions apply would otherwise download VSIX assets
- Then the CLI soft-fails extensions apply with a clear warning
- And MUST NOT download a host-platform VSIX as a silent fallback
- And lifecycle success is preserved solely for that soft-fail

#### Scenario: folder unpack alone is not UI-visible without registry
- Given an extension folder already exists under the remote extensions directory but `extensions.json` does not list that extension (registry empty or missing entry)
- When extensions apply runs for that ID on `up` / `clone` / `rebuild` (marker pending)
- Then the CLI upserts the registry entry for that ID (and SHOULD invalidate extensions user cache when registry changes)
- And install is treated complete for that ID only after registry listing succeeds (folder-only is insufficient)

#### Scenario: registry metadata.pinned reflects version pin only
- Given a bare config ID `publisher.name` and a version-pinned ID `publisher.name@1.2.3`
- When registry entries are built for each during apply on `up` / `clone` / `rebuild`
- Then bare ID entry has `metadata.pinned` **false**
- And version-pinned ID entry has `metadata.pinned` **true**

#### Scenario: transitive extensionDependencies install (Swift → lldb-dap style)
- Given config lists `swiftlang.swift-vscode` (or equivalent) whose unpacked `package.json` declares a hard `extensionDependencies` entry such as `llvm-vs-code-extensions.lldb-dap`
- When extensions apply runs successfully for the config-listed ID on `up` / `clone` / `rebuild`
- Then the CLI attempts install of the dependency ID (and further transitive deps/pack members) with cycle guard
- And dependency failures soft-fail per ID without failing lifecycle solely due to apply
- And the marker hash input still contains only the config-listed extension IDs (plus settings), not the transitive dependency IDs as extra config entries

#### Scenario: transitive extensionPack install (csdevkit-style pack + deps)
- Given config lists only a root extension (e.g. `ms-dotnettools.csdevkit`) whose unpacked `package.json` declares both `extensionPack` members (e.g. `ms-dotnettools.csharp`) and `extensionDependencies` (e.g. `ms-dotnettools.vscode-dotnet-runtime`)
- When extensions apply runs successfully for the config-listed ID on `up` / `clone` / `rebuild`
- Then the CLI attempts install of **both** pack members and dependency IDs (and further transitive IDs from either field) with the shared visited bare-id cycle guard
- And failure of one pack or dep ID soft-fails that ID and continues the queue without failing lifecycle solely due to apply
- And the marker hash input still contains only the config-listed extension IDs (plus settings), not transitive pack/dep IDs as extra config entries

#### Scenario: extensions still apply when open soft-fails under --vscode
- Given well-formed extensions and an `up` / `clone` / `rebuild` lifecycle that would otherwise succeed
- When the user runs with `--vscode` and open soft-fails
- Then the CLI still attempts extensions install for that invocation (command gate, not open-success gate)
- And lifecycle success is unchanged by open soft-fail alone
- And postAttach follows realized **postAttachCommand policy (CLI-only)** (open soft-fail MUST NOT skip CLI-attach postAttach)
- And the marker MAY be finalized when extensions apply fully succeeds even though open soft-failed

#### Scenario: extensions soft-fail keeps lifecycle success
- Given `up` / `clone` / `rebuild` and extension install forced to fail
- When extensions apply runs
- Then stderr includes a warning
- And the lifecycle command exit remains success when postAttach is absent or does not run or exits 0
- And the container is not deleted or stopped solely due to extensions apply failure

#### Scenario: postAttach still fail-keep after extensions apply
- Given open success, extensions apply soft-fails or succeeds, and `postAttachCommand` exits non-zero
- When the user runs `up --vscode` (or clone/rebuild equivalent)
- Then the command fails naming postAttach
- And the container is kept
- And extensions apply soft-fail did not by itself cause that command failure

#### Scenario: manual attach without flag is not an apply trigger
- Given well-formed extensions and a running container
- When the user attaches via experimental UI without using a CLI command that applies customizations
- Then the CLI MUST NOT apply extensions solely due to that manual attach (same attach-hook limitation class as postAttach)
- And a prior `up` / `clone` / `rebuild` MAY already have applied them on that earlier command

#### Scenario: extensions apply is not image build
- Given a config with both `features` and `customizations.vscode.extensions`
- When Features runner builds/reuses a derived image and the user then runs `up` / `clone` / `rebuild`
- Then image build identity and Dockerfile generation are not required to embed those vscode extensions solely to satisfy this change
- And apply still occurs against the running guest per this requirement

## MODIFIED Requirements

### Requirement: VS Code attach acceptance

**Domain:** `vscode`  
*(Delta — replace apply bullet 4 and the docs scenario. Bullet 3 stays as in the realized spec (CLI attach model). This change MUST NOT re-gate postAttach on `--vscode`.)*

MVP acceptance for editor integration is:

1. **Manual attach (unchanged core):** After `up` (and equivalently after `clone` / when a managed container is running), the container is running and listable/inspectable so the user can manually use experimental **Attach to Running Apple Container**. The CLI MUST NOT claim full Dev Containers extension parity and MUST NOT fail `up` (or `clone` / `start`) solely because VS Code did not auto-attach or because an optional open was not requested.

2. **Optional best-effort open (additive):** When the user passes `--vscode` on `up`, `start`, `clone`, or `rebuild`, the CLI MUST attempt a best-effort open of a new VS Code window on the resolved remote workspace folder per **VS Code best-effort open**. Open failure MUST be soft (warn; lifecycle success preserved **by itself**). Without `--vscode`, no automatic open is required.

  3. **CLI attach hook for postAttach:** Unchanged from the realized spec (CLI attach model; see **postAttachCommand policy (CLI-only)**).

  4. **CLI apply of config-file vscode customizations:** The CLI MUST apply parseable config-file `customizations.vscode.settings` and `customizations.vscode.extensions` on `up`, `clone`, and `rebuild` (fresh create-path, `up` reuse, and `up` start-stopped) without requiring `--vscode` or a successful editor open, per the apply requirements. `adevcontainer start` MUST NOT apply settings or extensions. `--vscode` MUST NOT be an apply gate; it remains the open flag only. Manual UI attach is not an apply trigger. Apple attach still does not auto-install. Apply failures are soft-fail and MUST NOT be presented as full Dev Containers parity.


#### Scenario: Running container is attachable target
- Given a successful `up` (or `clone`)
- When the user lists/inspects containers via the CLI
- Then the managed dev container is identifiable for manual VS Code attach

#### Scenario: Optional open does not replace manual attach
- Given a successful lifecycle without or with `--vscode`
- When the user chooses not to rely on automatic open (flag omitted, or open soft-failed)
- Then list/inspect still expose enough identity for manual experimental attach
- And the CLI documentation MUST NOT state that full Dev Containers extension parity is provided

#### Scenario: customizations apply does not claim IDE parity
- Given docs or help text describing vscode customizations apply
- When a user reads product documentation for this behavior
- Then the text MUST NOT claim that manual UI attach or full Dev Containers extension-driven apply is implemented
- And it MUST describe soft-fail
- And it MUST describe that settings and extensions apply by default on `up` / `clone` / `rebuild`
- And it MUST describe that `--vscode` gates open, not apply
- And it MUST describe that `start` does not apply settings or extensions

---

### Requirement: Optional `--vscode` flag on up, start, clone, and rebuild

**Domain:** `vscode`  
*(Delta — `--vscode` remains open only for apply purposes; drop the rebuild “extensions apply (flag gate only)” clause. postAttach follows the realized CLI attach model. `start` MUST NOT apply customizations.)*

When `--vscode` is **absent**, those commands MUST NOT invoke a host VS Code open. When `--vscode` is **present**, after the command’s container lifecycle has reached the `waitFor` connection point and the managed container is running (or already running for a start no-op), the CLI MUST attempt a **best-effort** open of a **new** VS Code window attached to that container at the **resolved remote workspace folder**. postAttach after that open is specified under realized **postAttachCommand policy (CLI-only)**.

`--vscode` MUST NOT gate settings apply or extensions apply. On `up`, `clone`, and `rebuild`, customizations apply (when pending) MUST run whether the flag is present or not, and when the flag is present MUST run **before** the open attempt. On `start`, the flag still requests open (and postAttach per realized policy); `start` MUST NOT apply customizations. On CLI-attach paths, omitting `--vscode` MUST NOT skip postAttach.

On `rebuild`, `--vscode` behavior MUST be identical to the `up`/`clone` create path for **open**: after rebuild lifecycle reaches `waitFor` on the new container, customizations apply (not flag-gated) has already run or runs before open; then attempt a best-effort open. postAttach follows realized **postAttachCommand policy (CLI-only)** — never failing rebuild solely due to open.

#### Scenario: --vscode still only gates open not apply on up
- Given a successful `up` create-path with well-formed settings and extensions and a config that also has `postAttachCommand`
- When the user runs `up` **without** `--vscode`
- Then settings and extensions apply still run per the apply requirements
- And the CLI MUST NOT invoke a host VS Code open
- And postAttach MUST execute as CLI attach

#### Scenario: --vscode on start still opens without applying customizations
- Given a managed container that `start` can select and a config with settings, extensions, and `postAttachCommand`
- When the user runs `start --vscode` and host `code` launch succeeds
- Then after start success the CLI attempts to open a new VS Code window attached to that container
- And postAttach follows realized **postAttachCommand policy (CLI-only)**
- And the CLI MUST NOT apply settings or extensions on that `start` invocation
- And resume hooks still follow realized **Start managed container**

#### Scenario: without --vscode behavior unchanged for open
- Given any valid `up`, `start`, `clone`, or `rebuild` invocation
- When the user omits `--vscode`
- Then the CLI MUST NOT invoke a host VS Code open as part of that command
- And manual attach (list/inspect + experimental Attach to Running Apple Container) remains valid

---

### Requirement: Apply vscode settings on create-path (and repair on drift)

**Domain:** `vscode`  
*(Delta — keep create-path and `up` reuse / start-stopped apply; remove `start` as a settings-apply command.)*

When resolved config retains a non-empty well-formed `customizations.vscode.settings` object (or when marker drift requires re-apply of the normalized payload that includes settings), the CLI MUST attempt to merge those settings into the guest **remote Machine** settings file for the **resolved remote connection user** (not create-only `containerUser` when `remoteUser` differs):

- Target path concept: under the resolved remote connection user home, `~/.vscode-server/data/Machine/settings.json` (create parent directories as needed).
- Merge semantics: deep-merge or key-merge such that config-declared keys are written into the Machine settings object without wiping unrelated keys already present when feasible; on missing file, create a valid settings JSON object containing at least the declared keys.

**When settings apply RUNS**

1. **Fresh create-path** on `up`, `clone`, and `rebuild`: after create-path lifecycle hooks for that path have completed successfully (onCreate → updateContent → postCreate → postStart as applicable to the path), and **before** optional `--vscode` open / postAttach.
2. **`up` reuse / `up` start-stopped:** when config can be loaded and the guest marker indicates the normalized customizations hash does **not** match (drift or never applied), the CLI MUST attempt settings repair (and marker update on full successful apply of the normalized payload) without requiring `--vscode`. On `up` start-stopped, settings apply runs after `postStartCommand` when that hook runs.

**When settings apply MUST NOT run**

- `adevcontainer start` (with or without `--vscode`, including already-running no-op) MUST NOT merge or repair Machine settings on that invocation.
- Settings apply MUST NOT be gated on `--vscode`.
- Settings apply MUST NOT require a successful editor open.
- Settings apply MUST NOT run as part of image build or Features Dockerfile generation.

**Soft-fail (MUST)** and **Idempotency** remain as in the realized requirement (warn; never fail lifecycle exit; never delete/stop solely due to settings apply; skip when marker hash matches).

#### Scenario: settings merge on fresh up create without --vscode
- Given a valid config with well-formed non-empty `customizations.vscode.settings` and a fresh `up` create-path that completes create-path hooks successfully
- When the user runs `up` **without** `--vscode`
- Then the CLI attempts to merge settings into the guest Machine settings path under the resolved remote connection user home
- And `up` still reports lifecycle success when settings apply soft-fails or succeeds
- And the managed container is not deleted solely due to settings apply failure

#### Scenario: settings apply under remote connection user home
- Given `remoteUser` `alice` and settings apply on create-path
- When settings are merged
- Then the guest Machine settings path is under `alice`’s home, not `bob`’s when `containerUser` is `bob`

#### Scenario: settings merge on fresh clone create without --vscode
- Given a valid clone path with well-formed non-empty `customizations.vscode.settings` and successful create-path hooks
- When the user runs `clone` **without** `--vscode`
- Then the CLI attempts the same Machine settings merge after create-path hooks
- And soft-fail does not fail `clone` or delete the container/volume solely due to settings apply

#### Scenario: settings merge on rebuild without --vscode
- Given a successful `rebuild` create-path on the new container and well-formed non-empty settings
- When the user runs `rebuild` **without** `--vscode`
- Then the CLI attempts the same Machine settings merge after create-path hooks on the **new** container
- And soft-fail does not fail `rebuild` or start a recovery session solely due to settings apply

#### Scenario: settings not gated on open or --vscode
- Given well-formed settings and create-path success
- When `--vscode` is omitted or open soft-fails
- Then settings apply still runs (or already ran) on that `up` / `clone` / `rebuild` path
- And extensions apply on those same commands is also not gated on `--vscode` (see **Apply vscode extensions on up, clone, and rebuild**)

#### Scenario: settings soft-fail keeps lifecycle success
- Given create-path would otherwise succeed and settings merge is forced to fail (e.g. mocked exec failure)
- When settings apply runs
- Then stderr includes a warning about settings apply
- And the lifecycle command exit remains success (absent unrelated failures)
- And the container is not deleted or stopped solely due to that failure

#### Scenario: up reuse repairs settings on marker drift
- Given a running managed container whose guest marker hash does not match the normalized customizations from loadable config (e.g. config settings edited on host without rebuilding)
- When the user runs `up` (matching identity/hash reuse)
- Then the CLI attempts settings repair according to the drifted payload
- And `--vscode` is not required
- And soft-fail policy still applies

#### Scenario: up start-stopped repairs settings on marker drift
- Given a matching stopped managed container, loadable config with well-formed settings, and a guest marker missing or drifted
- When the user runs `up` (start-stopped path)
- Then after `postStartCommand` (when present) the CLI attempts settings repair
- And `--vscode` is not required
- And soft-fail policy still applies

#### Scenario: start never applies settings
- Given well-formed settings, a managed container that `start` can select, and a guest marker missing or drifted
- When the user runs `start` **without** `--vscode`
- Then the CLI MUST NOT merge or repair Machine settings on that invocation

#### Scenario: start with --vscode still does not apply settings
- Given well-formed settings, a managed container that `start` can select, and a guest marker missing or drifted
- When the user runs `start --vscode`
- Then the CLI MUST NOT merge or repair Machine settings on that invocation
- And open / postAttach still follow realized `--vscode` and **postAttachCommand policy (CLI-only)**
- And resume hooks still follow realized **Start managed container**

---

### Requirement: Vscode customizations apply idempotency

**Domain:** `vscode`  
*(Delta — both settings and extensions can complete on `up` / `clone` / `rebuild` without `--vscode`; `start` never applies and MUST NOT finalize the marker. Marker path, hash input, and skip-on-match remain.)*

The CLI MUST record successful application of the **normalized** customizations payload (ordered **config-file** extension IDs + canonicalized settings JSON) using a guest marker file under the resolved remote connection user home, e.g. `$HOME/.adevcontainer/vscode-customizations.applied`, whose content is a stable content hash of that normalized payload.

**Rules**

1. Before apply work on `up`, `clone`, or `rebuild`, the CLI SHOULD read the marker (if present) and compare to the hash of the current normalized payload from resolved/loadable config.
2. When the marker hash **matches**, the CLI MUST skip redundant settings merge and extensions install for that payload.
3. When the marker is **missing** or the hash **differs** (config edited without rebuilding), the CLI MUST treat apply as pending on `up` / `clone` / `rebuild` and run the applicable apply steps (settings and extensions per those requirements). `--vscode` MUST NOT be required to run either step.
4. The CLI MUST write/update the marker to the new hash only after the apply steps required for that invocation’s pending work have completed successfully for the full normalized payload. Settings-only success while extensions remain pending (or the reverse) MUST NOT claim full-payload success. Marker finalization MUST NOT require `--vscode` or open success. `adevcontainer start` MUST NOT write or update the marker.
5. Apply MUST NOT blindly re-run on every `up` / `clone` / `rebuild` (or every `--vscode` invocation) when the marker already matches.
6. Marker hash input MUST NOT include transitive `extensionDependencies` or `extensionPack` IDs discovered at install time — only config-listed extension IDs (normalized) and settings. Transitive installs remain side effects of applying listed IDs when apply runs.

**Normalization** is unchanged (stable sort of config-file extension IDs; canonical settings JSON).

#### Scenario: matching marker skips re-apply
- Given a guest marker whose hash matches the normalized extensions+settings from config
- When the user runs `up` without or with `--vscode` (or `clone` / `rebuild`)
- Then the CLI skips redundant settings merge and extensions install for that payload
- And does not fail solely due to skip

#### Scenario: hash drift re-applies on up without --vscode
- Given a guest marker that does not match the current normalized payload (e.g. extension ID added in config without rebuilding)
- When the user runs `up` (reuse or create-path) **without** `--vscode`
- Then the CLI attempts apply for the drifted payload per the settings and extensions requirements
- And updates the marker only according to successful full-payload completion rules above

#### Scenario: start does not finalize or consume apply via marker
- Given a guest marker missing or drifted
- When the user runs `start` without or with `--vscode`
- Then the CLI MUST NOT apply settings or extensions
- And the marker MUST remain unchanged solely due to that `start`

#### Scenario: not every up blindly reinstalls
- Given a matching marker after a prior successful full apply
- When the user runs `up` again (reuse)
- Then extensions are not reinstalled and settings are not re-merged solely because `up` ran again

---

### Requirement: Supported property surface (core + lifecycle/runArgs/host)

**Domain:** `core`  
*(Delta — editor customizations bullets and the apply-policy scenario; other bullets unchanged.)*

**Editor customizations (config-file, v1)**

- `customizations.vscode.extensions` — array of string extension IDs; retained and applied on `up` / `clone` / `rebuild` (not gated on `--vscode` or open success; not applied on `start`) per apply requirements
- `customizations.vscode.settings` — JSON object; retained and merged into guest Machine settings on `up` / `clone` / `rebuild` create-path and on `up` reuse / start-stopped drift repair (not gated on `--vscode`; not applied on `start`) per apply requirements
- Other `customizations` content remains admitted metadata and is not applied in v1

#### Scenario: property surface admits vscode extensions and settings
- Given a minimal image config that includes only well-formed `customizations.vscode.extensions` and `settings` beyond core image fields
- When config is resolved
- Then resolve succeeds and those fields are available to apply paths

#### Scenario: parseable vscode customizations are applied per policy
- Given a valid config with well-formed `customizations.vscode.settings` and `extensions`
- When the user completes a fresh `up` create-path **without** `--vscode`
- Then settings and extensions were both attempted on that `up` per the apply requirements
- And apply soft-fail never fails lifecycle solely due to apply errors

---

### Requirement: Unsupported property policy

**Domain:** `core`  
*(Delta — retarget the apply-requirement names in **No longer pure-ignore**; remainder unchanged.)*

**No longer pure-ignore**

- `customizations.vscode` — MUST still admit without failing parse when present as an object under object-shaped `customizations` (see existing scenario **customizations.vscode does not fail**). When nested `extensions` / `settings` are well-formed, the CLI MUST retain them and MUST apply per **Parse and retain customizations.vscode extensions and settings**, **Apply vscode settings on create-path (and repair on drift)**, **Apply vscode extensions on up, clone, and rebuild**, and **Vscode customizations apply idempotency**. Malformed nested shapes soft-skip apply with warn rather than failing whole-config resolve when `customizations.vscode` is an object.

#### Scenario: parseable vscode customizations are applied per policy
- Given a valid config with well-formed `customizations.vscode.settings` and `extensions`
- When the user completes a fresh `up` create-path **without** `--vscode`
- Then settings and extensions were both attempted on that `up` per the apply requirements
- And apply soft-fail never fails lifecycle solely due to apply errors

---

### Requirement: Up lifecycle (create, start, reuse)

**Domain:** `core`  
*(Delta — replace the vscode customizations apply matrix and the following paragraph. Hook and postAttach matrix rows stay as in the realized spec (CLI attach / start hooks). This change MUST NOT restore “Bind start-stopped postStartCommand remains an `up` path only”.)*

| Path | Vscode customizations apply |
|------|-----------------------------|
| Fresh create-path `up`/`clone`/`rebuild` with well-formed settings and/or extensions | after create-path hooks: settings merge and extensions install as applicable (soft-fail); **not** gated on `--vscode`; marker/idempotency rules |
| Fresh create-path without settings or extensions (and no pending payload) | no vscode customizations apply required |
| `up` reuse (running, matching hash) with loadable config and marker pending/drift | settings repair and extensions install as applicable (soft-fail); **not** gated on `--vscode` |
| `up` start-stopped (matching hash) with loadable config and marker pending/drift | after `postStartCommand` when that hook runs: settings repair and extensions install as applicable (soft-fail); **not** gated on `--vscode` |
| `adevcontainer start` (any flag combination) | **no** settings or extensions apply |
| Any path with matching marker for full normalized payload | skip redundant settings+extensions apply (`start` still does not apply) |
| `up`/`clone`/`rebuild` with `--vscode` | apply first (if pending), then open; postAttach follows realized **postAttachCommand policy (CLI-only)** |
| `start` with `--vscode` | no apply; then open; postAttach follows realized **postAttachCommand policy (CLI-only)** |

postAttach matrix rows and gating text remain as in the realized spec. Customizations apply is **not** part of create-path delete-on-fail, **not** folded into postAttach execution, and **not** run on `start`.

#### Scenario: up reuse still applies customizations
- Given a matching running container and a drifted guest customizations marker
- When the user runs `up` without `--vscode`
- Then the CLI attempts pending settings and extensions apply
- And create-path hooks are not re-run

#### Scenario: up start-stopped still applies customizations
- Given a matching stopped container and a drifted guest customizations marker
- When the user runs `up` without `--vscode`
- Then `postStartCommand` runs if present, then the CLI attempts pending settings and extensions apply

---

### Requirement: Start managed container

**Domain:** `managed-lifecycle`  
*(Delta — apply exclusion only. Resume hooks follow realized **Start managed container** / **Lifecycle hook surface**. This change does **not** lock `start` as runtime-only and MUST NOT remove postStart from bare `start`.)*

**Vscode customizations on start**

- `adevcontainer start` MUST NOT apply `customizations.vscode.settings` or `customizations.vscode.extensions`, with or without `--vscode`.
- Config load on `start` MAY be used for hooks, open, and postAttach. It MUST NOT be used to apply settings or extensions.

#### Scenario: start does not apply vscode customizations
- Given a managed container whose config has well-formed settings and extensions and whose guest marker is missing or drifted
- When the user runs `adevcontainer start` without or with `--vscode`
- Then the CLI MUST NOT apply those settings or extensions on this path
- And resume hooks still follow the realized Start managed container requirement

## REMOVED Requirements

### Requirement: Apply vscode extensions when --vscode is set (before open)

**Rationale:** Extensions apply is no longer gated on `--vscode` and no longer runs on `start`. Replacement is **Apply vscode extensions on up, clone, and rebuild** (same guest Marketplace VSIX / registry / soft-fail / marker mechanism; command gate is `up` / `clone` / `rebuild` only).
