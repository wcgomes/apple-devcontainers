# Change Spec: friendly-container-name

## ADDED Requirements

### Requirement: Create-name occupancy classification

Before `up` or `clone` creates a container, the CLI MUST classify any existing container whose runtime name equals the desired create name, and MUST classify any existing managed container for the same workspace under a different runtime name.

**Same workspace** means the occupant’s managed labels match this invocation:

| Mode | Matching labels |
|------|-----------------|
| Bind (`up`) | `devcontainer.local_folder` + `devcontainer.config_file` equal this workspace path and config path |
| Volume (`clone`) | `devcontainer.git_url` + config identity (`devcontainer.config_file` / repo-relative config path) equal this normalized git URL and config relative path |

**Classification — MUST**

| Occupant | Command | Outcome |
|----------|---------|---------|
| Same workspace, same create name, managed | `up` | Existing reuse, start-stopped, or `config_hash_mismatch` → hint `rebuild`. MUST NOT offer a rename-to-duplicate path. |
| Same workspace, same create name, managed | `clone` | Fail closed with a structured error naming the existing container. MUST NOT silently reuse, replace, attach, or offer rename-to-duplicate. |
| Same workspace, different runtime name (managed or not) | `up` / `clone` | Fail with a structured error and a delete-hint. MUST NOT offer the foreign-name rename prompt. MUST NOT silently reuse, rename, or attach. |
| Desired create name taken by a different workspace identity, or by an unmanaged container | `up` / `clone` | Foreign occupant — see **Foreign create-name collision offer**. |
| No occupant of the desired create name, and no same-workspace container under another name | `up` / `clone` | Create under the desired create name. |

`start` MUST NOT apply this classification as a create-name collision trigger. `rebuild` MUST NOT use this `up`/`clone` leftover delete-hint; it is the rename / naming-migration path — see **Rebuild replacement create name**.

Idle containers (no `rebuild` or delete) MUST keep their runtime names. `up`/`clone` MUST NOT auto-rename an existing `adev-*` occupant.

#### Scenario: up reuses same-workspace same-name occupant

- Given a managed bind-mode container whose create name equals the desired create name and whose `local_folder`+`config_file` match this workspace
- When the user runs `up` and the stamped config hash matches
- Then the CLI reuses or starts that container and MUST NOT prompt to rename

#### Scenario: up hash mismatch on same-workspace same-name occupant

- Given a managed bind-mode container whose create name equals the desired create name and whose workspace labels match, but stamped `devcontainer.config_hash` differs
- When the user runs `up`
- Then the CLI fails with `config_hash_mismatch`, does not delete the occupant, and does not offer the foreign-name rename prompt

#### Scenario: clone fails closed on same-workspace same-name occupant

- Given a managed volume-mode container whose create name equals the desired create name and whose git URL + config identity match this clone
- When the user runs `clone` for that identity
- Then the CLI fails with a structured error naming the existing container and MUST NOT create, start, populate, or offer rename-to-duplicate

#### Scenario: same-workspace occupant under a different name is a delete-hint

- Given a managed container for this workspace already exists under a different runtime name (including a leftover `adev-*` name)
- When the user runs `up` or `clone` for that workspace
- Then the CLI fails with a structured error that hints to delete the existing container and MUST NOT present the foreign-name rename prompt

#### Scenario: start does not offer create-name collision

- Given a managed container selectable by `--name` or the managed picker, and some other container already uses a name that would collide with a sanitized config `name`
- When the user runs `start`
- Then start does not classify or offer a create-name collision rename prompt

#### Scenario: no idle migration of existing containers

- Given an existing managed container whose runtime name is `adev-{base}-{hash12}`
- When the user does not delete or rebuild it
- Then that container keeps its runtime name and `up`/`clone` do not rename it

---

### Requirement: Rebuild replacement create name

`rebuild` MUST create the replacement container under the **current** computed create name from the live config (sanitized `name` when set, else the mode fallback), not under `selected.name`, when those values differ.

The product MUST NOT delete the selected (old) container until that replacement create name is known and occupiable. If the computed name is taken by a **foreign** occupant, `rebuild` MUST follow **Foreign create-name collision offer** and MUST leave the selected container in place.

When the replacement is created, `rebuild` MUST:

