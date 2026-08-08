# Change Spec: clone-in-volume

Delta against realized contract `specs/adevcontainer/spec.md`. Requirements below are **ADDED** unless marked **MODIFIED**. RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Host git prerequisite for clone

`adevcontainer clone` MUST require a usable host `git` executable on `PATH` before any network or filesystem clone work. If `git` is missing or not executable, the CLI MUST fail with a structured error naming the dependency and that host git is required for clone (config-only fetch and HTTPS credential fill). The product MUST NOT bundle git. Full workspace populate MUST use **in-container** git after Features ensure git is available.

#### Scenario: Missing host git fails structured
- Given a host without `git` on `PATH`
- When the user runs `adevcontainer clone <git-url>`
- Then the command fails with a structured error indicating host `git` is required and MUST NOT create a container or volume

---

### Requirement: Clone command surface (URL only)

The CLI MUST provide `adevcontainer clone <git-url>` where `<git-url>` is a single required positional argument identifying a git remote (HTTPS or SSH URL forms accepted by host `git`).

**v1 argument surface:**

- MUST accept exactly the git URL positional.
- MUST NOT accept `--branch`, `--depth`, submodule flags, or PAT/token flags as product options.
- Unknown flags MUST fail closed with a structured error.

Success MUST emit machine-readable JSON on stdout (progress on stderr per existing StatusPrinter rules). Failure MUST be structured (non-zero exit; JSON error shape consistent with other commands when `--json` / machine mode applies per product norms).

#### Scenario: Clone accepts URL positional only
- Given a valid public git URL to a repo with a supported `devcontainer.json`
- When the user runs `adevcontainer clone <git-url>` with no extra flags
- Then the CLI accepts the invocation and proceeds with the clone flow (subject to other requirements)

#### Scenario: Branch flag rejected
- Given any git URL
- When the user runs `adevcontainer clone <git-url> --branch main`
- Then the CLI fails with a structured error (unsupported flag) and MUST NOT create resources

---

### Requirement: Config-only fetch then full resolve for clone

On `clone`, the CLI MUST:

1. Create a temporary directory for config discovery.
2. Perform a **sparse and/or shallow host git clone (or equivalent)** into that temp directory sufficient to obtain the devcontainer configuration files only (not necessarily the full tree).
3. Discover config relative to that temp workspace root in order: (1) `.devcontainer/devcontainer.json`, (2) `.devcontainer.json`. First existing file wins (same policy as Config discovery).
4. If neither config path exists → fail with a structured error listing the paths searched. MUST NOT select a default image or invent config.
5. Resolve the config through the **existing** admission pipeline (JSONC, substitution, supported properties, Features, runArgs allowlist, hostRequirements, unsupported-property policy) with the temp directory as workspace root **for discovery and resolve only**.
6. Proceed to identity, volume create, container create, populate, and hooks only after successful resolve.

`${localWorkspaceFolder}` and related path-shaped substitutions during clone resolve MAY bind to the temp discovery root; implementers MUST document that volume-mode durable identity does not depend on the temp path remaining after clone completes.

**workspaceFolder default and `${localWorkspaceFolderBasename}` (clone resolve) — MUST**

- During clone resolve, the default container `workspaceFolder` (`/workspaces/<basename>` when `workspaceFolder` is omitted) and the substitution `${localWorkspaceFolderBasename}` MUST use the **repository basename derived from the git URL** (same basename source as volume-mode human base when `name` is omitted), **not** the host temp checkout directory name (e.g. not `adev-clone-cfg-<uuid>`).
- An explicit `workspaceFolder` in config still wins after substitution (including forms that embed `${localWorkspaceFolderBasename}`).

#### Scenario: Public happy path discovers nested config
- Given a public repository containing `.devcontainer/devcontainer.json` with a valid `image` (and no forever-rejected properties)
- When the user runs `adevcontainer clone <git-url>` with host git and runtime available (or mocked success)
- Then config is discovered from `.devcontainer/devcontainer.json`, resolve succeeds, and the clone flow continues to create

#### Scenario: Missing config fails without default image
- Given a repository with neither `.devcontainer/devcontainer.json` nor `.devcontainer.json`
- When the user runs `adevcontainer clone <git-url>`
- Then the CLI fails with a structured error listing both candidate paths and MUST NOT create a container, workspace volume, or pull a default image

#### Scenario: Root `.devcontainer.json` fallback
- Given a repository with only `.devcontainer.json` at the root
- When config is discovered for clone
- Then the CLI uses `.devcontainer.json`

