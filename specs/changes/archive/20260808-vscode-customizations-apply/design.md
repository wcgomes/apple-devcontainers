# Design: vscode-customizations-apply

Lean HOW for applying config-file `customizations.vscode` inside the guest. Outcome contract lives in `spec.md`; this file names concrete paths, merge/install mechanisms, marker layout, and ordering so implementers do not invent a second policy.

## Approach

Extend resolve to retain normalized vscode **extensions** (string IDs) and **settings** (JSON object) from the config file only (v1). After the container is running:

1. **Settings (create-path / drift repair):** merge into guest Machine settings at `~/.vscode-server/data/Machine/settings.json` under the effective `remoteUser` home (resolve home via `getent`/`eval echo ~user`/existing remoteUser exec patterns already used for lifecycle). Not gated on `--vscode`.
2. **Extensions (open-gated):** on first successful `--vscode` open, install missing IDs by **host VSIX download → tar-pipe into guest → unzip** into `~/.vscode-server/extensions`, then **upsert `extensions.json`** (Server registry) and best-effort **invalidate extensions.user.cache**. Folder unpack alone is insufficient for UI visibility. After each ID, BFS-install `package.json` `extensionDependencies` with cycle guard. Same CLI attach open-success gate as postAttach.
3. **Idempotency:** guest marker `$HOME/.adevcontainer/vscode-customizations.applied` containing a stable hash of normalized **config-file** extensions+settings only (transitive deps are side effects, not hash inputs). Skip when match; re-apply on drift.
4. **Order after open success:** extensions apply (soft-fail) → postAttach (unchanged fail-keep). Never use postAttachCommand as the apply vehicle.
5. **Soft-fail everything in apply:** warn on stderr; never fail lifecycle exit; never delete/stop container solely due to apply. Soft-fail apply ≠ postAttach fail-keep.

**Alternatives rejected:** relying on official Dev Containers / Apple attach to install extensions (spike disproved); **folder unpack only without registry upsert** (live validation: UI showed 0 installed while `extensions.json` was `[]`); embedding multi-MB VSIX as base64 in exec argv (ARG_MAX); applying only inside image build/Features Dockerfile; folding apply into `postAttachCommand`; hard-fail on marketplace/network errors; feature/metadata customizations merge in v1; gating settings on `--vscode`; blind re-apply every open/postAttach; waiting for full Server ready when VSIX seed works; changing create identity hash to include customizations; putting transitive dependency IDs into the marker hash.

## Significant decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Source v1 | Config-file `customizations.vscode` only | Matches spike configs; feature/metadata merge is phase 2 |
| Parse resilience | Admit object; soft-skip bad nested types with warn | Matches “does not fail” admission; avoid brittle configs |
| Model | Replace bool-only with retained `[String]` extensions + settings object (JSON/`[String: Any]` or typed envelope) | Apply needs payload, not only intent flag |
| Settings path | `~/.vscode-server/data/Machine/settings.json` under effective remote user home | Remote Machine settings scope used by VS Code Server |
| Settings merge | Read existing JSON object if present; set/override declared keys; write back pretty or compact valid JSON; create dirs | Preserve unrelated user/server keys when feasible |
| Settings when | After create-path hooks on fresh `up`/`clone`; repair on `start`/reuse when marker drift and config loadable | Editor not required for Machine settings file |
| Extensions path | `~/.vscode-server/extensions/<publisher.extension-version>/` via VSIX unpack | Works without Server UI; common remote layout |
| Extensions fetch | **Host** marketplace VSIX download → **tar-pipe** (`copyTreeIntoContainer`) into guest `/tmp` → guest unzip (not base64-in-argv) | Avoids ARG_MAX; guest network optional |
| Registry | Upsert `~/.vscode-server/extensions/extensions.json`; install incomplete until listed | Live validation: folder-only → UI 0 installed |
| Cache invalidate | Best-effort delete `~/.vscode-server/data/CachedProfilesData/__default__profile__/extensions.user.cache` when registry dirty | Server reloads registry on next read/reload |
| extensionDependencies | BFS after each ID from unpacked `package.json`; visited bare-id cycle guard; soft-fail per ID | e.g. Swift → `llvm-vs-code-extensions.lldb-dap` without listing dep in config |
| Extensions when | After successful `--vscode` open; pending via marker | Same attach approximation as postAttach; manual attach without flag unsupported |
| Order | open success → extensions apply → postAttach | Spec: separate step; postAttach fail-keep unchanged |
| Marker path | `$HOME/.adevcontainer/vscode-customizations.applied` | Stable, namespaced, easy to inspect/debug |
| Marker content | Hex/digest of canonical **config** payload (sorted config extension IDs + canonical JSON settings) — **not** transitive deps | Drift detection without recreate; deps are side effects |
| Marker write | Only after full normalized payload successfully applied (registry upsert included for listed IDs); if extensions pending (no open yet), do not finalize full-hash marker — allow settings re-merge idempotently until extensions complete, then write full hash | Ensures first successful open still installs extensions |
| Soft-fail | All apply I/O/network/exec; per-ID continue on dep failure | Lifecycle reliability > perfect editor setup; ≠ postAttach fail-keep |
| Identity | customizations omitted from `hashMaterial()` (status quo) | Config edit applies in-place via marker drift |
| Config load on start | Reuse `PostAttachConfigLoader` (or extend it) to obtain extensions/settings on bare `start` | Same label/path recovery as postAttach |
| Process boundary | Exec into container as effective user; mockable runner in tests | Unit tests without real marketplace/VS Code |
| postAttach | Unchanged API and fail-keep | Different policy; do not couple |
| UI refresh | User may need Reload Window once after first registry write | CLI does not force IDE reload |