- Reuse the existing product workspace volume `adev-{base}-{hash12}-ws` (volume mode) with its data. MUST NOT rename, delete, or re-populate that volume.
- Reuse user-literal volume `source` strings as written (same attach/reuse as today’s rebuild).
- Expand `${devcontainerId}` in mounts to the **same** resource identity stem as before the rebuild (`adev-{base}-{hash12}`, empty resource base → `adev-{hash12}`), not to the new create name, so those volumes are reused. Config `name` MUST NOT change that stem.

When the computed create name equals the selected name, `rebuild` MUST keep today’s same-name replacement behavior (container-only delete then create under that name).

#### Scenario: rebuild after editing name uses the new create name

- Given a managed container whose live config `name` was edited so the computed create name differs from the selected runtime name
- When the user runs `rebuild` for that selected container and the new name is occupiable
- Then the replacement is created under the new computed create name, the old container is gone, the product `*-ws` volume is reused with its data, and user-literal volume sources remain attached as written

#### Scenario: rebuild migrates an adev-* name to the short computed name

- Given a managed container named `adev-myapp-abc123def456` whose live config `name` still sanitizes to `myapp`
- When the user runs `rebuild` for that selected container and `myapp` is occupiable
- Then the replacement is named `myapp`, the old `adev-myapp-abc123def456` container is gone, and the product `*-ws` volume is reused

#### Scenario: rebuild same computed name is unchanged

- Given a managed container whose selected runtime name already equals the live computed create name
- When the user runs `rebuild` for that container
- Then the replacement is created under that same name (today’s same-name rebuild)

#### Scenario: rebuild foreign occupant does not delete the selected container

- Given a managed container selected for rebuild whose computed create name is taken by a foreign occupant
- When the user runs `rebuild`
- Then the CLI MUST NOT delete the selected container and MUST follow **Foreign create-name collision offer** (TTY change-name prompt, or non-TTY/`--json` structured fail + hint)

#### Scenario: rebuild keeps the same devcontainerId stem when create name changes

- Given a bind workspace folder `foo` (or volume-mode repo basename `foo`) whose identity stem is `adev-foo-{hash12}`, a volume mount `source=${devcontainerId}-shellhistory`, and a rebuild that only changes config `name` so the create name becomes `myapp`
- When the replacement is created
- Then that mount source is still `adev-foo-{hash12}-shellhistory` and the shell-history volume is reused

---

### Requirement: Foreign create-name collision offer

When occupancy classification yields a **foreign occupant** of the desired create name on `up`, `clone`, or `rebuild`, the CLI MUST warn that the name is in use and is not the same workspace, and MUST NOT delete, replace, or attach to that occupant. On `rebuild`, the selected container MUST remain until the replacement create name is known and occupiable. The CLI MUST NOT open bring-up recovery or any editor on this path, MUST NOT offer a suffix-append choice, and MUST NOT present a two-option recovery list.

**TTY (stdin is a TTY and `--json` is absent) — MUST**

1. Emit the warning with that reason.
2. Ask whether the user wants to change the name (Y/n) on stderr. This prompt is interactive and MUST remain usable under QUIET (not a silenced progress line).
3. On yes: prompt for the new **full** name (not a suffix appended to the current base). Sanitize with the same DNS-safe rules as create-name identity (no `adev-` prefix, no identity hash, ≤ 63 characters). Persist that sanitized value into the editable config `name` (`up`: host `devcontainer.json`; `clone`: retained checkout; `rebuild`: the live config this rebuild is reading) so the next `up`/`clone`/`rebuild` of this config is stable, then retry MUST re-resolve. MUST NOT delete the occupant (on `rebuild`, MUST NOT delete the selected container).
4. A name that is empty after sanitize, or that is not a DNS-safe name of at most 63 characters, MUST re-prompt for the new name without persisting.
5. If the name after persist is still a foreign occupant (or otherwise still collides), the CLI MUST re-ask (warn that this name is also in use, then Y/n again).
6. Decline, cancel, or EOF at the Y/n prompt or the name prompt MUST fail with the original structured name-in-use error. The occupant MUST remain untouched.
7. A successful `clone` retry after a persisted `name` MUST leave that `name` in the workspace `devcontainer.json` after populate, matching **Clone recovery persists edited config into workspace**. Bind `up` remains host-edit only.

