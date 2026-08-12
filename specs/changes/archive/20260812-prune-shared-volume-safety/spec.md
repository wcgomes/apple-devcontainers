# Change Spec: prune-shared-volume-safety

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply. Requirements below are **MODIFIED** unless marked **ADDED**.

## ADDED Requirements

None.

## MODIFIED Requirements

### Requirement: Prune command

**Domain:** `managed-lifecycle`  
**Modify** volume-removal and exit semantics of `adevcontainer prune`. Resource inclusion table, managed-only selection, label-based candidate discovery, image policy, bind-path non-deletion, global-prune exclusion, missing-resource skip, and recovery-helper full skip remain in force except where restated below.

`adevcontainer prune` MUST remove:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`) via `devcontainer.config_volumes` label | Yes, **only when unreferenced** after target container delete (see volume attachment gate) |
| Config `image` reference (from runtime inspect) | Yes |
| **Workspace volume for volume-mode** (`devcontainer.workspace_volume` / deterministic `*-ws` name) | **Yes, only when unreferenced** after target container delete |
| Derived Features tags | No (unless equal to config `image`) |
| Bind-mount host paths | No |
| Global volume/image prune | No |

**Identity and candidates (unchanged intent):**

- Identity resolution for prune MUST be managed-only (`--name` / picker), same as stop/delete/exec/inspect.
- Config named volumes MUST be taken from the `devcontainer.config_volumes` label when present.
- Missing `workspace_volume` label (bind-mode) means no workspace volume candidate.
- Labels define the **candidate volume set only**. The product MUST NOT invent Compose `external` support, shared/private naming conventions, or new public `devcontainer.json` fields for this decision.
- Same resolved volume name MUST be treated as the same volume (Docker-like sharing). No separate “private copy” identity.

**Ordering and fail-safe (MUST):**

1. Resolve the managed target (and apply recovery-helper skip first when applicable — unchanged: skip helper, its referenced volumes, and its image; exit 0).
2. Delete the **target container** (force as today). Missing container after resolve MAY be skipped as today.
3. **If target container delete fails** (runtime error on an existing container the command attempted to delete), the command MUST **not** delete any candidate volumes, MUST return non-zero, and MAY still attempt image cleanup only if that does not undermine the volume fail-safe (preferred: treat container failure as hard failure and skip volume deletes entirely).
4. Only after the target container is gone (deleted successfully or already absent), evaluate each **distinct** candidate volume name from labels (`config_volumes` + optional `workspace_volume`).

**Volume attachment gate (MUST):**

For each existing candidate volume name:

- The product MUST determine whether **any other container** (managed or not, **running or stopped**) still has a **real volume mount** of that name, using existing attachment inspection semantics (`containersAttached` / `list --all` style mount inspection already used elsewhere in the product).
- The pruned target container MUST NOT count as an attachment (it is already deleted or was absent).
- **Unreferenced:** if no remaining container mounts the volume, and the volume exists, prune MUST delete it (same success/skip-missing behavior as today for the delete call itself).
- **Referenced (shared):** if one or more remaining containers mount the volume, prune MUST **preserve** the volume (MUST NOT call volume delete for it) and MUST emit a **stderr** status warning via the StatusPrinter pattern stating that the volume is preserved because it is still referenced, and listing the referencing containers preferably by **name and id** when both are available (name alone is acceptable when id is unavailable).
- Legitimate sharing MUST **not** by itself cause a non-zero exit. When the only volume-related deviations are share-preserves (and any missing-volume skips), and container/image deletes did not hard-fail, prune MUST exit **0**.

**Attachment inspection failure (MUST):**

- If listing or parsing attachments fails for a candidate volume (runtime list failure, unparseable payload, or equivalent inability to decide safely), prune MUST **preserve** that volume (MUST NOT delete it) and MUST treat the command as a **hard failure** (non-zero exit).
- The product MUST NOT delete a volume when it cannot prove the volume is unreferenced.

**Volume delete runtime failure (MUST):**

- If the runtime rejects deletion of a volume the command attempted to delete (volume exists and was judged unreferenced), that remains a **hard failure** (non-zero), same class as today’s “deleting an existing resource failed.”

**Unchanged (MUST NOT regress):**

- Missing candidate volumes are skipped without error solely for absence.
- Bind-mount host paths are never deleted; no global volume/image prune is invoked.
- Ordinary `delete` remains **container-only**; this change MUST NOT add a force-volumes flag or make `delete` remove volumes.
- Recovery helper prune skip behavior is unchanged.

**Exit summary (MUST):**

| Condition | Volume deletes | Exit |
|-----------|----------------|------|
| Recovery helper selected | None (full skip) | 0 |
| Target container delete failed | None | non-zero |
| Attachment inspection failed for a candidate | Preserve affected volume(s) | non-zero |
| Shared volume(s) preserved with warning only | Skip those; delete unreferenced others | 0 if no hard failures |
| Runtime volume/image delete of existing resource failed | Per attempt | non-zero |
| All handled or already absent; shares only warned | As above | 0 |

#### Scenario: Prune removes volume-mode workspace volume when unreferenced

- Given a volume-mode managed container with workspace volume `adev-{base}-{hash12}-ws` and optional config named volumes, and no other container mounts those volumes
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container is gone, unreferenced config named volumes are removed, the config image reference is removed per base policy, **and** the workspace volume `*-ws` is removed

#### Scenario: Prune bind-mode uses config_volumes label when unreferenced

- Given a bind-mode managed container with `config_volumes=vol-a,vol-b`, no workspace_volume label, and no other container mounts `vol-a` or `vol-b`
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container and labeled config volumes are removed; no `*-ws` volume delete is attempted solely for bind mode

#### Scenario: Prune still skips binds and global prune

- Given bind mounts in a bind-mode config
- When the user runs `adevcontainer prune` targeting that container
- Then host bind paths remain and no global volume/image prune is invoked

#### Scenario: Prune skips missing resources

- Given no managed dev container and no matching named volumes (or selection finds nothing to prune per existing managed selection rules)
- When the user runs `adevcontainer prune` in a situation where resources are already absent after valid selection handling
- Then the command succeeds without erroring solely because resources were already absent

#### Scenario: Prune preserves volume still mounted by another container

- Given managed container A selected for prune with candidate volume `shared-data`, and container B (running or stopped) still has a real volume mount of `shared-data`
- When the user runs `adevcontainer prune --name <A>`
- Then container A is deleted, volume `shared-data` still exists, no volume-delete was applied to `shared-data`, and stderr carries a StatusPrinter-style warning that the volume was preserved because it is referenced, listing B preferably by name and id
- And the command exits 0 when no other hard failures occur

#### Scenario: Prune deletes unreferenced candidate among mixed attachments

- Given prune candidates `vol-shared` and `vol-only`, where another container mounts only `vol-shared`, and `vol-only` has no remaining mounts after target delete
- When the user runs `adevcontainer prune` on the target
- Then `vol-only` is removed, `vol-shared` is preserved with a reference warning, and exit is 0 when no hard failures occur

#### Scenario: Stopped container attachment still protects volume

- Given another container that is **stopped** but still configured with a real volume mount of candidate volume `v1`
- When prune evaluates `v1` after deleting the target
- Then `v1` is preserved (stopped attachments count) with the same warning class as a running attacher

#### Scenario: Labels discover candidates; mounts decide deletion

- Given a managed container whose labels list volume `from-label` but after target delete no remaining container mounts `from-label`
- When prune runs
- Then `from-label` is a delete candidate because of the label and is deleted because mounts show it unreferenced
- Given instead the labels omit `other-vol` even if some host volume exists by that name
- When prune runs
- Then prune MUST NOT delete `other-vol` solely because it exists on the host (not in the candidate set)

#### Scenario: Container delete failure blocks all volume deletes

- Given a managed prune target whose container delete fails at the runtime
- When the user runs `adevcontainer prune --name <that-name>`
- Then the command returns non-zero and MUST NOT delete any candidate volumes (including unreferenced ones)

#### Scenario: Attachment inspection failure preserves volume and fails

- Given a candidate volume that exists and attachment list/parse fails so prune cannot prove the volume is unreferenced
- When prune evaluates that volume
- Then the volume is left in place, the command exits non-zero, and no success is claimed for that volume delete

#### Scenario: Runtime volume delete rejection remains hard failure

- Given an unreferenced existing candidate volume whose runtime `volume delete` fails
- When prune attempts deletion
- Then the command exits non-zero (hard failure)

#### Scenario: Recovery helper skip unchanged

- Given a marked recovery helper selected for prune
- When the user runs `adevcontainer prune --name <helper>`
- Then the helper, its referenced workspace/config volumes, and its image are not removed, and the command exits 0

#### Scenario: delete remains container-only

- Given any managed container
- When the user runs ordinary `adevcontainer delete --name <that-name>`
- Then only the container is removed; named volumes are not deleted by `delete`, and no force-volumes flag is required or introduced by this change

## REMOVED Requirements

None. (Unconditional “always delete labeled volumes” behavior is replaced by the attachment gate above; it is not a separately named removed requirement.)