#### Scenario: Default workspaceFolder uses git URL repo basename
- Given a clone URL whose repo basename is `my-repo` and a config that omits `workspaceFolder`
- When clone resolve runs against a temp discovery directory named unlike the repo
- Then the resolved container `workspaceFolder` is `/workspaces/my-repo` (not a path based on the temp directory name)

#### Scenario: Explicit workspaceFolder still wins
- Given a config with `"workspaceFolder": "/custom/ws"`
- When clone resolve runs
- Then the resolved container `workspaceFolder` is `/custom/ws`

---

### Requirement: Volume-mode identity (git URL hash and names)

For containers created by `clone`, deterministic identity MUST be derived as follows.

**Hash material (`hash12`)**

- MUST hash **normalized git URL** + **config relative path** (path within the repo, e.g. `.devcontainer/devcontainer.json`).
- MUST NOT use the host temporary directory path as durable hash material (temp paths change per invocation).

**URL normalization (`normalizeGitURL`) — MUST**

- Trim surrounding whitespace.
- Strip trailing `/` and a trailing `.git` suffix (case-insensitive on the suffix); re-strip trailing `/` after `.git` removal.
- For `scheme://` URLs: lowercase the scheme and **MUST strip `userinfo@`** (user, `user:pass`, or token) before the host so embedded credentials never enter hash material, labels, or success JSON.
- SCP-like forms (`git@host:path`) MUST retain the username segment — it is not secret userinfo and is required shape.
- Normalization MUST be deterministic and covered by tests.
- Host `git` invocations MUST still receive the **original** (caller-supplied) URL so credential helpers and embedded tokens continue to work; only identity/labels/JSON use the normalized form.

**Human base**

1. If resolved `name` is present and non-empty after trim → sanitize that value (same DNS-safe sanitize as Deterministic identity and labels).
2. Else → sanitize the **repository basename** derived from the git URL (not a host folder basename).

**Container name**

- Format: `adev-{base}-{hash12}`; empty base → `adev-{hash12}`; full name ≤ 63 characters (same scheme as existing identity).

**Workspace volume name**

- Format: `adev-{base}-{hash12}-ws` (same `base` and `hash12` as the container).
- MUST include container identity material and the `-ws` suffix.
- If the name must be clipped to satisfy runtime length limits, the implementation MUST retain `hash12` and the `-ws` suffix (clip the base / middle as needed).

Apple `container create --name` MUST equal the container id used for later inspect/exec/stop/delete/start, consistent with the base contract.

#### Scenario: Volume name includes container identity
- Given a clone identity with base `myapp` and a computed `hash12`
- When container and workspace volume names are computed
- Then the container name is `adev-myapp-{hash12}` (or ≤ 63-char clipped form per policy) and the workspace volume name is `adev-myapp-{hash12}-ws` (or a clipped form that still contains `{hash12}` and ends with `-ws`)

#### Scenario: Same URL and config path stable identity
- Given the same normalized git URL and config relative path
- When identity is computed on two separate clone invocations (different temp dirs)
- Then `hash12`, container name, and workspace volume name are identical

#### Scenario: Human base from repo basename when name omitted
- Given a config without `name` and URL ending in `sample-repo.git`
- When the container name is computed
- Then the human base is the sanitized repo basename (`sample-repo` or equivalent sanitize result), not a temp directory name

#### Scenario: Scheme URL userinfo stripped from identity
- Given a git URL `https://token:x-oauth-basic@github.com/org/repo.git`
- When identity, labels, and success JSON are produced
- Then hash material and `devcontainer.git_url` / `gitUrl` MUST equal the normalized form without userinfo (e.g. `https://github.com/org/repo`) and MUST NOT contain the token
- And host `git` MUST still be invoked with the original URL (including userinfo when present)

#### Scenario: SCP-like URL keeps username shape
- Given a git URL `git@github.com:org/repo.git`
- When the URL is normalized for identity
- Then the normalized form retains the `git@host:path` shape (username not stripped as scheme userinfo)

---

### Requirement: Volume-mode workspace mount and labels

On `clone` create, the CLI MUST:

1. **Workspace volume freshness (re-clone):** If the workspace named volume already exists, the CLI MUST **delete it and recreate it empty** before mount. MUST NOT reuse a dirty existing workspace volume tree. (Config `type=volume` mounts remain list-then-create/reuse per Named volume reuse policy — only the clone workspace `*-ws` volume is delete-and-recreate.)
2. Mount that volume as the **container workspace folder** (the implicit workspace mount). MUST NOT bind-mount a durable host project directory as the workspace for clone-created containers.
3. **Existing managed container name:** If a container with the computed managed name already exists, `clone` MUST fail with a structured error and MUST NOT silently reuse, replace, or attach to that container. (No automatic delete/recreate of an existing managed container on `clone`.)
4. Set labels on create:

| Label | Requirement |
|-------|-------------|
| `devcontainer.managed` | MUST be `adevcontainer` |
| `devcontainer.git_url` | MUST be the **normalized** git URL (userinfo stripped for `scheme://` forms; stable for inspect/list) |
| `devcontainer.workspace_volume` | MUST equal the workspace volume name |
| `devcontainer.workspace_mode` | MUST be `volume` |
| `devcontainer.local_folder` | MUST be adapted for volume mode: a `volume://…` form **or** empty/synthetic value — MUST NOT require a durable host path that outlives clone temps |
| `devcontainer.config_file` | MUST identify the config file used (absolute-at-resolve and/or repo-relative form suitable for inspect) |
| Config hash label (e.g. `devcontainer.config_hash`) | MUST be set per existing drift/identity policy |
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

#### Scenario: Re-clone deletes and recreates existing workspace volume
- Given a workspace volume name `adev-{base}-{hash12}-ws` that already exists (e.g. after a prior container-only delete) with residual files
- When the user runs `adevcontainer clone` for the same URL/config identity
- Then the CLI deletes that volume, recreates it empty, and mounts the fresh volume (MUST NOT mount the dirty pre-existing tree)

#### Scenario: Existing managed container name fails closed
- Given a container already exists with the computed clone container name
- When the user runs `adevcontainer clone` for that identity
- Then the CLI fails with a structured error naming the existing container and MUST NOT create, start, or populate a second instance under that name

#### Scenario: config_volumes label records config named volumes
- Given a clone config with a `type=volume` mount whose source is `data-vol`
- When the container is created
- Then labels include `devcontainer.config_volumes=data-vol` (comma-separated if multiple)

---

### Requirement: In-container full clone populate (auth by URL scheme) (MODIFIED)

After the container is created and started (and Features have ensured in-container git), `clone` MUST populate the workspace volume with a **full git clone inside the container** into `workspaceFolder` (volume mount), **before** create-path lifecycle hooks.

**Populate steps — MUST**

1. Exec in-container `git clone` of the git URL into the workspace folder (workdir = `workspaceFolder`, as `remoteUser` when set). Implementation MAY clone to a temp path on the volume and move into place when the mount is non-empty (e.g. `lost+found` only).
2. **Verify** populate with `test -e <workspaceFolder>/.git` (or equivalent path-exists). If verification fails, populate MUST fail structured (MUST NOT treat empty volume as success).
3. MUST NOT perform host full clone + tar-pipe populate on the happy path. (Runtime tar-pipe MAY remain as an unused utility.)
4. The product MUST NOT implement explicit Git Credential Manager detection, install, or configuration inside the guest.
5. The product MUST NOT add PAT/token CLI flags as primary UX. Optional env `ADEVCONTAINER_GIT_TOKEN` as escape hatch is allowed.
6. Secrets MUST NEVER appear in success JSON, labels, or StatusPrinter progress lines. Errors MUST redact URL userinfo and credential material.

**Auth by URL scheme — MUST**

| Scheme | Behavior |
|--------|----------|
| **SSH** (`git@host:path`, `ssh://…`) | On volume-mode create, inject `AllowlistedRunArg.ssh` (`container create --ssh`) when host `SSH_AUTH_SOCK` is set and non-empty (if not already in runArgs). If SSH URL and `SSH_AUTH_SOCK` unset/empty → fail structured with hint to start ssh-agent / `ssh-add` / use HTTPS. Day-2 push works while the container retains `--ssh` forward from create. |
| **HTTPS** (`http://`, `https://`) | On the **host**, attempt credentials via `git credential fill` (protocol/host/path from URL) using host env (works with GCM/osxkeychain without product GCM integration). Optional fallbacks: `ADEVCONTAINER_GIT_TOKEN`; if `gh` available and host is github.com, `gh auth token`. When credentials are available, pass them into **one** in-container `git clone` via GIT_ASKPASS / env one-shot (prefer approach that avoids logging secrets; redact errors), then configure in-container `credential.helper store` and `git credential approve` once so day-2 push/pull work without re-prompt. Store MAY persist on volume/home layer. When fill returns nothing, still attempt an anonymous in-container clone (public repos). If that clone fails → structured error hinting to configure git credential on Mac or use SSH URL. |
| **Other** | Fail clear or best-effort passthrough with structured errors on failure. |

**Clone cleanup on failure (after workspace volume / container create) — MUST**

If start, populate, or create-path lifecycle hooks fail after the workspace volume and/or container have been created, `clone` MUST:

1. Delete the workspace container (force as needed), and
2. Delete the workspace volume (`*-ws`),