**Non-TTY or `--json` — MUST**

- Never prompt, never open an editor, never collect a new name.
- Fail with a structured error plus an edit/retry hint (`up`: host config path; `clone`: retained checkout and exact retry command when retention applies; `rebuild`: hint to free or change `name` and retry `rebuild --name` of the still-present selected container).
- Leave the occupant untouched. On `rebuild`, the selected container MUST still exist.

`start` MUST NOT offer this rename prompt. `rebuild` MUST offer it when the computed replacement name is a foreign occupant.

#### Scenario: TTY asks whether to change the name

- Given the desired create name is already used by a container for a different workspace (or an unmanaged container), and stdin is a TTY without `--json`
- When the user runs `up`, `clone`, or `rebuild`
- Then the CLI warns that the name is in use and not the same workspace, and asks whether to change the name (Y/n) on stderr
- And the CLI MUST NOT open an editor or present an editor-or-suffix list

#### Scenario: yes prompts for the new full name and persists it

- Given a TTY foreign-name offer
- When the user affirms and types `My App 2` (or `my-app-2`)
- Then the product persists `name` as `my-app-2` (or the equivalent sanitized result) into the editable config, retries from a re-resolve, and creates under that name when it is free
- And the foreign occupant still exists unchanged

#### Scenario: successful clone rename retry leaves name in the workspace config

- Given a TTY foreign-name offer on `clone`, a persisted new `name`, and a successful retry through populate
- When the workspace `devcontainer.json` is read inside the new container
- Then `name` is the persisted create name, not the original git-populated value

#### Scenario: empty or invalid name re-prompts

- Given a TTY foreign-name offer and the user affirmed the change-name question
- When the user types a name that sanitizes to empty or is not DNS-safe within 63 characters
- Then the CLI does not persist `name` and re-prompts for the new name

#### Scenario: still-colliding name re-asks

- Given a TTY foreign-name offer and the user types a new name that is also occupied by a foreign occupant
- When that name would be persisted
- Then the CLI does not delete either occupant and re-asks whether to change the name

#### Scenario: decline leaves the occupant untouched

- Given a TTY foreign-name offer
- When the user declines, cancels, or sends EOF
- Then the CLI fails with the original name-in-use error and the occupant is unchanged

#### Scenario: non-TTY and json never prompt

- Given the same foreign occupant and a non-TTY stdin or `--json`
- When the user runs `up`, `clone`, or `rebuild`
- Then the CLI never prompts or opens an editor, fails with a structured error plus an edit/retry hint, and leaves the occupant untouched
- And on `rebuild` the selected container is still present

#### Scenario: rename prompts remain usable under QUIET

- Given `ADEVCONTAINER_QUIET=1` and a TTY foreign-name offer
- When the Y/n or new-name prompt is presented
- Then those prompts and the warning remain usable on stderr (not classified as silenced progress)

---

### Requirement: Hashed sidecar names and literal volume sources stay

This change MUST NOT use config `name` as the **base** of product-generated Features tags, product workspace volumes, or `${devcontainerId}`. Those stay hashed `adev-{base}:…` / `adev-{base}-{hash12}-ws` / `adev-{base}-{hash12}` where **base** is the workspace/repo basename only. User-literal volume `source` strings stay as written.

