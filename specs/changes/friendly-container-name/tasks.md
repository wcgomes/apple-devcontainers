# Tasks: friendly-container-name

Spec ref: `specs/changes/friendly-container-name/`. Test-first: write the failing test, confirm it fails, then implement. Mock `AppleContainerRuntime` so the default suite needs no real `container` runtime. Suite of record: `swift run adevcontainerTests`. Do not auto-rename idle containers. `up`/`clone` leftover different-name stays a delete-hint. `rebuild` uses the live computed create name. Config `name` MUST NOT participate in `${devcontainerId}`, `*-ws`, or Features `nameBase`. Do not offer this rename prompt on `start`. Do not open bring-up recovery on foreign-name collision.

## 1. Create-name identity

- [x] 1.1 Write failing tests: create name is sanitized `name` (`My App` → `my-app`) with no `adev-` prefix and no identity hash; omitted/blank `name` falls back to sanitized workspace basename; punctuation collapses (`C# (.NET)` → `c-net`); 63-character create name is accepted; empty sanitize fails asking for a DNS-safe `name` (not `adev-{hash12}`); same workspace+config `name` is stable across invocations (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 [P] Write failing tests: volume-mode create name is the sanitized `name` or repo basename (not `adev-{base}-{hash12}`); workspace volume stays `adev-{base}-{hash12}-ws`; same URL+config relpath keeps identical `hash12` and volume name; bind vs volume hash material stays distinct when both sanitize to `foo` (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 1.3 Split create name (sanitize `name`, ≤63, no prefix/hash, empty → fail) from resource base (workspace/repo basename only, ~20 clip). Features/`*-ws`/`${devcontainerId}` MUST use that resource base, never sanitized config `name` (path: `Sources/ADevContainerLib/Runtime/ContainerIdentity.swift`)
- [x] 1.4 Surface empty create-name as a structured resolve/`up`/`clone` error asking for a DNS-safe `name` (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)

## Checkpoint

- [x] verify **Container name uses config name when set**
- [x] verify **Container name falls back to workspace basename**
- [x] verify **Empty sanitize asks for a DNS-safe name**
- [x] verify **Create name may use 63 characters**
- [x] verify **Punctuation-heavy name collapses hyphens**
- [x] verify **Stable name across invocations**
- [x] verify **Resource base from repo basename even when name is set**
- [x] verify **Volume name includes workspace identity not the short create name**
- [x] verify **Same URL and config path stable identity**
- [x] verify **Bind and volume modes distinct workspace hashes**

## 2. Hashed sidecars and `${devcontainerId}`

- [x] 2.1 Write failing tests: `"name": "My App"` in folder `foo` → create name `my-app`, Features tag `adev-foo:{contentHash}`, `${devcontainerId}-shellhistory` = `adev-foo-{hash12}-shellhistory`; empty resource base → `adev-{hash12}` / `adevcontainer:{contentHash}`; user-literal `team-cache` is not rewritten (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 2.2 Pass Features `nameBase` as the workspace/repo resource base, never sanitized config `name` (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 2.3 Write failing tests: bind vs volume stems use folder/repo basename + the same hash material as `*-ws` and stay distinct even when both configs set `"name": "My App"` (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 2.4 Expand `${devcontainerId}` to the resource identity stem (folder/repo base + hash12), never the create `--name` and never config `name` (path: `Sources/ADevContainerLib/Config/VariableSubstitutor.swift`)

## Checkpoint

- [x] verify **Features tag keeps hashed adev- form**
- [x] verify **workspace volume keeps hashed adev- form**
- [x] verify **user-literal volume source is not rewritten**
- [x] verify **devcontainerId token expands to the resource identity stem**
- [x] verify **devcontainerId in feature volume mount source**
- [x] verify **bind and volume devcontainerId stems stay distinct**
- [x] verify **localEnv in mount source**
- [x] verify **Unknown substitution token**

## 3. Occupancy classification

- [x] 3.1 Write failing tests: same-workspace same-name `up` reuses or start-stopped and never offers rename; hash mismatch is `config_hash_mismatch` without the foreign-name rename prompt; same-workspace occupant under a different name (including leftover `adev-*`) fails with a delete-hint (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 3.2 [P] Write failing tests: same-workspace same-name `clone` fails closed (no reuse/replace/attach/rename-to-duplicate); same-workspace different name is delete-hint; a different git URL/config identity on the desired name is foreign (not fail-closed-as-same) (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 3.3 Classify occupants by bind `local_folder`+`config_file` or volume `git_url`+config identity before create (path: `Sources/ADevContainerLib/Runtime/ContainerIdentity.swift`)
- [x] 3.4 Wire `up` to reuse / `config_hash_mismatch` / delete-hint / foreign per classification; do not find-by-name-only (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 3.5 Wire `clone` to fail-closed / delete-hint / foreign per classification; do not delete the occupant (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)

## Checkpoint

- [x] verify **up reuses same-workspace same-name occupant**
- [x] verify **up hash mismatch on same-workspace same-name occupant**
- [x] verify **clone fails closed on same-workspace same-name occupant**
- [x] verify **same-workspace occupant under a different name is a delete-hint**
- [x] verify **Existing managed container name fails closed**
- [x] verify **Foreign occupant of the clone create name offers a rename prompt** (classification reaches the offer path)

## 4. Foreign create-name collision offer

Replace the editor-or-suffix picker. MUST NOT open bring-up recovery. TTY is Y/n then a full-name prompt; persist sanitized `name`; retry.

- [x] 4.1 Write failing tests: TTY foreign occupant warns (name in use, not the same workspace) and asks whether to change the name (Y/n); yes then `My App 2` persists `my-app-2` and retries; empty/invalid name re-prompts without persist; still-colliding name re-asks; decline/cancel/EOF returns the original error with occupant untouched; no editor and no suffix list; `ADEVCONTAINER_QUIET=1` still shows the warning and prompts (path: `Tests/adevcontainerTests/UpCommandRecoveryTests.swift`)
- [x] 4.2 [P] Write failing tests: `clone` TTY persist writes `name` on the retained checkout (not via recovery editor) and a successful retry leaves that `name` in the workspace config after populate; non-TTY/`--json` never prompt and hint retained checkout + exact retry (path: `Tests/adevcontainerTests/CloneRecoveryTests.swift`)
- [x] 4.3 Implement Y/n then new-full-name prompt, persist sanitized `name` into the editable config, re-prompt on empty/invalid, re-ask on still-colliding; MUST NOT open an editor or offer a suffix (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 4.4 Offer the foreign rename path from `clone` only when classification is foreign, persist into the retained checkout, and overlay persisted `name` after populate (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)

## Checkpoint

- [x] verify **TTY asks whether to change the name**
- [x] verify **yes prompts for the new full name and persists it**
- [x] verify **successful clone rename retry leaves name in the workspace config**
- [x] verify **empty or invalid name re-prompts**
- [x] verify **still-colliding name re-asks**
- [x] verify **decline leaves the occupant untouched**
- [x] verify **non-TTY and json never prompt**
- [x] verify **rename prompts remain usable under QUIET**

## 5. start, rebuild, and presentation

- [x] 5.1 [P] Write failing tests: `start` never classifies or offers the create-name collision rename prompt (path: `Tests/adevcontainerTests/StartCommandRecoveryTests.swift`)
- [x] 5.2 Write failing tests: `rebuild` uses the live computed create name when it differs from `selected.name` (edited `name` → new create name, old container gone, `*-ws` reused, literal volumes reused); unchanged config `name` on an `adev-*` container migrates to the short name; computed name equal to selected name stays same-name rebuild; foreign occupant of the new name MUST NOT delete the selected container and follows the TTY change-name offer / non-TTY fail (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 5.3 Create the rebuild replacement under the live computed create name; do not delete the selected container until that name is known and occupiable; reuse `*-ws` and user-literal volumes (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 5.6 Write failing tests: rebuild that only changes config `name` (bind and volume) keeps the same `adev-{folder/repo}-{hash12}` stem so shell-history and `*-ws` are reused (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 5.7 Keep rebuild `${devcontainerId}` / `*-ws` / Features `nameBase` on the folder/repo resource base, ignoring live config `name` (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 5.4 [P] Treat short create names as phase-line resource tokens so `==> … my-app` still emphasizes the name after the `adev-` prefix goes away (path: `Tests/adevcontainerTests/Support/TerminalStyleTests.swift`)
- [x] 5.5 Update phase-item detection so DNS-friendly create names (not only `adev-*`) style as resource targets (path: `Sources/ADevContainerLib/Support/TerminalStyle.swift`)

## Checkpoint

- [x] verify **start does not offer create-name collision**
- [x] verify **rebuild after editing name uses the new create name**
- [x] verify **rebuild migrates an adev-* name to the short computed name**
- [x] verify **rebuild same computed name is unchanged**
- [x] verify **rebuild foreign occupant does not delete the selected container**
- [x] verify **rebuild keeps the same devcontainerId stem when create name changes**
- [x] verify **no idle migration of existing containers**

## 6. Unchanged-scenario regression lock

- [x] 6.1 [P] Confirm existing bind label / inspect / config-hash / remote_user stamp tests still pass under the short create name (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 6.2 [P] Confirm existing clone URL-normalization, named-volume (not host bind), volume labels, re-clone freshness, and `config_volumes` tests still pass (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 6.3 [P] Confirm rebuild still refreshes `remote_user` and reuses the `*-ws` volume (path: `Tests/adevcontainerTests/RebuildCommandTests.swift`)
- [x] 6.4 Run `swift run adevcontainerTests` and fix only regressions caused by this change (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **Labels present on inspect**
- [x] verify **Features participate in identity hash**
- [x] verify **Up create stamps managed bind labels**
- [x] verify **Up create stamps non-empty remote_user from resolution**
- [x] verify **Clone create stamps remoteUser when set**
- [x] verify **Rebuild refreshes remote_user to newly resolved connection user**
- [x] verify **Scheme URL userinfo stripped from identity**
- [x] verify **SCP-like URL keeps username shape**
- [x] verify **Clone create uses named volume not host bind**
- [x] verify **Managed and volume labels present**
- [x] verify **Re-clone deletes and creates a fresh workspace volume**
- [x] verify **rebuild reuses the workspace volume instead of replacing it**
- [x] verify **config_volumes label records config named volumes**