before returning the structured failure. (Create-path hook runners that already delete the container still require workspace volume deletion on this path.) Temp dirs remain subject to always-clean rules below. Tests MUST assert no successful outcome and no leftover clone container/workspace volume on these failures.

#### Scenario: Populate uses in-container git clone with verify
- Given a resolved clone create with container started and in-container git available
- When populate runs
- Then full `git clone` runs inside the container into the workspace folder, post-clone verify confirms `.git` exists, and host full clone / tar-pipe populate is NOT used

#### Scenario: SSH injects --ssh when agent present
- Given an SSH git URL and host `SSH_AUTH_SOCK` set and non-empty
- When clone creates the container
- Then create argv includes `--ssh` (injected if not already in runArgs)

#### Scenario: SSH without agent fails structured
- Given an SSH git URL and host `SSH_AUTH_SOCK` unset or empty
- When the user runs `adevcontainer clone <ssh-url>`
- Then the CLI fails structured with a hint to start ssh-agent / use HTTPS and MUST NOT create a container or volume

#### Scenario: HTTPS uses host credential fill one-shot
- Given an HTTPS git URL and host `git credential fill` returns username/password
- When populate runs
- Then credentials are passed into one in-container clone without appearing in success JSON/labels, and after clone the guest configures `credential.helper store` for day-2

#### Scenario: HTTPS public works without host credentials
- Given an HTTPS git URL to a public repository and host credential fill returns nothing
- When clone populate runs
- Then in-container anonymous clone may succeed and clone reports success

#### Scenario: HTTPS private without credentials fails structured
- Given an HTTPS git URL and host credential fill returns nothing and in-container clone fails (auth)
- When clone populate runs
- Then clone fails structured hinting to configure host git credentials or use SSH; MUST NOT require a PAT CLI flag

#### Scenario: Populate verify fails when .git missing
- Given in-container clone reports success but `<workspaceFolder>/.git` is missing
- When populate verification runs
- Then clone fails structured (populate failed) and MUST NOT report success

#### Scenario: Populate failure deletes container and workspace volume
- Given the container and workspace volume were created and populate then fails
- When clone returns failure
- Then the managed container is deleted and the workspace `*-ws` volume is deleted

#### Scenario: No GCM-in-guest product integration
- Given any clone URL
- When clone runs
- Then the product does not install/detect GCM inside the container and does not mount host `~/.git-credentials`

---

### Requirement: Clone lifecycle hooks and temp cleanup

**Lifecycle (clone fresh create)**

After successful populate, `clone` MUST run create-path lifecycle hooks with the **same matrix as `up` fresh create**:

`onCreateCommand` → `updateContentCommand` → `postCreateCommand` → `postStartCommand`

- Hooks run via AppleContainerRuntime exec (not baked into the image).
- Non-zero exit of any create-path hook MUST fail `clone` and MUST delete the container **and** the workspace volume before returning failure (clone cleanup; container delete-on-fail aligns with `up` fresh create, plus volume-mode `*-ws` removal).
- `postAttachCommand` remains admitted and not executed (same as `up`).

**Temp cleanup**

- Config-fetch temp directories MUST be deleted on **both** success and failure (use `defer` or equivalent). (No host full-clone staging temp on the happy path.)
- If temp deletion fails, the CLI MUST print a **warning on stderr** only and MUST NOT change a successful outcome to failure solely due to cleanup failure.

#### Scenario: Create-path hooks run after populate
- Given a config with `postCreateCommand` that exits 0
- When clone completes create, start, and populate successfully
- Then create-path hooks run in order and clone reports success

#### Scenario: Temp dirs always cleaned up
- Given clone runs to success or to a mid-flow structured failure after temps were created
- When the command returns
- Then config-fetch temp directories are removed (or a stderr warning is emitted if removal failed)

#### Scenario: Hook failure deletes container and workspace volume
- Given populate succeeded and `postCreateCommand` exits non-zero
- When clone runs
- Then clone fails structured, the workspace container is deleted, the workspace `*-ws` volume is deleted, and temps are cleaned up

---

### Requirement: Clone success JSON

On successful `clone`, stdout machine-readable JSON MUST include at least:

| Field | Meaning |
|-------|---------|
| `outcome` | Success indicator consistent with `up` (e.g. `"success"`) |
| `containerId` | Runtime container id |
| `remoteUser` | Effective remote/container user (may be empty/default if unset) |
| `remoteWorkspaceFolder` | Absolute workspace path inside the container |
| `gitUrl` | Normalized git URL used for identity/labels (userinfo stripped for `scheme://`) |
| `workspaceVolume` | Workspace named volume name |