- Features derived tags MUST remain `adev-{base}:{contentHash}` where `base` is the resource base (about-20-character clip of the workspace folder basename on `up`, or git URL repo basename on `clone`) and `contentHash` is the Features content hash including `recipeVersion`. Empty resource base MUST still map to `adevcontainer:{contentHash}`. MUST NOT use sanitized config `name` or the short create name as the tag, and MUST NOT drop the `adev-` tag prefix.
- Volume-mode product workspace volumes MUST remain `adev-{base}-{hash12}-ws` using that same resource base and the volume-mode identity `hash12` (normalized git URL + config relative path). MUST NOT rename the workspace volume to the short create name or to sanitized config `name`.
- A config or feature mount `source` that is a user-written literal (no unsubstituted `${devcontainerId}` token) MUST be used as written. The product MUST NOT rewrite that literal to include the create name, an `adev-` prefix, or an identity hash.
- `${devcontainerId}` MUST expand to the resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`), using the same hash material and the same resource base as the product workspace volume. It MUST NOT expand to the create `--name` / DNS hostname and MUST NOT include sanitized config `name` in the stem. This is not a rewrite of a user-literal source.

#### Scenario: Features tag keeps hashed adev- form

- Given a Features build in workspace folder `foo` with `"name": "My App"`
- When the derived image tag is computed
- Then the tag is `adev-foo:{contentHash}` and is not `adev-my-app:{contentHash}` or `my-app:{contentHash}`

#### Scenario: workspace volume keeps hashed adev- form

- Given a clone whose git URL repo basename is `foo`, config `"name": "My App"`, and identity `hash12`
- When the workspace volume name is computed
- Then the volume name is `adev-foo-{hash12}-ws` and is not `adev-my-app-{hash12}-ws` or `my-app-ws`

#### Scenario: user-literal volume source is not rewritten

- Given a config `type=volume` mount whose `source` is the literal `team-cache`
- When the container is created or rebuilt under create name `my-app`
- Then the volume source remains `team-cache` and is not rewritten to `my-app-team-cache` or `adev-my-app-{hash}-team-cache`

#### Scenario: devcontainerId token expands to the resource identity stem

- Given a feature mount `source=${devcontainerId}-shellhistory`, config `"name": "My App"`, workspace folder basename `foo`, and identity `hash12`
- When the container is created
- Then the create name is `my-app` and the volume name is `adev-foo-{hash12}-shellhistory` (not `adev-my-app-{hash12}-shellhistory` or `my-app-shellhistory`)

#### Scenario: bind and volume devcontainerId stems stay distinct

- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`, both without an overriding `name`
- When `${devcontainerId}` is expanded
- Then the bind stem uses path+config `hash12` and the volume stem uses git URL+config relpath `hash12`, matching each mode’s `*-ws` material, so the stems are not required to match

---

## MODIFIED Requirements

### Requirement: Variable substitution subset

After parse, the resolver MUST apply this substitution subset anywhere string values appear in supported properties:

| Token | Replacement |
|-------|-------------|
| `${localWorkspaceFolder}` | Absolute path of the workspace root |
| `${localWorkspaceFolderBasename}` | Basename of the workspace root |
| `${localEnv:VAR}` | Value of host environment variable `VAR` (empty string if unset, unless a default form is later specified) |
| `${containerWorkspaceFolder}` | Resolved container workspace folder path (after `workspaceFolder` resolution) |
| `${devcontainerId}` | Resource identity stem `adev-{base}-{hash12}` (empty resource base → `adev-{hash12}`). **Base** is the sanitized workspace folder basename (`up`) or git URL repo basename (`clone`) only — MUST NOT use config `name`. Hash material matches the product workspace volume (bind: workspace path + config path; volume: normalized git URL + config relative path). MUST NOT be the create `--name` / DNS hostname. Official meaning is unique + stable across rebuilds; this stem is that analogue. |

Unsupported substitution tokens MUST cause a structured error naming the token. Substitution MUST run before runtime admission and mount/port mapping.

**`${devcontainerId}` lifecycle — MUST**

