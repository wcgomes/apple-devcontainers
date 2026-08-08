# Proposal: Apply customizations.vscode extensions and settings via adevcontainer

## Intent

Official Dev Containers applies `customizations.vscode.extensions` and `settings` when the editor creates or connects to a remote. Spike work showed that Apple Container attach (`apple-container+`) does **not** install those extensions or merge those settings. `adevcontainer` today admits `customizations.vscode` but only keeps a `hasVscodeCustomizations` Bool — configs that declare Swift tooling (e.g. `swiftlang.swift-vscode`) or remote Machine settings never take effect through the CLI. This change makes parseable config-file `customizations.vscode` **apply** through adevcontainer with clear gates, soft-fail policy, and idempotency, without claiming full Dev Containers parity.

## Scope

- Change id: **`vscode-customizations-apply`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; CLI entry `Sources/adevcontainer/AdevcontainerMain.swift`; tests under `Tests/adevcontainerTests/`
- Realized base contract: `specs/adevcontainer/spec.md`. Prior related archive: `specs/changes/archive/20260808-vscode-open-flag/` (open soft-fail; postAttach after successful `--vscode` open only)
- **Parse and retain** config-file `customizations.vscode.extensions` (string extension IDs) and `customizations.vscode.settings` (JSON object). Presence of a parseable vscode customizations object continues to signal VS Code intent; well-formed extensions/settings MUST be retained for apply
- **Settings apply** on create-path after create-path lifecycle hooks complete on fresh `up` / `clone` create — **not** gated on `--vscode`. Merge into guest remote Machine settings under the effective `remoteUser` home. Soft-fail (warn; never fail lifecycle; never delete/stop container solely due to apply failure)
- **Extensions apply** on first successful `--vscode` open (same CLI attach open success gate as postAttach). Install missing IDs into the remote extension directory under effective `remoteUser` home. Soft-fail. Prefer mechanisms that do not require full VS Code Server ready when possible
- **Idempotency** via a guest marker file whose content is a hash of normalized extensions + settings. Skip when hash matches; re-apply when config drifts without container recreate. MUST NOT blindly re-apply every postAttach / every open
- **Separate apply step** — MUST NOT use `postAttachCommand` as the apply vehicle (different fail policy). Recommended order after open success: extensions apply, then postAttach unchanged
- **start / reuse**: load config via existing PostAttachConfigLoader-class paths as needed; settings repair on marker drift; extensions only when `--vscode` open succeeds and apply is pending
- **v1 merge source**: config file `customizations` only. Feature-contributed customizations and image metadata merge are non-goals (phase 2)
- **Identity**: `customizations` remain outside create identity / config hash (already true; MUST stay true)
- **Admission**: still MUST NOT fail whole-config parse solely because `customizations.vscode` is present; malformed nested extensions/settings shapes SHOULD soft-skip apply with warn rather than fail resolve when the vscode key is an object (resilience matching today’s admit-any-object behavior). Wrong top-level `customizations` type (not an object) remains a resolve failure as today
- **MODIFY** realized requirements that treat `customizations.vscode` as ignore/metadata-only (Unsupported property policy “May ignore…” and any editor-side-only framing) so the contract requires apply when parseable extensions/settings are present per the policies above
- Docs: help/README note that CLI applies config-file vscode customizations (settings on create-path; extensions after successful `--vscode` open), soft-fail, marker idempotency, no full parity claim

## Live-validation refinements (post-ship note)

Empirical apply on a real guest confirmed: (1) **folder unpack alone is insufficient** — UI stayed at 0 installed until `extensions.json` registry upsert + extensions.user.cache invalidate; (2) **recursive `extensionDependencies`** (Swift → `llvm-vs-code-extensions.lldb-dap`) removes the missing-dependency prompt; (3) **host VSIX + tar-pipe + guest unzip** is the transfer path; (4) settings Machine merge works; marker hash stays **config payload only**. Spec/design/README/wiki capture these as MUST/HOW — see active change artifacts.

