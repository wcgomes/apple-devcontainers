# Change Spec: align-remote-user-resolution

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Remote connection user resolution

The product MUST resolve a **remote connection user** for every managed create path (`up`, `clone`, `rebuild`) and MUST use that value for connection-oriented consumers (labels, `exec`, lifecycle hook exec, VS Code nameConfig / customizations / postAttach, and success-JSON `remoteUser`).

**Precedence (MUST, first non-empty after trim wins):**

1. Config `remoteUser` when non-empty after trim (local `devcontainer.json`)
2. Else config `containerUser` when non-empty after trim (local)
3. Else image label `devcontainer.metadata` `remoteUser` when non-empty after trim (see **Image metadata users** below)
4. Else image label `devcontainer.metadata` `containerUser` when non-empty after trim
5. Else the **final OCI image `USER`** of the image that will run the workspace container (config base image when Features are absent; **derived** image when Features produce one), obtained from runtime image inspect
6. Else the literal `root`

Local config wins when set: steps 1–2 always beat metadata. Create process user follows **Create process user** below (explicit `containerUser`, else non-root connection user — so metadata `remoteUser` such as `vscode` becomes create `-u` when local `containerUser` is unset).

**Image metadata users (MUST):**

- When present, the image label `devcontainer.metadata` (JSON object or array of fragment objects) MUST contribute `remoteUser` / `containerUser` into the connection-user chain above.
- Across an array of fragments, **last non-empty after trim wins** per field.
- Absence or unparseable metadata MUST be treated as no metadata users (never fails resolution alone).
- On Features paths, metadata MUST be read from the **base** image (derived tags may not carry the base label).

**Inspect failure (MUST NOT invent root at the OCI tier):**

- When steps 1–4 do not yield a user, the product MUST obtain OCI `USER` via image inspect.
- If image inspect **fails** (runtime error, unparseable payload, or missing inspect path) while steps 1–4 are empty, the product MUST fail the create path with a structured error naming image inspect / user resolution — it MUST **not** treat inspect failure as “OCI USER is `root`” and MUST **not** silently fall through to `root` solely because inspect failed.
- When inspect **succeeds** and the image has no usable `USER` (absent, empty, or whitespace-only), the product MUST continue to step 6 (`root`).

**No hardcoded product usernames (MUST):**

- Resolution MUST NOT hardcode editor-oriented names (e.g. `vscode`) or any other fixed username outside the precedence chain above.
- The terminal `root` fallback is only step 4 after a **successful** empty-USER inspect (or after an explicit non-empty config value of `root`).

**Create vs connection (MUST):**

- Create process user is governed by **Create process user** below. Connection user still drives labels/exec/nameConfig/VS Code; when both keys are set, create uses `containerUser` and connection uses `remoteUser`.

#### Scenario: remoteUser wins over containerUser and OCI USER

- Given a config with `remoteUser` `alice`, `containerUser` `bob`, and an image whose OCI `USER` is `carol`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `alice`

#### Scenario: containerUser used when remoteUser unset

- Given a config with no `remoteUser` (or empty), `containerUser` `bob`, and any OCI `USER`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `bob`

#### Scenario: OCI USER used when both config keys unset

- Given a config with neither `remoteUser` nor `containerUser` set (or both empty), and image inspect returns OCI `USER` `node`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `node`

#### Scenario: root only after successful empty OCI USER

- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect **succeeds** with no usable `USER`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `root`

#### Scenario: inspect failure does not become root

- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect **fails**
- When create runs
- Then the command fails with a structured user-resolution / image-inspect error
- And the product MUST NOT stamp `devcontainer.remote_user=root` solely due to that failure
- And no managed container is left created from that failed resolution

#### Scenario: no hardcoded vscode default

- Given a config with neither `remoteUser` nor `containerUser` set, and image inspect succeeds with OCI `USER` `app`
- When remote connection user is resolved
- Then the result is `app` and MUST NOT be replaced by `vscode` or any other hardcoded product username

#### Scenario: metadata remoteUser when config users empty