- Feature metadata mounts (and config mounts) MAY embed `${devcontainerId}` in volume `source` (e.g. shell-history `source=${devcontainerId}-shellhistory`).
- When the resource identity stem is not yet known at config resolve, the token MAY remain unsubstituted through resolve.
- Before named-volume ensure and `container create`, the CLI MUST expand `${devcontainerId}` to the resource identity stem so Apple volume names match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`.
- Volume-mode config hash / `devcontainer.config_volumes` labels MUST use post-expansion mount sources so identity stays stable and prune sees real volume names.
- A rebuild that only changes config `name` (create name) MUST expand `${devcontainerId}` to the same stem as before so those volumes are reused.

#### Scenario: localEnv in mount source
- Given `containerEnv` or a mount `source` containing `${localEnv:HOME}/.kube/config` and `HOME` is set on the host
- When config is resolved
- Then the token is replaced with the host value

#### Scenario: devcontainerId in feature volume mount source
- Given a feature mount `source=${devcontainerId}-shellhistory` (type volume), workspace folder `foo`, `"name": "My App"`, and identity `hash12`
- When the container is created
- Then the volume name is `adev-foo-{hash12}-shellhistory` and volume create succeeds

#### Scenario: Unknown substitution token
- Given a string value containing `${unknownToken}`
- When config is resolved
- Then the CLI fails with a structured error naming `unknownToken`

---

### Requirement: Deterministic identity and labels

On create, the CLI MUST assign a deterministic container name and MUST set labels. Apple `container create --name` MUST equal the container id used for later inspect/exec/stop/delete/start.

Sanitize MUST be DNS-safe: lowercase; replace each run of characters outside `[a-z0-9-]` with `-`; collapse consecutive hyphens; trim leading/trailing hyphens.

`name` is not metadata-only: when set (non-empty after trim), it MUST drive the **create name** (DNS / human identification). It MUST NOT drive the resource base used for `${devcontainerId}`, Features derived image tags, or product workspace volumes.

When `features` is present, config hash material MUST include the selected feature refs, options, and ordered identity inputs. Changing features MUST change config hash so reuse and drift detection remain correct (a new create path runs when features change).

**Bind-mode (`up`) workspace identity** MUST remain: `hash12` from workspace path + config path is still the bind-mode identity hash for hashed sidecars that need it. Reuse and occupancy MUST key off labels (`devcontainer.local_folder` + `devcontainer.config_file`), not off embedding that hash in the create name. On create, labels MUST include:

| Label | Requirement |
|-------|-------------|
| `devcontainer.managed` | MUST be `adevcontainer` |
| `devcontainer.workspace_mode` | MUST be `bind` |
| `devcontainer.local_folder` | Absolute host workspace path |
| `devcontainer.config_file` | Config path used |
| `devcontainer.config_hash` | Per existing drift/identity policy |
| `devcontainer.workspace_folder` | Container workspace folder |
| `devcontainer.remote_user` | MUST be the **resolved remote connection user** (non-empty). MUST NOT be stamped empty on a successful create. |
| `devcontainer.config_volumes` | Comma-separated config `type=volume` sources when any; omit/empty otherwise |
| `devcontainer.git_url` / `devcontainer.workspace_volume` | MUST NOT be set (or empty; prune ignores missing ws vol) |

**Resource base** (rebuild-stable sidecars only)

1. Sanitize the workspace folder basename (bind) or the git URL repo basename (volume). MUST NOT use config `name`.
2. Clip the resource base to about 20 characters.
3. Resource base is used for Features tags, the product workspace volume, and the `${devcontainerId}` stem only. An empty resource base after sanitize/clip MUST NOT invent a hashed create name; create-name emptiness is a structured failure (below). Features empty-base tag fallback `adevcontainer:{contentHash}` remains for the tag path. Empty resource base for the stem is `adev-{hash12}`.

**Create name (container id / DNS hostname)**

1. If `devcontainer.json` `name` is present and non-empty after trim → sanitize that value.
2. Else → sanitize the workspace folder basename (bind) or the git URL repo basename (volume).
3. MUST NOT prefix `adev-`. MUST NOT append an identity hash.
4. The create name MUST be ≤ 63 characters and MAY use the full 63-character budget. If the sanitized value exceeds 63, the product MUST clip to 63 characters and trim leading/trailing hyphens afterward.
5. If the create name is empty after sanitize (and clip/trim), the CLI MUST fail with a structured error that asks the user to set a DNS-safe `name` in `devcontainer.json`. MUST NOT fall back to `adev-{hash12}` or any other invented create name.
6. Occupancy of that create name MUST follow **Create-name occupancy classification**.

**Volume-mode (`clone`) identity** MUST use the volume-mode identity and labels requirements (git URL + config relative path; managed/volume labels; adapted `local_folder`). Bind and volume workspace hashes MUST stay distinct. Two invocations MAY still compute the same create name when sanitized `name` / fallback values match; that is a name occupancy, not a hash collision. Volume-mode create MUST stamp `devcontainer.remote_user` to the same **resolved remote connection user** (non-empty) as bind-mode.

On every successful managed create (`up` bind, `clone` volume, `rebuild` new container), the product MUST stamp `devcontainer.remote_user` to the resolved remote connection user from **Remote connection user resolution**.

Greenfield: existing containers with empty labels are out of scope for automatic repair; `exec` continues to honor whatever is stamped (empty → omit `-u` on exec as today). New creates MUST always stamp non-empty.

Discovery and reuse MUST prefer create name + inspect + managed labels, NOT Docker-style `ps --filter label=` as the primary mechanism. Discovery of managed containers for `list` / `start` / extended `stop` MUST filter client-side on `devcontainer.managed=adevcontainer` after machine JSON list (Apple `container` has no label filter API).

#### Scenario: Stable name across invocations
- Given the same workspace path, config `name`, and config content
- When `up` is invoked twice without delete
- Then the second invocation reuses the same create name and same-workspace occupant rather than creating a conflicting duplicate

#### Scenario: Container name uses config name when set
- Given a config with `"name": "My App"` and a workspace folder basename `foo`
- When the container name and resource stem are computed
- Then the create name is `my-app` (DNS-safe sanitize of `My App`) and the resource stem is `adev-foo-{hash12}` (not `adev-my-app-{hash12}`)

#### Scenario: Container name falls back to workspace basename
- Given a config with no `name` (or only whitespace) and workspace folder basename `other-folder`
- When the container name is computed
- Then the create name is the sanitized workspace folder basename (`other-folder` or equivalent sanitize result) with no `adev-` prefix and no identity hash

#### Scenario: Empty sanitize asks for a DNS-safe name
- Given a config whose `name` (or fallback basename, when `name` is omitted) sanitizes to empty
- When `up` or `clone` computes the create name
- Then the CLI fails with a structured error asking for a DNS-safe `name` and MUST NOT create a container named `adev-{hash12}`

#### Scenario: Create name may use 63 characters
- Given a sanitized create name of 63 `a-z0-9-` characters
- When the container is created
- Then Apple `create --name` equals that 63-character value

#### Scenario: Punctuation-heavy name collapses hyphens
- Given a config with `"name": "C# (.NET)"` and workspace folder basename `proj`
- When the create name and resource base are computed
- Then the create name is `c-net` (not `c----net`) and the resource base is the sanitized folder basename (`proj`), not `c-net`

#### Scenario: Labels present on inspect
- Given a container created by `up`
- When the user runs `adevcontainer inspect`
- Then local folder, config file, and config hash labels/fields are visible in the inspect output

#### Scenario: Features participate in identity hash
- Given two configs identical except for a feature option value
- When config hashes are computed
- Then the hashes differ

#### Scenario: Bind and volume modes distinct workspace hashes
- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`, both without an overriding `name`
- When identities are computed
- Then bind hash material (path+config) differs from volume hash material (git URL+config relpath) so workspace-volume names stay mode-specific
- And both create names are the sanitized `foo` (or equivalent); if that name is already taken by the other mode, occupancy classification applies