## Non-goals

- Full Dev Containers extension parity (up/rebuild driver, IDE-owned apply on manual Attach UI, auto-forward side channels)
- Applying customizations during **image build** or via Features Dockerfile layers
- Feature-contributed `customizations` / `devcontainer.metadata` merge (phase 2)
- Hard-fail lifecycle when settings merge or extension install fails (apply remains soft-fail; contrast postAttach fail-keep)
- Using `postAttachCommand` (or folding apply into postAttach exec) as the delivery mechanism
- Requiring VS Code Server fully ready before extension apply when a seed/unpack path is viable
- Applying extensions on manual attach **without** `--vscode` (same CLI attach-hook limitation as postAttach)
- Gating settings apply on `--vscode` (settings apply on create-path regardless of open)
- Changing create identity / config hash to include customizations
- Auto-installing host VS Code, Remote - Containers, or enabling experimental host settings
- Shipping VSIX marketplace proxy infrastructure beyond best-effort download/install of declared IDs
- Applying non-vscode customization namespaces

## Approach

Lite+design SDD: this proposal + outcome delta `spec.md` + lean `design.md` (Machine settings merge, VSIX/extension-dir install, marker path, order vs postAttach, soft-fail) + dependency-ordered test-first `tasks.md`.

1. Extend the resolved config model to retain normalized `extensions` (string IDs) and `settings` (JSON object) from config-file `customizations.vscode`, with resilient parse (admit object; soft-skip bad nested types with warn).
2. Implement an apply helper: content-hash of normalized payload; guest marker under `$HOME/.adevcontainer/`; merge settings into `~/.vscode-server/data/Machine/settings.json`; install missing extension IDs into remote extensions dir (VSIX download+unpack or equivalent best-effort). Soft-fail all apply I/O.
3. Wire settings apply on fresh create-path after create-path hooks (`up` / `clone`); on start/reuse, repair settings when marker hash drifts.
4. Wire extensions apply after successful `--vscode` open and **before** postAttach (postAttach policy unchanged); skip extensions when open absent/soft-failed.
5. Unit-test parse, hash/marker idempotency, soft-fail, create-path settings gate, open-gated extensions, and non-interference with postAttach fail-keep.
6. Document behavior in help/README without parity overclaim.

## Locked product decisions (summary)

| Topic | Decision |
|-------|----------|
| Source (v1) | Config-file `customizations.vscode` only |
| Extensions shape | Array of string IDs |
| Settings shape | JSON object |
| Settings when | Create-path after create-path lifecycle hooks (fresh `up`/`clone`); repair on start/reuse if marker drift |
| Settings `--vscode` gate | **No** — settings apply without open |
| Extensions when | First successful `--vscode` open (CLI attach hook); pending if marker/hash says not applied |
| Extensions `--vscode` gate | **Yes** — same open-success gate spirit as postAttach |
| Order vs postAttach | After open success: extensions apply → then postAttach (unchanged fail-keep) |
| Apply vehicle | Dedicated apply step — **not** postAttachCommand |
| Soft-fail apply | Warn; never fail lifecycle exit; never delete/stop container solely due to apply |
| Contrast postAttach | postAttach non-zero still fails command / keep container |
| Idempotency | Guest marker e.g. `$HOME/.adevcontainer/vscode-customizations.applied` = hash of normalized extensions+settings; skip match; re-apply on drift |
| Identity hash | customizations stay **out** of create identity |
| Malformed nested | Prefer admit + soft-skip apply with warn (do not fail whole config when vscode is object with bad extensions/settings type) |
| Manual attach no flag | Extensions not applied by CLI |
| Image build / Features Dockerfile | Non-goal |
| Feature/metadata merge | Non-goal phase 2 |
| Server ready | Prefer not requiring full Server ready for extension install |
