# Proposal: Prune shared-volume protection

## Intent

Today `adevcontainer prune` discovers named volumes from managed labels (`devcontainer.config_volumes`, `devcontainer.workspace_volume`) and **deletes every existing candidate volume unconditionally** after the target container is removed. Exit is non-zero only when deleting an **existing** resource fails. That is unsafe when another container (managed or not, running or stopped) still mounts the same volume name: prune can destroy shared data that other workloads still reference.

This change makes prune **attachment-aware** for volume deletion only: labels still define the **candidate set**; the decision to delete uses **real volume mounts** on every other container (via existing `containersAttached` / `list --all` semantics). Unreferenced candidates are removed as today. Volumes still mounted by any remaining container are **preserved** with a stderr StatusPrinter warning that lists the referencing containers (prefer name and id). Legitimate sharing is **not** a hard failure. Fail-safe ordering: if target container delete fails, **no** volume deletes run. Attachment inspection failure preserves the affected volume(s) and exits non-zero. Runtime rejection on volume delete remains a hard failure. Recovery-helper skip and container-only `delete` are unchanged.

## Scope

- Change id: **`prune-shared-volume-safety`**
- Package root: repository root (Swift SPM `adevcontainer`)
- Library under `Sources/ADevContainerLib/`; tests under `Tests/adevcontainerTests/`
- Realized base contract: union of `specs/<domain>.md`. This delta **modifies** the **Prune command** requirement in `specs/managed-lifecycle.md` so volume removal is gated on real mounts after target container delete; selection, image prune policy, bind-path non-deletion, missing-resource skip, recovery-helper skip, and ordinary `delete` remain as today except where exit/ordering for volumes is restated below.
- Paths affected (implementation later): `Sources/ADevContainerLib/Commands/PruneCommand.swift`; tests primarily `Tests/adevcontainerTests/AllCommandTests.swift` (reuse mount / attach JSON shapes already covered near recovery helper tests as needed).
- No new public `devcontainer.json` fields or naming conventions. Same resolved volume name means the same Docker-like shared volume.

## Non-goals

- Compose `external: true` (or any Compose external-volume) support
- A shared/private volume naming convention or new label schema for “owned vs shared”
- Changing ordinary `delete` to remove volumes, or adding a force-volumes / `--force-volumes` flag
- Changing recovery-helper prune skip behavior (helpers and their referenced volumes remain fully skipped)
- Global volume/image prune, bind-mount host path deletion, or derived Features tag deletion policy beyond existing prune rules
- Failing prune solely because a volume is legitimately shared (warning + preserve is success for that volume)
- Archive / domain fold (implement after this Lite change; fold at land)

## Approach

Lite SDD: this proposal + outcome delta `spec.md` + dependency-ordered `tasks.md` (no `design.md`).

1. Keep label-based **candidate** discovery (`config_volumes` + optional `workspace_volume`).
2. After successful target container delete, for each existing candidate volume: inspect attachments on **all** remaining containers (running and stopped) via existing attach/list-all semantics; if any other container has a real volume mount of that name, preserve and warn; else delete as today.
3. Fail-safe: container delete failure → skip all volume deletes → non-zero. Attachment list/parse failure for a volume → preserve that volume → non-zero. Runtime volume delete rejection → hard failure (non-zero). Share-only preserves → exit 0 when no hard failures.
4. Test-first command tests with mocked runtime (list/attach + volume delete call recording); no new public config surface.