#### Scenario: Up create stamps managed bind labels
- Given a successful `up` create
- When labels are inspected
- Then `devcontainer.managed=adevcontainer`, `workspace_mode=bind`, local_folder/config_file/config_hash/workspace_folder/remote_user are set, and git_url/workspace_volume are absent

#### Scenario: Up create stamps non-empty remote_user from resolution
- Given a successful `up` create with neither config user set and OCI `USER` `node`
- When labels are inspected
- Then `devcontainer.remote_user` equals `node` (non-empty)

#### Scenario: Clone create stamps remoteUser when set
- Given a successful `clone` create with `remoteUser` `alice`
- When labels are inspected
- Then `devcontainer.remote_user` equals `alice`

#### Scenario: Rebuild refreshes remote_user to newly resolved connection user
- Given a managed container whose edited config changes `remoteUser` from `alice` to `bob`
- When the user runs `adevcontainer rebuild --name <that-name>` successfully
- Then the new container’s `devcontainer.remote_user` is `bob`

See also: [clone.md](../../clone.md) for volume-mode identity, workspace volume names, and volume-mode labels; **Remote connection user resolution** for the stamp value.

---

### Requirement: Volume-mode identity (git URL hash and names)

For containers created by `clone`, deterministic identity MUST be derived as follows.

**Hash material (`hash12`)**

- MUST hash **normalized git URL** + **config relative path** (path within the repo, e.g. `.devcontainer/devcontainer.json`).
- MUST NOT use the host temporary directory path as durable hash material (temp paths change per invocation).
- This `hash12` MUST continue to identify the product workspace volume. It MUST NOT be appended to the create name.

**URL normalization (`normalizeGitURL`) — MUST**