- Given a config with neither `remoteUser` nor `containerUser` set, image OCI `USER` `root`, and image `devcontainer.metadata` `{"remoteUser":"vscode"}`
- When remote connection user is resolved on create
- Then the resolved remote connection user is `vscode`
- And create MUST include `-u` `vscode` (non-root connection user; Apple attach uses container default user)

#### Scenario: local config wins over metadata remoteUser

- Given a config with `remoteUser` `alice` and image metadata `remoteUser` `vscode`
- When remote connection user is resolved
- Then the result is `alice`

#### Scenario: metadata array last non-empty wins

- Given image `devcontainer.metadata` is an array of fragments with successive `remoteUser` values
- When metadata users are parsed
- Then the last non-empty `remoteUser` fragment wins

---

### Requirement: Create process user

On managed create (`up`, `clone`, `rebuild`), the product MUST set create `-u` as follows (first match wins):

1. When config `containerUser` is non-empty after trim → create MUST include `-u <containerUser>` (post-substitution value).
2. Else when the **resolved remote connection user** is non-empty after trim and is **not** the literal `root` → create MUST include `-u <connectionUser>`.
3. Else create MUST **omit** `-u` (connection user is `root` or empty; image default applies).

Rationale (Apple-first): Apple Remote Containers attach does **not** pass exec `-u`; the integrated terminal uses the container’s default (create) user. nameConfig `remoteUser` alone does not change the terminal user. Applying the non-root connection user at create keeps VS Code terminal aligned with `remoteUser` / metadata `vscode` without requiring local `containerUser`.

Connection/exec/nameConfig/VS Code consumers continue to use the connection-user chain unchanged. When `remoteUser` is `alice` and `containerUser` is `bob`, create is still `-u bob` and connection remains `alice`.

#### Scenario: create -u from remoteUser when containerUser unset

- Given a config with `remoteUser` `alice` and no `containerUser`
- When create argv is built
- Then create MUST include `-u` `alice`
- And the stamped remote connection user for labels/exec remains `alice`

#### Scenario: create -u when containerUser set

- Given a config with `containerUser` `bob` (with or without `remoteUser`)
- When create argv is built
- Then create MUST include `-u` `bob`
- And when `remoteUser` is also `alice`, connection/stamp/exec remain `alice`

#### Scenario: non-root OCI connection user sets create -u

- Given a config with neither `remoteUser` nor `containerUser` set and OCI `USER` `node`
- When create argv is built
- Then create MUST include `-u` `node`
- And `devcontainer.remote_user` is stamped `node`

#### Scenario: connection root omits create -u

- Given neither config user set and successful empty OCI USER (connection resolves to `root`)
- When create argv is built
- Then create MUST omit `-u`
- And `devcontainer.remote_user` is stamped `root`

#### Scenario: metadata vscode sets create -u (Apple terminal)

- Given neither local user key set, OCI `USER` `root`, metadata `remoteUser` `vscode`
- When create argv is built
- Then create MUST include `-u` `vscode`
- And connection/stamp/nameConfig remain `vscode`

---

### Requirement: OCI image USER on image inspect

Runtime image inspect MUST expose the image’s final OCI `USER` when the inspect payload provides it.

- The inspect result MUST carry a user field (name or empty) derived from the machine-readable image inspect JSON.
- Absence of a usable `USER` in a **successful** inspect MUST be represented as empty/absent user — not as a fabricated `root` inside the inspect result.
- Consumers that need a default after empty USER MUST apply the remote connection user chain (step 4 `root`) themselves; inspect MUST NOT pretreat failure or emptiness as `root`.

#### Scenario: inspect exposes OCI USER

- Given a local image whose inspect JSON reports final `USER` `node`
- When the product inspects that image
- Then the inspect result exposes user `node`

#### Scenario: successful inspect with no USER is empty not root

- Given a local image whose inspect JSON has no usable `USER`
- When the product inspects that image successfully
- Then the inspect result’s user is empty/absent
- And the inspect API itself MUST NOT coerce that to `root`

#### Scenario: inspect failure is distinct from empty USER

- Given image inspect fails for a reference
- When the product attempts inspect
- Then the call fails with a structured runtime/inspect error
- And callers MUST NOT interpret that failure as user `root`

---