Additional fields (e.g. `containerName`) MAY be included. Progress remains on stderr; `ADEVCONTAINER_QUIET=1` silences progress status as today.

#### Scenario: Success JSON includes gitUrl and workspaceVolume
- Given a successful clone
- When the machine-readable result is parsed
- Then it includes `outcome`, `containerId`, `remoteUser`, `remoteWorkspaceFolder`, `gitUrl`, and `workspaceVolume`

---

### Requirement: List managed containers

The CLI MUST provide `adevcontainer list` that:

1. Obtains the container list via AppleContainerRuntime machine JSON.
2. **Filters client-side** to containers whose labels include `devcontainer.managed=adevcontainer`.
3. Default output: human-readable **table** (at least name/id and state; SHOULD include git URL and/or workspace mode when labels present).
4. `--json`: machine-readable listing of the same managed set (array or documented object envelope).

Containers without the managed label MUST NOT appear in `list`. Both `up` (bind) and `clone` (volume) create paths MUST stamp `devcontainer.managed=adevcontainer` so both appear. Historical unlabeled containers (if any) remain invisible to `list` / day-2 selection.

#### Scenario: List shows only managed containers
- Given one managed (clone or up) container and one unlabeled container
- When the user runs `adevcontainer list`
- Then only the managed container appears in the default table

#### Scenario: List includes bind-mode up container
- Given a container created by `up` with managed bind labels
- When the user runs `adevcontainer list`
- Then that container appears in the managed set

#### Scenario: List JSON is machine-readable
- Given at least one managed container
- When the user runs `adevcontainer list --json`
- Then stdout parses as JSON describing the managed set and does not include progress lines

---

### Requirement: Start managed container

The CLI MUST provide `adevcontainer start` that starts a **stopped** managed container.

**Selection**

- `--name <container-name-or-id>` selects explicitly.
- If no name is provided and exactly one managed container is eligible, the CLI MAY select it automatically.
- If multiple managed containers exist and none is selected, and stdin is an interactive TTY, the CLI MUST present an interactive picker.
- If multiple exist and stdin is not a TTY (non-interactive), the CLI MUST fail with a structured error requesting `--name`.
- Selection set MUST be managed containers only (`devcontainer.managed=adevcontainer`).

**Runtime behavior**

- If the selected container is stopped → start it via AppleContainerRuntime.
- If already running → success **no-op** (MUST NOT error solely because it was already running).
- MUST NOT re-clone the git URL.
- MUST NOT run the full `up` or `clone` create path (no Features rebuild, no volume re-populate, no config re-resolve required for start).

**Lifecycle hooks on start (locked split)**

| Workspace origin | `start` / start-stopped hooks |
|------------------|-------------------------------|
| **Volume-mode / clone-origin** (`devcontainer.workspace_mode=volume`) | **Runtime start only** — MUST NOT run lifecycle hooks (`postStartCommand` included) |
| **Bind-mode** via `up` | `up` start-stopped (same container, via `up` path) runs **`postStartCommand` only** per base contract. Bare `adevcontainer start` on a bind managed container is runtime start only (no config re-resolve / no hooks) in v1. |

Rationale: clone config may have lived only in a temp directory that is gone after clone; bare `start` MUST remain reliable without recovering full config from disk. Labels remain available for identity/list; hook re-execution on bare `start` is out of scope for v1 (use `up` for bind postStart).

#### Scenario: Start stopped managed container
- Given a managed container created by clone that is stopped
- When the user runs `adevcontainer start --name <that-name>`
- Then the container is running and the command succeeds without re-cloning

#### Scenario: Start already running is no-op success
- Given a managed container that is already running
- When the user runs `adevcontainer start --name <that-name>`
- Then the command succeeds and does not recreate the container

#### Scenario: Start interactive picker when multiple
- Given two stopped managed containers and an interactive TTY stdin
- When the user runs `adevcontainer start` without `--name`
- Then the CLI presents an interactive selection UI and starts the chosen container

#### Scenario: Volume-mode start runs no hooks
- Given a volume-mode managed container with labels from clone and a config that had `postStartCommand` at create time
- When the user runs `adevcontainer start --name <that-name>` on a stopped container
- Then the container starts and **no** lifecycle hooks are executed on this path

---

### Requirement: Clone does not replace up bind workspaces

`adevcontainer up` MUST continue to use **host workspace bind mounts** for `-w` / current-directory workspaces per the base contract. This change MUST NOT convert `up` to volume mode. Volume-mode workspaces are created via `clone` (v1).

#### Scenario: Up still bind-mounts host workspace
- Given a local directory with `devcontainer.json`
- When the user runs `adevcontainer up -w <dir>`
- Then the workspace mount remains a host bind (not a clone workspace volume) per base `up` requirements

