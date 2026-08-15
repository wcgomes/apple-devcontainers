# Proposal: Friendly container name

## Intent

Apple `container create --name` is the container id and DNS hostname, so this product cannot follow the official Dev Containers CLI (random runtime name, identity only via labels). Today's create name `adev-{base}-{hash12}` is stable but hostile as a hostname and as the value users type for `--name`. This change makes the create name the DNS-friendly sanitized `devcontainer.json` `name` (with the existing folder/repo fallback), and turns a *foreign* occupant of that name into a TTY ask — change the name? if yes, type the new name — then persist that sanitized `name` and retry.

## Scope

- Bind `up` and volume `clone` create-name identity in [core.md](../../core.md) **Deterministic identity and labels** and [clone.md](../../clone.md) **Volume-mode identity (git URL hash and names)**.
- Occupancy classification and collision UX for `up`/`clone` (same-workspace reuse and fail-closed paths stay; foreign occupant gets a Y/n then new-name prompt; same-workspace occupant under a different name gets a delete-hint). `rebuild` is the rename / naming-migration path.
- `${devcontainerId}` expands to the stable resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`), not the create `--name` / DNS hostname. Resource **base** is the workspace/repo basename fallback only — never sanitized config `name` ([core.md](../../core.md) **Variable substitution subset**).
- Presentation: TTY foreign-name offer is an interactive Y/n prompt then a name prompt on stderr, not QUIET-gated ([terminal-output.md](../../terminal-output.md) interactive-prompt rule). MUST NOT use a two-option recovery list or the bring-up recovery editor.
- Explicit non-regression: Features tags and product workspace volumes stay hashed `adev-{base}:…` / `adev-{base}-{hash12}-ws` with **resource base** = workspace/repo basename only; user-literal volume `source` strings stay as written.

## Non-goals

- Auto-renaming existing containers without `rebuild` (idle `adev-*` names stay until rebuild or delete). `up`/`clone` leftover different-name occupancy stays a delete-hint.
- Offering this foreign-name rename prompt on `start`.
- Opening bring-up recovery or any editor on this collision (the product writes `name` itself).
- A suffix-append choice or a two-option recovery list.
- Letting config `name` participate in `${devcontainerId}`, `*-ws`, or Features `nameBase`.
- Changing the hashed Features-tag / workspace-volume *format*, or rewriting user-literal volume sources.
- Silent reuse, replace, or attach when `clone` hits the same workspace already running under the computed name (still fail-closed; not rename-to-duplicate).
- Changing bring-up recovery, managed selection, `list`, prune, or rebuild recovery.

## Approach

Compute create `--name` as the sanitized `name` (or mode fallback), up to 63 characters, with no `adev-` prefix and no identity hash. Resource stem / `*-ws` / Features `nameBase` use the workspace (bind) or git-repo (volume) basename only — never config `name`. Classify any occupant of that name before create. Same-workspace labels keep today's `up` reuse / `config_hash_mismatch` / `clone` fail-closed behavior. A same-workspace container under a *different* name fails with a delete-hint on `up`/`clone`. `rebuild` creates the replacement under the live computed create name (sanitized `name` / fallback), reuses the product workspace volume and user-literal volume sources, and MUST NOT delete the old container until that new name is known and occupiable. A foreign occupant of the computed rebuild name uses the same TTY change-name offer (or non-TTY fail) as `up`/`clone`. Non-TTY and `--json` never prompt.

## Decision index

- **Create name is the sanitized `name`:** Apple `--name` is the id and hostname, so the product MUST use a DNS-friendly create name rather than a random runtime name or `adev-{base}-{hash12}`. Fallback remains sanitized workspace basename (`up`) or git URL repo basename (`clone`).
- **No `adev-` prefix and no identity hash on the create name:** those tokens made hostnames ugly and `--name` untypable; workspace identity stays on labels (bind: `local_folder`+`config_file`; volume: `git_url`+config identity).
- **Length budget is 63 characters:** the create name MAY use the full Apple/DNS budget; it MUST NOT reserve space for a prefix or hash. Resource base (workspace/repo basename only) still clips to about 20 characters for hashed sidecars.
- **Empty sanitize fails closed:** there is no `adev-{hash12}` create-name fallback. The error MUST ask for a DNS-safe `name`.
- **Sanitize alphabet unchanged:** lowercase; non-`[a-z0-9-]` → `-`; collapse consecutive hyphens; trim leading/trailing hyphens. Same rules apply to a typed new name.
- **Hashed sidecars stay hashed, base is folder/repo only:** product workspace volumes remain `adev-{base}-{hash12}-ws`; Features tags remain `adev-{base}:{contentHash}` (empty resource base → `adevcontainer:{contentHash}`). **Base** is sanitized workspace folder basename (`up`) or git URL repo basename (`clone`) — never config `name`. User-literal volume `source` is never rewritten.
- **`${devcontainerId}` is the resource identity stem, not the DNS name:** expand to `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`), the same hash material as `*-ws` (bind: path+config; volume: git URL+config relpath). Official `${devcontainerId}` means unique + stable across rebuilds — this stem is that analogue, not Docker’s random name and not Apple `--name`. Config `name` is human ID + DNS only and MUST NOT participate in the stem or any rebuild-stable resource identity. Rebuild that only changes `name` MUST keep the same stem (bind and volume).
- **Same-workspace, same name:** `up` keeps reuse / start-stopped / `config_hash_mismatch`→rebuild; `clone` stays fail-closed. Do not offer rename-to-duplicate.
- **Same-workspace, different name (`up`/`clone`):** fail with a delete-hint. Not this rename prompt. Leftover `adev-*` occupants stay on `up`/`clone`; `rebuild` is the rename path.
- **Foreign occupant:** warn with the reason (name in use, not the same workspace). Occupant MUST NOT be deleted. Same TTY offer on `up`/`clone` and on `rebuild` when the computed replacement name is foreign.
- **TTY rename prompt (not recovery):** ask whether to change the name (Y/n). Yes → prompt for the new **full** name (not a suffix), persist the sanitized value into `name`, retry from a re-resolve. Empty/invalid → re-prompt the name without persisting. Still colliding → re-ask. Decline/cancel/EOF → original error, occupant untouched. MUST NOT open bring-up recovery or any editor.
- **Non-TTY / `--json`:** never prompt; structured error plus edit/retry hint.
- **`start`:** this rename trigger MUST NOT fire.
- **`rebuild` uses the live computed create name:** replacement `--name` is the sanitized `name` / fallback from the live config, not `selected.name` when they differ. Do not delete the old container until the new name is known and occupiable. Product `*-ws`, user-literal volume sources, and `${devcontainerId}` volumes stay attached because they key off the stem, not the DNS name. Existing `adev-*` containers migrate to the short create name by rebuild.
- **Prompt presentation:** interactive Y/n then a name prompt on stderr; not QUIET-gated. Not a numbered/navigable recovery list.
- **No `design.md`:** the occupancy matrix and prompt outcomes fit a decision index plus normative scenarios.

## Clarifications

- **Q:** If the product already writes `name` into `devcontainer.json`, is a recovery editor needed on foreign-name collision?
  **A:** No. MUST NOT open bring-up recovery or any editor. Ask whether the user wants to change the name; if yes, prompt for the new full name; persist the sanitized value into `name` and retry.
- **Q:** Suffix or full name?
  **A:** Full name. MUST NOT append a suffix to the sanitized base and MUST NOT offer a two-option editor-or-suffix list.
- **Q:** What happens on `clone` after persist?
  **A:** A successful retry still overlays the persisted `name` into the workspace `devcontainer.json` after populate. Bind `up` remains host-edit only.
- **Q:** Should `rebuild` apply a `name` change, and can existing containers move to the new naming without losing workspace-volume references?
  **A:** Yes. `rebuild` MUST create the replacement under the current computed create name from the live config. The product workspace volume `adev-{base}-{hash12}-ws` and user-literal volume sources MUST stay attached. Do not delete the old container until the new name is known and occupiable. A foreign occupant of that new name uses the same TTY change-name offer (or non-TTY fail) as `up`/`clone`. Idle containers are not renamed until the user rebuilds.
- **Q:** Does `${devcontainerId}` equal the short create `--name`?
  **A:** No. `${devcontainerId}` MUST expand to the stable resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`), the same material as the product `*-ws` volume. Official meaning is unique + stable across rebuilds. Create name is only human identification and DNS.
- **Q:** Does config `name` participate in the resource stem, `*-ws`, or Features `nameBase`?
  **A:** No. Resource **base** MUST be the workspace folder basename (`up`) or git URL repo basename (`clone`) only. Example: `"name": "My App"` in folder `foo` → create name `my-app`, stem `adev-foo-{hash12}`, `${devcontainerId}-shellhistory` = `adev-foo-{hash12}-shellhistory`. A rebuild that only changes `name` MUST keep that stem (bind and volume).