### Marker and pending semantics (v1 concrete)

Normalized payload `P = { extensions: sorted unique trimmed **config-file** IDs, settings: canonical JSON object }`. Transitive `extensionDependencies` are **not** part of `P`.

- `H = hash(P)` (e.g. SHA-256 hex of a stable encoding).
- Read marker `M` from guest if present.
- If `M == H`: skip all apply for this payload.
- If `M != H` or missing:
  - **Settings:** if `settings` non-empty (or always merge when `P` includes settings keys), merge Machine settings when on create-path or drift-repair path.
  - **Extensions:** only if open success and extensions non-empty; install missing (folder + registry + BFS deps).
  - If payload has **no** extensions: after successful settings merge (or no-op settings), write `M = H`.
  - If payload **has** extensions: write `M = H` only after settings (when any) and extensions both succeeded for this `P` (registry upsert for config IDs included). If open did not run, leave marker stale/missing until full success; settings merge is always safe to re-run (key overlay); skip only when `M == H`.

### Extension install (v1 concrete)

**Complete install** = extension folder on disk **and** entry in Server registry `~/.vscode-server/extensions/extensions.json`. Folder unpack alone leaves UI at 0 installed when registry is `[]`.

**Transfer:** host marketplace VSIX download → stage on host temp → `copyTreeIntoContainer` (tar-pipe into guest `/tmp`) → guest `unzip` into `~/.vscode-server/extensions/<publisher.name-version>/`. Do **not** base64-embed VSIX in exec argv (ARG_MAX).

**BFS queue + deps:**

```text
queue = config extension IDs
visited = {}  # bare publisher.name lowercased
while queue non-empty:
  id = dequeue; bare = bareId(id); skip if bare in visited; mark visited
  if folder present:
    if not in extensions.json → upsert registry entry
  else:
    host download VSIX → tar-pipe → guest unzip → upsert registry
    on fail: warn; soft-fail that ID; continue (no dep expand for failed ID)
  read package.json extensionDependencies → enqueue unvisited deps
if registry dirty:
  write extensions.json
  best-effort rm extensions.user.cache
# then marker only if full config payload succeeded
```

**Registry entry essentials** (VS Code Server shape; upsert by `identifier.id` case-insensitive):

| Field | Role |
|-------|------|
| `identifier.id` | bare `publisher.name` (lowercase) |
| `version` | from pin, folder name, or fallback |
| `location` | `{ $mid: 1, path: <abs folder>, scheme: "file" }` |
| `relativeLocation` | install folder name under extensions dir |
| `metadata` | e.g. `installedTimestamp`, `pinned`, `source: "vsix"` |

**Cache path:** `~/.vscode-server/data/CachedProfilesData/__default__profile__/extensions.user.cache` — delete best-effort when registry changes so Server re-reads `extensions.json`.

