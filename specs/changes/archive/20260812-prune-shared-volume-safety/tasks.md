# Tasks: prune-shared-volume-safety

Spec ref: `specs/changes/prune-shared-volume-safety/`  
Base contract: union of `specs/<domain>.md` (focus: `specs/managed-lifecycle.md` **Prune command**)  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. Mock `AppleContainerRuntime` so the default suite needs no real `container` runtime and no network. Reuse mount / `containersAttached` JSON shapes from recovery helper coverage where helpful (`Tests/adevcontainerTests/RecoveryHelperTests.swift` patterns). Do not add public `devcontainer.json` fields, Compose `external` support, or a force-volumes flag. Do not archive or fold domain specs in this task set.

## 1. Failing tests — shared volume preserve + warn

- [x] 1.1 Write failing tests: after target container delete, a candidate config volume still mounted by **another running** container is **not** deleted; mock records no `deleteVolume` for that name; stderr/status includes a preserve-because-referenced warning listing the other container by **name and id** when both available; exit code `0` when nothing else fails (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 1.2 Write failing tests: same preserve when the other container is **stopped** but still listed with a real volume mount via `list --all` / `containersAttached` semantics (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 1.3 Write failing tests: mixed candidates — unreferenced volume is deleted; shared volume is preserved with warning; exit `0` (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 1.4 Write failing tests: volume-mode workspace volume (`workspace_volume` / `*-ws`) is preserved when another container mounts it, and removed when unreferenced (regression lock with existing prune workspace-volume coverage) (path: `Tests/adevcontainerTests/AllCommandTests.swift` and/or `Tests/adevcontainerTests/CloneInVolumeTests.swift`)

## Checkpoint — share preserve tests red

- [x] verify **Prune preserves volume still mounted by another container** fails under current unconditional delete
- [x] verify **Stopped container attachment still protects volume** encoded as a test
- [x] verify **Prune deletes unreferenced candidate among mixed attachments** encoded as a test

---

## 2. Failing tests — fail-safe ordering and inspection errors

- [x] 2.1 Write failing tests: when target **container delete** throws, prune returns non-zero and mock records **zero** `deleteVolume` calls for all candidates (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 2.2 Write failing tests: when attachment inspection fails (list/parse error) for a candidate that exists, that volume is **not** deleted and exit is non-zero (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 2.3 Write failing tests: unreferenced existing volume whose `deleteVolume` throws → non-zero hard failure (lock current class of failure) (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 2.4 Write failing tests: labels define candidates only — volume not in `config_volumes` / `workspace_volume` is never deleted even if present on the host mock (path: `Tests/adevcontainerTests/AllCommandTests.swift`)

## Checkpoint — fail-safe tests red

- [x] verify **Container delete failure blocks all volume deletes**
- [x] verify **Attachment inspection failure preserves volume and fails**
- [x] verify **Runtime volume delete rejection remains hard failure**
- [x] verify **Labels discover candidates; mounts decide deletion** (both sub-cases)

---

## 3. Implement attachment-aware prune volumes

- [x] 3.1 After successful target container delete (or skip-missing container), for each distinct candidate volume from labels, call existing attachment inspection (`containersAttached` / equivalent `list --all` mount check) excluding the already-removed target (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 3.2 If any remaining container mounts the volume: skip delete; emit StatusPrinter warning on stderr that the volume is preserved because referenced, listing container names (and ids when available) (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 3.3 If none mount and volume exists: delete as today; missing volume skip unchanged (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 3.4 If container delete failed: set hard failure, **skip the entire volume-delete loop**, do not partial-delete volumes (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 3.5 If attachment inspection throws/fails closed: preserve that volume, set hard failure, continue safely for other candidates without deleting the uncertain one (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)
- [x] 3.6 Make §1–§2 tests green without weakening recovery-helper skip or image/bind policies (path: `Tests/adevcontainerTests/AllCommandTests.swift`, `Sources/ADevContainerLib/Commands/PruneCommand.swift`)

## Checkpoint — implementation green

- [x] verify **Prune preserves volume still mounted by another container**
- [x] verify **Prune deletes unreferenced candidate among mixed attachments**
- [x] verify **Stopped container attachment still protects volume**
- [x] verify **Container delete failure blocks all volume deletes**
- [x] verify **Attachment inspection failure preserves volume and fails**
- [x] verify **Runtime volume delete rejection remains hard failure**
- [x] verify **Labels discover candidates; mounts decide deletion**

---

## 4. Regression locks — existing prune scenarios

- [x] 4.1 Confirm/adjust existing tests still encode: unreferenced volume-mode workspace volume removed; bind-mode `config_volumes` removed when unreferenced; bind host paths never volume-deleted; missing resources skipped; recovery helper full skip exit 0 (paths: `Tests/adevcontainerTests/AllCommandTests.swift`, `Tests/adevcontainerTests/CloneInVolumeTests.swift`, integration recovery prune assertions in `Tests/adevcontainerTests/AllIntegrationTests.swift` only if already gated)
- [x] 4.2 Confirm ordinary `delete` tests still assert container-only deletion (no volume deletes); do not add force-volumes (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 4.3 Grep regression: prune volume delete path always preceded by attachment decision or explicit fail-safe skip; no Compose `external` API; no new devcontainer.json keys (path: `Sources/ADevContainerLib/Commands/PruneCommand.swift`)

## Checkpoint — regressions

- [x] verify **Prune removes volume-mode workspace volume when unreferenced**
- [x] verify **Prune bind-mode uses config_volumes label when unreferenced**
- [x] verify **Prune still skips binds and global prune**
- [x] verify **Prune skips missing resources**
- [x] verify **Recovery helper skip unchanged**
- [x] verify **delete remains container-only**

---

## 5. Suite / land gate

- [x] 5.1 Run full default suite `swift run adevcontainerTests`; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 5.2 Cross-check every scenario title in `specs/changes/prune-shared-volume-safety/spec.md` against a test or explicit regression lock above (path: `specs/changes/prune-shared-volume-safety/spec.md`)
- [x] 5.3 Domain fold into `specs/managed-lifecycle.md` + archive are **out of this task set** (land contract after code; coordinator archives). Do not move this folder to `specs/changes/archive/` here.

## Checkpoint — done for implementers

- [x] verify all change `spec.md` scenarios covered
- [x] verify default `swift run adevcontainerTests` green
- [x] verify Non-goals respected (no external Compose, no force-volumes, no archive/wiki, recovery skip unchanged)

(End of file - total 91 lines)