### Requirement: Features install as root then restore base image USER

When the Features runner generates a derived-image Dockerfile, it MUST:

1. Run each feature install layer as **root** (`USER root` before install `RUN`), unchanged in intent from today.
2. After **all** feature install layers, emit a final instruction that restores the **base image’s** final OCI `USER` as obtained from image inspect of the Features `FROM` base (the config base image before feature layers).
3. When base inspect succeeds and base `USER` is non-empty, the final image default user MUST match that base `USER`.
4. When base inspect succeeds and base `USER` is empty/absent, the Dockerfile MUST restore an equivalent default (no lingering forced `USER root` as the final image user solely because install ran as root) — final default MUST be `root` only when that matches empty-USER / default image semantics after successful inspect.
5. When base image inspect **fails**, Features build MUST fail structured — MUST NOT hardcode a final `USER root` restore solely because inspect failed.
6. Changing this final-`USER` restore semantics MUST bump Features `recipeVersion` so derived tags rebuild.

#### Scenario: Features Dockerfile ends with base USER not root

- Given a base image with OCI `USER` `node` and at least one admitted feature
- When the Features Dockerfile is generated
- Then install layers run as root
- And the Dockerfile’s final user directive restores `node`
- And the Dockerfile MUST NOT end on `USER root` when base `USER` is `node`

#### Scenario: Features restore fails closed on base inspect failure

- Given Features build needs base USER restore and base image inspect fails
- When Features build runs
- Then build fails with a structured error
- And no derived image is produced that silently ends as root solely due to inspect failure

---

## MODIFIED Requirements

### Requirement: Deterministic identity and labels

**Modify** the bind-mode (and volume-mode equivalent) label row for `devcontainer.remote_user`:

| Label | Prior | New |
|-------|--------|-----|
| `devcontainer.remote_user` | “Effective user or empty string” | MUST be the **resolved remote connection user** (non-empty). MUST NOT be stamped empty on a successful create. |

On every successful managed create (`up` bind, `clone` volume, `rebuild` new container), the product MUST stamp `devcontainer.remote_user` to the resolved remote connection user from **Remote connection user resolution**.

Greenfield: existing containers with empty labels are out of scope for automatic repair; `exec` continues to honor whatever is stamped (empty → omit `-u` on exec as today). New creates MUST always stamp non-empty.

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

---

### Requirement: Supported property surface — Env & user / Env user folder

**Modify** the env & user property intent and the **Env user folder** scenario so process user and connection user are not collapsed:

- `remoteUser` — remote connection / exec / attach user when set (feeds resolution chain; also create `-u` when `containerUser` unset and value is non-root).
- `containerUser` — explicit container create process user when set (wins create `-u` over connection user).
- When both are set, create process user is `containerUser` and remote connection user is `remoteUser`.
- When only one is set, that value participates in the chain per **Remote connection user resolution** and **Create process user**.

#### Scenario: Env user folder (connection vs create)

- Given fixture `Tests/Fixtures/env-user.json` (`remoteUser` and `containerUser` both `vscode`)
- When `up` succeeds
- Then container env includes configured `containerEnv`, create uses `-u vscode`, default cwd is `workspaceFolder`, and stamped `devcontainer.remote_user` / success-JSON `remoteUser` are `vscode`

#### Scenario: remoteUser without containerUser sets create -u

- Given a config with only `remoteUser` `alice` (no `containerUser`)
- When `up` succeeds
- Then create includes `-u` `alice`, `devcontainer.remote_user` is `alice`, and `exec` runs as `alice`

---

### Requirement: Up lifecycle success JSON `remoteUser`

**Modify** success JSON field description:

- `remoteUser` — MUST be the **resolved remote connection user** (non-empty after successful create). MUST NOT be empty solely because config omitted both user keys when resolution yielded OCI `USER` or `root`.

The same non-empty resolved value MUST apply to `clone` and `rebuild` success JSON `remoteUser` fields.

#### Scenario: success JSON remoteUser reflects OCI fallback

- Given neither config user key set and OCI `USER` `node`
- When `up` succeeds with `--json`
- Then JSON `remoteUser` is `node`

---