---

### Requirement: Clone auto-injects git Feature when missing

On `adevcontainer clone` only, after config resolve and **before** the Features gate, the CLI MUST ensure in-container git is available via Features:

1. If no admitted feature has `FeatureRef.featureId == "git"` **and** none has id `"common-utils"` (common-utils often ships git) → append `AdmittedFeature(ref: "ghcr.io/devcontainers/features/git:1", options: empty)`.
2. If `git` or `common-utils` is already present (any registry/tag or local path whose feature id matches) → MUST NOT double-add.
3. The mutated features list is what FeaturesRunner sees. If the list was empty before inject, clone MUST enter the Features path (pull base, build/reuse derived image, etc.).
4. `effectiveConfig.features` and the config hash after merge MUST include the injected feature when added.
5. Progress on stderr MUST report e.g. `==> Ensuring git feature for volume workspace` when injecting (StatusPrinter).
6. Prefer a small helper (e.g. `FeatureGitEnsure.ensurePresent`) under Features/.

**MUST NOT** apply this inject on `up` bind-mode. Forever-rejected docker-* Features policy is unchanged. The git feature is the official OCI feature — not a docker-* id.

Rationale: volume-mode workspaces need git inside the container for **full clone populate** and day-to-day work; probing the base image is heavy without a one-shot run API, and Feature install is idempotent enough when the base already has git.

#### Scenario: Empty features injects git:1
- Given a clone config with no `features` (or empty features object)
- When clone resolves and prepares Features
- Then the admitted features list includes `ghcr.io/devcontainers/features/git:1` and FeaturesRunner runs for that list

#### Scenario: Existing git feature not duplicated
- Given a clone config that already admits a feature whose id is `git`
- When clone prepares Features
- Then no second git feature is appended

#### Scenario: common-utils covers git
- Given a clone config that already admits a feature whose id is `common-utils`
- When clone prepares Features
- Then git:1 is not injected

#### Scenario: Up does not auto-inject git
- Given a bind-mode `up` config with no features
- When the user runs `adevcontainer up`
- Then FeaturesRunner is not entered solely to inject git (no clone-only git ensure on `up`)

---

### Requirement: Clone applies host-resolved git author identity locally

On `adevcontainer clone`, after the host sparse/shallow **config** fetch succeeds, the CLI MUST resolve git author identity from that config work tree via host git:

- `git -C <configTemp> config --get user.name`
- `git -C <configTemp> config --get user.email`

Empty output or non-zero exit for a key MUST be treated as missing for that field (not fatal). Resolution MUST use the host git process boundary (so `includeIf` by remote URL and other host git config apply). The product MUST NOT invent fake defaults (e.g. no synthetic e2e identity).

Optional env overrides (when set and non-empty after trim) MUST win per field over resolved values:

- `ADEVCONTAINER_GIT_AUTHOR_NAME`
- `ADEVCONTAINER_GIT_AUTHOR_EMAIL`

**Before** Features build / image pull / container create, after env overrides are applied, the CLI MUST decide the author identity used later for local config:

- When **both** env overrides are set non-empty → use that identity with **no** interactive prompt (even if stdin is a TTY).
- When stdin is a **TTY** and env did not fully supply both fields:
  - If both name and email are resolved → print them on stderr and prompt `Use this identity? [Y/n]:`. Empty / `Y` / `y` keeps; `n` / `N` (or other non-affirmative) prompts for `user.name:` and `user.email:` (both required non-empty; empty → structured failure, no Features/create).
  - If either field is missing → print that identity was not found and prompt for both fields (same required/fail rules). Interactive path MUST NOT proceed with incomplete identity.
- When stdin is **not** a TTY (CI / non-interactive): no prompt; use resolved/env identity silently when complete; when incomplete, continue without hanging (warn path below).

Prompts MUST go to stderr so success JSON on stdout stays clean.

After **successful** in-container full clone and `.git` verify:

- If **both** name and email are non-empty after trim (chosen identity) → the CLI MUST set **local** repo config inside the container (same user as clone when possible):
  - `git -C <workspaceFolder> config --local user.name '…'`
  - `git -C <workspaceFolder> config --local user.email '…'`
- If either is missing (non-interactive incomplete only) → the CLI MUST NOT set a partial identity, and MUST emit a single StatusPrinter warning, e.g. that `git user.name/email` was not resolved and should be configured before first commit (host `includeIf`/global or `git config` in container).

This requirement does **not** change `up` bind-path identity behavior.

#### Scenario: Host-resolved author applied as local config
- Given host git resolves both `user.name` and `user.email` from the config-fetch work tree (e.g. via global or `includeIf` matching the remote)
- When `adevcontainer clone` completes in-container populate successfully
- Then the workspace clone has local `user.name` and `user.email` set to those values