- Trim surrounding whitespace.
- Strip trailing `/` and a trailing `.git` suffix (case-insensitive on the suffix); re-strip trailing `/` after `.git` removal.
- For `scheme://` URLs: lowercase the scheme and **MUST strip `userinfo@`** (user, `user:pass`, or token) before the host so embedded credentials never enter hash material, labels, or success JSON.
- SCP-like forms (`git@host:path`) MUST retain the username segment — it is not secret userinfo and is required shape.
- Normalization MUST be deterministic and covered by tests.
- Host `git` invocations MUST still receive the **original** (caller-supplied) URL so credential helpers and embedded tokens continue to work; only identity/labels/JSON use the normalized form.

**Resource base**

1. Sanitize the **repository basename** derived from the git URL (not a host folder basename and not config `name`).
2. Clip to about 20 characters for hashed sidecar names only.

**Create name**

- The create name MUST be the sanitized `name` when set, else the sanitized repository basename, with no `adev-` prefix and no identity hash, ≤ 63 characters (MAY use the full 63-character budget).
- Empty create name after sanitize MUST fail with a structured error asking for a DNS-safe `name`.
- Occupancy MUST follow **Create-name occupancy classification**.

**Workspace volume name**

- Format: `adev-{base}-{hash12}-ws` (resource base + identity `hash12`, not the short create name and not sanitized config `name`).
- MUST include workspace identity material and the `-ws` suffix.
- If the name must be clipped to satisfy runtime length limits, the implementation MUST retain `hash12` and the `-ws` suffix (clip the base / middle as needed).

Apple `container create --name` MUST equal the container id used for later inspect/exec/stop/delete/start, consistent with the base contract.

#### Scenario: Volume name includes workspace identity not the short create name
- Given a clone whose repo basename sanitizes to `foo`, config `"name": "My App"`, and a computed `hash12`
- When container and workspace volume names are computed
- Then the create name is `my-app` and the workspace volume name is `adev-foo-{hash12}-ws` (or a clipped form that still contains `{hash12}` and ends with `-ws`)

#### Scenario: Same URL and config path stable identity
- Given the same normalized git URL and config relative path
- When identity is computed on two separate clone invocations (different temp dirs)
- Then `hash12` and the workspace volume name are identical, and the create name is identical when `name` / repo basename are unchanged

#### Scenario: Resource base from repo basename even when name is set
- Given a config with `"name": "My App"` and URL ending in `sample-repo.git`
- When the create name and resource stem are computed
- Then the create name is `my-app` and the resource base / `*-ws` / `${devcontainerId}` stem use `sample-repo`, not `my-app` and not a temp directory name

#### Scenario: Scheme URL userinfo stripped from identity
- Given a git URL `https://token:x-oauth-basic@github.com/org/repo.git`
- When identity, labels, and success JSON are produced
- Then hash material and `devcontainer.git_url` / `gitUrl` MUST equal the normalized form without userinfo (e.g. `https://github.com/org/repo`) and MUST NOT contain the token
- And host `git` MUST still be invoked with the original URL (including userinfo when present)

#### Scenario: SCP-like URL keeps username shape
- Given a git URL `git@github.com:org/repo.git`
- When the URL is normalized for identity
- Then the normalized form retains the `git@host:path` shape (username not stripped as scheme userinfo)

See also: [core.md](../../core.md) **Deterministic identity and labels** for shared sanitize rules and bind-mode identity.

---

### Requirement: Volume-mode workspace mount and labels

On `clone` create, the CLI MUST:

1. **Workspace volume freshness (re-clone) — `clone` only:** If the workspace named volume already exists, `clone` MUST **delete it and create it empty** before mount. MUST NOT reuse a dirty existing workspace volume tree. (Config `type=volume` mounts remain list-then-create/reuse per Named volume reuse policy — only the clone workspace `*-ws` volume is delete-and-create.)
2. **`rebuild` carve-out:** `rebuild` of a volume-mode managed container MUST **reuse** the existing `*-ws` volume tree with its data and MUST NOT delete, replace, or re-populate it; MUST NOT run git re-clone or `git pull` inside it. The freshness rule applies to `clone` only.
3. Mount that volume as the **container workspace folder** (the implicit workspace mount). MUST NOT bind-mount a durable host project directory as the workspace for clone-created containers.
4. **Existing occupant of the create name:** classify per **Create-name occupancy classification**. Same-workspace same-name MUST fail closed (MUST NOT silently reuse, replace, or attach; MUST NOT offer rename-to-duplicate). Foreign occupant MUST follow **Foreign create-name collision offer**. Same-workspace different-name MUST fail with a delete-hint.
5. Set labels on create:

| Label | Requirement |
|-------|-------------|
| `devcontainer.managed` | MUST be `adevcontainer` |
| `devcontainer.git_url` | MUST be the **normalized** git URL (userinfo stripped for `scheme://` forms; stable for inspect/list) |
| `devcontainer.workspace_volume` | MUST equal the workspace volume name |
| `devcontainer.workspace_mode` | MUST be `volume` |
| `devcontainer.local_folder` | MUST be adapted for volume mode: a `volume://…` form **or** empty/synthetic value — MUST NOT require a durable host path that outlives clone temps |
| `devcontainer.config_file` | MUST identify the config file used (absolute-at-resolve and/or repo-relative form suitable for inspect) |
| Config hash label (e.g. `devcontainer.config_hash`) | MUST be set per existing drift/identity policy |
| `devcontainer.workspace_folder` | Container workspace folder |
| `devcontainer.remote_user` | MUST be the **resolved remote connection user** (non-empty). MUST NOT be stamped empty on a successful create (same contract as bind-mode — see [core.md](../../core.md) **Remote connection user resolution** and **Deterministic identity and labels**) |
| `devcontainer.config_volumes` | MUST be set on clone create when the resolved config has one or more `mounts` with `type=volume`: comma-separated list of those volume **source** names. MUST be omitted or empty when there are no config named volumes. `prune` MUST use this label (when present) to remove config named volumes for managed/volume-mode targets without re-resolving host config. |

Additional existing labels MAY be set. Discovery of managed containers for `list` / `start` / extended `stop` MUST filter client-side on `devcontainer.managed=adevcontainer` after machine JSON list (Apple `container` has no label filter API).

#### Scenario: Clone create uses named volume not host bind
- Given a successful resolve for clone
- When the container is created
- Then the workspace mount source is the workspace named volume and is not a host bind of the clone temp directories

#### Scenario: Managed and volume labels present
- Given a container created by clone
- When labels are inspected
- Then `devcontainer.managed` is `adevcontainer`, `devcontainer.workspace_mode` is `volume`, `devcontainer.workspace_volume` matches the volume name, and `devcontainer.git_url` is present (normalized)

#### Scenario: Re-clone deletes and creates a fresh workspace volume
- Given a workspace volume name `adev-{base}-{hash12}-ws` that already exists (e.g. after a prior container-only delete) with residual files
- When the user runs `adevcontainer clone` for the same URL/config identity
- Then the CLI deletes that volume, creates it empty, and mounts the fresh volume (MUST NOT mount the dirty pre-existing tree)

#### Scenario: rebuild reuses the workspace volume instead of replacing it
- Given a volume-mode managed container whose `*-ws` volume exists with data
- When the user runs `adevcontainer rebuild --name <that-name>` (including when the replacement create name differs from the selected name)
- Then the CLI does not delete or replace the volume, mounts the same volume on the new container, and the data remains present (no re-clone)

#### Scenario: Existing managed container name fails closed
- Given a container already exists with the computed clone create name and the same git URL + config identity
- When the user runs `adevcontainer clone` for that identity
- Then the CLI fails with a structured error naming the existing container and MUST NOT create, start, or populate a second instance under that name

#### Scenario: Foreign occupant of the clone create name offers a rename prompt
- Given a container already exists with the computed clone create name but a different git URL or config identity
- When the user runs `adevcontainer clone` on a TTY without `--json`
- Then the CLI follows **Foreign create-name collision offer** and MUST NOT silently reuse or replace that occupant

#### Scenario: config_volumes label records config named volumes
- Given a clone config with a `type=volume` mount whose source is `data-vol`
- When the container is created
- Then labels include `devcontainer.config_volumes=data-vol` (comma-separated if multiple)

---

## REMOVED Requirements

None. The `adev-{base}-{hash12}` create-name scheme and the empty-base `adev-{hash12}` create-name fallback are withdrawn by the modified identity requirements above; they are not standalone removed requirements.