### Requirement: Unified managed selection — `exec`

**Modify** exec user source wording:

- User and workdir MUST come from labels `devcontainer.remote_user` and `devcontainer.workspace_folder` stamped at create.
- When `devcontainer.remote_user` is non-empty, `exec` MUST pass that user to runtime exec.
- Empty label → omit exec `-u` (legacy / pre-change containers only; new creates stamp non-empty).

No change to managed-only selection.

#### Scenario: Exec uses stamped resolved remote connection user

- Given a running managed container stamped `devcontainer.remote_user=alice`
- When the user runs `adevcontainer exec --name <that-name> -- id -un`
- Then exec targets that container with user `alice`

---

### Requirement: VS Code best-effort open — optional nameConfig

**Modify** optional nameConfig policy:

- When the product writes nameConfig, it MUST include `workspaceFolder` and, when the resolved remote connection user is non-empty (always after successful resolution on create paths; on `start` from labels when non-empty), MUST include `remoteUser` set to that resolved connection user (from create result or stamped label — not a hardcoded name).
- nameConfig MUST be written **before** the host `code` launch attempt on `--vscode` paths so attach defaults can observe it prior to open.
- nameConfig write remains soft-fail: write failure MUST NOT fail lifecycle and MUST NOT block the subsequent open attempt.
- Folder-uri open remains the required open path.

#### Scenario: nameConfig written before code launch

- Given `--vscode` on `up` / `start` / `clone` / `rebuild` with open inputs available and nameConfig enabled
- When best-effort open runs
- Then nameConfig is written (or soft-fail warned) **before** host `code` is invoked
- And nameConfig `remoteUser` equals the resolved remote connection user (or stamped label on `start`)

#### Scenario: nameConfig remoteUser matches stamp not hardcoded

- Given a container stamped `devcontainer.remote_user=alice` and `start --vscode`
- When nameConfig is written
- Then `remoteUser` in nameConfig is `alice` and MUST NOT be a hardcoded product username

---

### Requirement: postAttachCommand policy / customizations apply — effective remote user

**Modify** wording that says “effective `remoteUser` when set” / “effective remote user home”:

- postAttach, settings apply, extensions apply, and customization markers MUST execute or target paths as the **resolved remote connection user** (from config resolution on create-path, or stamped/label-aligned user on reuse/`start`), not create-only `containerUser` when `remoteUser` differs.
- When `remoteUser` is `alice` and `containerUser` is `bob`, attach/customization/postAttach MUST use `alice`.

#### Scenario: postAttach runs as remote connection user not containerUser

- Given `remoteUser` `alice`, `containerUser` `bob`, `--vscode`, and successful open
- When postAttach runs
- Then postAttach exec uses user `alice`

#### Scenario: settings apply under remote connection user home

- Given `remoteUser` `alice` and settings apply on create-path
- When settings are merged
- Then the guest Machine settings path is under `alice`’s home, not `bob`’s when `containerUser` is `bob`

---

### Requirement: Derived image build (native arm64; no Rosetta)

**Modify** step 4 (generated Dockerfile) to include final base-USER restore per **Features install as root then restore base image USER**. Install remains as root with `_REMOTE_USER` / `_CONTAINER_USER` env; the Dockerfile MUST NOT leave the derived image’s final default user as root solely because install ran as root when the base image USER was non-root.

`_REMOTE_USER` / `_CONTAINER_USER` install env MUST be derived from config `remoteUser` / `containerUser` without inventing editor usernames; when both unset, install env MUST use the inspected base image USER when non-empty, else `root` — MUST NOT hardcode `vscode`. Callers MUST fail closed on base inspect failure before fabricating install-env users.

#### Scenario: derived image default user matches base after Features

- Given base image USER `node` and a successful Features-derived create
- When the derived image default user is observed
- Then it matches `node` (not forced root)

#### Scenario: Features install env uses base USER when config users empty

- Given config omits both user keys and base image USER is `node`
- When the Features Dockerfile install env is generated
- Then `_REMOTE_USER` and `_CONTAINER_USER` are `node` (not unconditional `root`, not `vscode`)

---

## REMOVED Requirements

None.