#### Scenario: Missing author field warns and skips local config
- Given host git resolves `user.name` but not `user.email` (or neither) and stdin is not a TTY
- When `adevcontainer clone` completes populate successfully
- Then no partial local author config is written and a single warning is emitted on stderr

#### Scenario: No invented identity
- Given no resolvable host author identity and no author env overrides
- When clone succeeds (non-interactive)
- Then the product does not write a synthetic default name/email into the container repo

#### Scenario: Env author overrides win
- Given resolved host identity and both `ADEVCONTAINER_GIT_AUTHOR_NAME` and `ADEVCONTAINER_GIT_AUTHOR_EMAIL` set
- When clone applies local author config
- Then the local values match the env overrides and no identity prompt is shown even on a TTY

#### Scenario: Interactive TTY confirms resolved identity
- Given both name and email resolved, stdin is a TTY, and author env overrides are not both set
- When the user accepts the confirm prompt (empty or Y)
- Then Features/create proceed and local config uses the resolved identity

#### Scenario: Interactive TTY declines and enters custom identity
- Given both name and email resolved, stdin is a TTY
- When the user declines and enters a non-empty name and email
- Then local config uses the entered values (not the originally resolved ones)

#### Scenario: Interactive incomplete identity collects before Features
- Given missing name or email, stdin is a TTY
- When the user supplies both fields
- Then Features/create run only after collection and local config uses the entered values

---

## MODIFIED Requirements

### Requirement: Unified managed selection for day-2 commands (MODIFIED)

Day-2 / lifecycle commands share **one** selection model. Only `up` accepts `-w` / `--workspace`.

| Command | Selection |
|---------|-----------|
| `up` | `-w` / `--workspace` (default cwd) — bind-mode create/start/reuse |
| `exec`, `stop`, `delete`, `prune`, `inspect`, `start` | `ManagedContainers.resolveSelection(name:)` only — `--name` and/or interactive picker over `devcontainer.managed=adevcontainer` |
| `clone`, `list`, `doctor` | no `-w` (unchanged) |

If the user passes `-w` / `--workspace` on any non-`up` command, the CLI MUST fail with a structured **usage** error whose message includes that `-w is only valid for up` (clearer than silently ignoring).

**`exec`:** MUST resolve managed only (no ConfigResolver / host workspace path branch). User and workdir MUST come from labels `devcontainer.remote_user` and `devcontainer.workspace_folder` stamped at `up`/`clone` create (empty label → omit).

**`inspect`:** MUST resolve managed only. Payload fields from runtime + labels:

| Field | Source |
|-------|--------|
| `remoteUser` | label `devcontainer.remote_user` |
| `remoteWorkspaceFolder` | label `devcontainer.workspace_folder` |
| `configPath` | label `devcontainer.config_file` |
| `workspacePath` | label `devcontainer.local_folder` |
| `configHash` | label `devcontainer.config_hash` |
| `portsAttributes` | `{}` in v1 (not stored on labels) |

**`stop` / `delete`:** MUST NOT accept a workspace path parameter. Selection is `--name` / picker only. Already-stopped stop is success no-op. `delete` remains **container only** (no workspace volume / config volumes / images).

#### Scenario: Exec managed by name (bind or volume)
- Given a running managed container (from `up` or `clone`) with workspace_folder/remote_user labels
- When the user runs `adevcontainer exec --name <that-name> -- echo ok`
- Then exec targets that container id with labeled user/workdir

#### Scenario: -w on exec is usage error
- Given any args including `-w <path>` on `exec`
- When the user runs the command
- Then the CLI fails usage with a message that `-w is only valid for up`

#### Scenario: Stop by name for managed container
- Given a running managed container from clone or up
- When the user runs `adevcontainer stop --name <that-name>`
- Then the container is stopped

#### Scenario: Stop interactive when multiple
- Given two running managed containers, interactive TTY, no `--name`
- When the user runs `adevcontainer stop`
- Then the CLI presents an interactive picker and stops the selected container

#### Scenario: Delete does not remove workspace volume
- Given a volume-mode container and its `*-ws` volume
- When the user runs `adevcontainer delete` for that container
- Then the container is gone and the workspace volume still exists

#### Scenario: Inspect from labels
- Given a managed container with bind or volume day-2 labels
- When the user runs `adevcontainer inspect --name <that-name>`
- Then payload remoteUser/remoteWorkspaceFolder/configPath/workspacePath/configHash match labels and portsAttributes is empty

---

### Requirement: Prune command (MODIFIED)

Extends base **Prune command**.