**Marker:** hash of sorted **config** IDs + canonical settings only. Transitive deps (e.g. `lldb-dap` pulled by Swift) are not config entries and do not expand the hash.

Do **not** invoke postAttach or require `code --install-extension` inside the guest unless a spike proves it without Server. User may need **Reload Window** once after first successful registry write.

### Settings merge (v1 concrete)

```text
path = "$HOME/.vscode-server/data/Machine/settings.json"  # effective remoteUser HOME
mkdir -p "$(dirname path)"
existing = {} if missing else parse JSON object (if parse fails → warn soft-fail or backup+replace only declared keys — prefer soft-fail without destroying non-JSON)
merged = existing ⊕ config.settings  # config keys win
atomic write merged JSON
```

### Home / user

Use the same effective user as lifecycle exec (`remoteUser` prefer, else `containerUser`, else container default). All marker, settings, and extensions paths are relative to that user’s home inside the guest.

## Flow

```text
resolve config
  → parse customizations.vscode
  → retain extensions[] + settings{} (soft-skip bad nested types)
  → hasVscodeCustomizations intent may remain derived

fresh up/clone create-path success (hooks done)
  → if marker != H and settings present (or full P pending):
        merge Machine settings (soft-fail)
  → if no extensions in P and settings apply ok (or empty):
        write marker H
  → else leave marker until extensions complete

--vscode? ──no──► extensions not applied; postAttach skip-as-today
    │
    yes
    ▼
  open attempt
    │
  soft-fail ──► extensions skip; postAttach skip-as-today
    │
  success (CLI attach hook)
    ▼
  if marker != H and extensions pending:
        BFS install (host VSIX → tar-pipe → unzip → registry upsert → deps)
        invalidate extensions.user.cache if registry dirty
        if full P applied ok → write marker H
    ▼
  postAttach run/skip per existing policy (fail-keep)
```

```text
start / up reuse
  → load config (PostAttachConfigLoader paths + feature postAttach merge as today)
  → if marker != H: settings repair (soft-fail)
  → if --vscode and open success and marker != H: extensions apply then marker
  → postAttach gate unchanged
```

## Artifact changes

| Area | Nature |
|------|--------|
| `Sources/ADevContainerLib/Config/DevContainerConfig.swift` | Retain `vscodeExtensions: [String]`, `vscodeSettings` (structured JSON), keep or derive `hasVscodeCustomizations`; ensure `hashMaterial()` still omits customizations |
| `Sources/ADevContainerLib/Config/ConfigResolver.swift` | Parse/normalize extensions + settings; resilient nested types |
| `Sources/ADevContainerLib/Config/ConfigAdmissions.swift` | Comments/policy: admit object; no new hard-fail for nested vscode shapes |
| `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift` (new) | Hash/normalize; marker read/write; settings merge; VSIX install; soft-fail helpers; mockable exec/download seams |
| `Sources/ADevContainerLib/Commands/LifecycleRunner.swift` or apply orchestrator | Optional thin wrappers for create-path settings + post-open extensions order |
| `Sources/ADevContainerLib/Commands/UpCommand.swift` | After create-path hooks: settings apply; after open success: extensions then postAttach |
| `Sources/ADevContainerLib/Commands/CloneCommand.swift` | Same create-path settings + post-open extensions ordering |
| `Sources/ADevContainerLib/Commands/StartCommand.swift` | Load config; settings repair on drift; extensions after open success; then postAttach |
| `Sources/ADevContainerLib/Commands/PostAttachConfigLoader.swift` | Ensure loaded config includes vscode extensions/settings (not bool-only) for start/reuse |
| `Sources/adevcontainer/AdevcontainerMain.swift` | Help text: customizations apply behavior |
| `Tests/adevcontainerTests/` | Parse; hash/marker; settings merge; extensions install mocks; gates; soft-fail; order vs postAttach; identity hash exclusion |
| `README.md` | Document apply gates, soft-fail, marker, no full parity |

### Test seams

- Inject container exec / file read-write / HTTP download protocols so unit tests never hit the real marketplace or require a real VM.
- Fixture configs under `Tests/Fixtures/` with sample `customizations.vscode` shapes (well-formed, bad extensions type, bad settings type, empty).