`adevcontainer prune` MUST remove:

| Resource | Included? |
|----------|-----------|
| Workspace container | Yes |
| Named volumes from config `mounts` (`type=volume`) via `devcontainer.config_volumes` label | Yes |
| Config `image` reference (from runtime inspect) | Yes |
| **Workspace volume for volume-mode** (`devcontainer.workspace_volume` / deterministic `*-ws` name) | **Yes — ADDED** |
| Derived Features tags | No (unless equal to config `image`) |
| Bind-mount host paths | No |
| Global volume/image prune | No |

Identity resolution for prune MUST be managed-only (`--name` / picker), same as stop/delete/exec/inspect. Config named volumes MUST be taken from the `devcontainer.config_volumes` label when present. Missing `workspace_volume` label (bind-mode) means no workspace volume delete. Missing resources are skipped. Exit non-zero only if deleting an **existing** resource fails.

#### Scenario: Prune removes volume-mode workspace volume
- Given a volume-mode managed container with workspace volume `adev-{base}-{hash12}-ws` and optional config named volumes
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container is gone, config named volumes are removed, the config image reference is removed per base policy, **and** the workspace volume `*-ws` is removed

#### Scenario: Prune bind-mode uses config_volumes label
- Given a bind-mode managed container with `config_volumes=vol-a,vol-b` and no workspace_volume label
- When the user runs `adevcontainer prune --name <that-name>`
- Then the container and labeled config volumes are removed; no `*-ws` volume delete is attempted solely for bind mode

#### Scenario: Prune still skips binds and global prune
- Given bind mounts in a bind-mode config
- When the user runs `adevcontainer prune` targeting that container
- Then host bind paths remain and no global volume/image prune is invoked

---

### Requirement: Deterministic identity and labels (MODIFIED — bind + volume)

Extends base **Deterministic identity and labels**.

**Bind-mode (`up`) identity** MUST remain: `hash12` from workspace path + config path. On create, labels MUST include:

| Label | Requirement |
|-------|-------------|
| `devcontainer.managed` | MUST be `adevcontainer` |
| `devcontainer.workspace_mode` | MUST be `bind` |
| `devcontainer.local_folder` | Absolute host workspace path |
| `devcontainer.config_file` | Config path used |
| `devcontainer.config_hash` | Per existing drift/identity policy |
| `devcontainer.workspace_folder` | Container workspace folder |
| `devcontainer.remote_user` | Effective user or empty string |
| `devcontainer.config_volumes` | Comma-separated config `type=volume` sources when any; omit/empty otherwise |
| `devcontainer.git_url` / `devcontainer.workspace_volume` | MUST NOT be set (or empty; prune ignores missing ws vol) |

**Volume-mode (`clone`) identity** MUST use the ADDED volume-mode identity and labels requirements (git URL + config relative path; managed/volume labels; adapted `local_folder`). The two modes MUST NOT collide solely because a temp path string matches a host workspace path.

#### Scenario: Bind and volume modes distinct hash inputs
- Given a bind-mode up on host path `/Projects/foo` and a clone of a git URL whose repo basename is also `foo`
- When identities are computed
- Then the hash inputs differ (path+config vs git URL+config relpath) so container names are not required to match and MUST follow each mode’s rules

#### Scenario: Up create stamps managed bind labels
- Given a successful `up` create
- When labels are inspected
- Then `devcontainer.managed=adevcontainer`, `workspace_mode=bind`, local_folder/config_file/config_hash/workspace_folder/remote_user are set, and git_url/workspace_volume are absent

---

## REMOVED Requirements

(none)

---

## Non-goals (normative exclusions)

The following are **out of scope** for this change and MUST NOT be required for v1 conformance:

- `--branch`, `--depth`, or submodule product flags on `clone`
- Explicit Git Credential Manager **detection, install, or product integration** (host `git credential fill` / existing helpers are in scope; GCM-in-guest is not)
- PAT/token **CLI flags** as primary UX (optional env `ADEVCONTAINER_GIT_TOKEN` escape hatch allowed)
- Browser/device-code re-auth product flow
- Mounting host `~/.git-credentials` / host home into the container
- Default image or scaffold when `devcontainer.json` is missing
- Host↔volume live file sync after initial populate
- Docker Compose / multi-service clone
- Command aliases `play` / `run` for this flow
- Running lifecycle hooks on `start` for volume-mode containers without host workspace

**In scope for populate/day-2 auth (not non-goals):** in-container full clone; SSH agent forward via Apple `container create --ssh` when `SSH_AUTH_SOCK` is set; host HTTPS credential fill one-shot into guest clone; guest `credential.helper store` after HTTPS clone for day-2.

(End of file)
