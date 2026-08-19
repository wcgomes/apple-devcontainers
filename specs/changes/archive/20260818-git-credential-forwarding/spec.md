# Change Spec: git-credential-forwarding

Status: Archived. Branch: `patch/git-credential-forwarding`. Applies to: all releases.

> **Amendment 1 (2026-08-18):** username-agnostic container-side credential helper — decision B. The container-side seeding mechanism changes from configuring `credential.helper store` to writing a POSIX-sh credential helper (get/store/erase) into the container and appending it via `git config --global --add credential.helper <absolute-path>`; the ADDED requirement text below is amended accordingly, scenarios S15–S18 are added, and clone's own store+approve mechanism is unchanged.

## ADDED Requirements

Merge target: [specs/core.md](../../../core.md).

### Requirement: Git credential store seeded on create paths

On the create paths — `up` fresh create (bind mode) and `rebuild` replacement create (bind and volume mode) — the CLI MUST seed the resolved remote connection user's git credential store in the container BEFORE any create-path lifecycle hook (onCreateCommand, updateContentCommand, postCreateCommand, postStartCommand) runs. Seeding MUST run after the create-path ownership steps.

Seeding MUST write a POSIX-sh credential helper script to the connection user's home directory in the container (e.g. `$HOME/.adevcontainer/git-credential-adev`) with mode 0700, owned by the connection user. Seeding MUST configure the helper at `--global` scope via `git config --global --add credential.helper <absolute-path>`; the configuration MUST append and MUST NOT replace pre-existing credential helpers. Seeding MUST add one credential entry per unique (protocol, host, username) triple via `git credential approve`, which routes through the configured helper whose store mode persists the entry. Entries MUST NOT include a path component, so sibling repositories on the same host are covered without knowing their paths. Matching uses the URL scheme (protocol), host, and username; SSH remotes MUST NOT be seeded.

The helper MUST implement `get`, `store`, and `erase`. On `get`, the helper MUST match the persisted store by (protocol, host) IGNORING the queried username, and MUST return the queried username (or the stored username when the query carries none) together with the stored password; when no entry matches, the helper MUST exit 0 with no output so git falls through to remaining helpers, askpass, or prompt. On `store`, the helper MUST persist the entry, deduping by (protocol, host, username), to its own store file (e.g. `$HOME/.adevcontainer/git-credentials`) with mode 0600, owned by the connection user; the helper MAY use git's store file format with percent-encoding or its own simple line format, and persisted values MUST round-trip raw username and password values (including `@` and `:` characters) without corruption. `erase` MUST be a no-op. Secrets MUST NOT be echoed to stdout or stderr outside the credential protocol and MUST NOT appear in argv.

Credentials MUST be acquired on the HOST through the shared acquisition contract declared by **In-container full clone populate (auth by URL scheme)** ([specs/clone.md](../../../clone.md)): `git credential fill` (protocol/host/path from URL) with `GIT_TERMINAL_PROMPT=0`, optional `ADEVCONTAINER_GIT_TOKEN`, and the `gh auth token` fallback — the existing `HostGitCredential.fillHTTPS` path. When fill returns nil for a URL, the CLI MUST skip that URL silently.

Remote discovery MUST be:

- Bind mode (`up` fresh create, `rebuild` bind): the unique fetch remote URLs of the host workspace via `git -C <hostWorkspace> remote -v`.
- Rebuild volume mode: the stamped `devcontainer.git_url` label of the rebuilt container; a missing or empty label MUST skip seeding silently.

Silent skip — no warning and no failure — MUST apply when host git is missing, when the host workspace is not a git repository or has no remotes, or when fill returns nil. `up` MUST NOT gain a host-git prerequisite.

Seeding failures (for example missing in-container git or an exec failure) MUST soft-fail: a warning on stderr and the create path continues. Seeding MUST NOT delete the container and MUST NOT enter bring-up recovery. Hook failure remains the hook's own failure under existing create-path policy.

Secrets MUST NEVER appear in success JSON, labels, StatusPrinter progress lines, or logged errors; errors MUST redact URL userinfo and credential material (same redaction as the clone flow).

Non-create paths MUST NOT seed: `up` reuse of a running matching container, `up` start-stopped, and bare `start` MUST NOT run seeding.

`clone` is covered-by-design: the product MUST NOT add a second seeding mechanism on `clone`; clone's populate already configures `credential.helper store` + approve before hooks, and regression coverage MUST prove the store outcome is delivered without a seeding call.

#### Scenario: up bind fresh create seeds the store before hooks

- Given a bind-mode `up` fresh create whose host workspace has an HTTPS fetch remote `https://dev.azure.com/plantsuite/PlantSuite/_git/GitOps` and host `git credential fill` returns credentials
- When the create path runs after start and before create-path hooks
- Then the CLI acquires credentials on the host and runs an in-container exec as the connection user that writes the credential helper script, configures `credential.helper --add` with its absolute path at `--global` scope, and approves an entry for (https, dev.azure.com, plantsuite) BEFORE the first create-path hook exec

> Note (Amendment 1, 2026-08-18): wording updated from `credential.helper store` (`--global`) to the username-agnostic helper mechanism; scenario semantics unchanged.

#### Scenario: sibling repositories on the same host are covered

- Given the same bind-mode `up` and a workspace whose remotes include `https://dev.azure.com/plantsuite/PlantSuite/_git/GitOps` and `https://dev.azure.com/plantsuite/PlantSuite/_git/Other`
- When seeding runs
- Then one approve entry per unique (protocol, host, username) is applied and the entries contain no path component

#### Scenario: duplicate remote lines dedupe to one entry

- Given `git -C <hostWorkspace> remote -v` lists the same fetch URL more than once
- When seeding runs
- Then only one approve entry per (protocol, host, username) is applied

#### Scenario: no host credentials skip silently

- Given a public HTTPS remote and host credential fill returns nothing
- When seeding runs
- Then the CLI skips silently (no warning, no failure) and the create path continues

#### Scenario: workspace without a git repo or remotes skips silently

- Given a bind workspace that is not a git repository, or a git repository with no remotes
- When `up` fresh create runs
- Then no seeding exec runs and `up` succeeds

#### Scenario: missing host git skips silently

- Given host git is not installed
- When bind-mode `up` fresh create runs
- Then no seeding runs, no warning is required, and `up` succeeds without a host-git prerequisite

#### Scenario: rebuild bind seeds from host remotes

- Given a bind-mode `rebuild` replacement create whose host workspace has an HTTPS remote and host fill returns credentials
- When the rebuild create path runs after start and before create-path hooks
- Then seeding runs before the first create-path hook exec and the rebuild succeeds

#### Scenario: rebuild volume seeds from the stamped git URL

- Given a volume-mode `rebuild` of a managed container whose `devcontainer.git_url` label is `https://github.com/org/repo`
- When the rebuild create path runs (no host workspace remote enumeration)
- Then seeding acquires credentials for that URL and approves an entry before the first create-path hook exec

#### Scenario: rebuild volume without a stamped git URL skips silently

- Given a volume-mode rebuild whose stamped `devcontainer.git_url` label is missing or empty
- When the rebuild create path runs
- Then no seeding runs and the rebuild succeeds

#### Scenario: seeding failure soft-fails

- Given a create path whose seeding exec fails (for example in-container git is missing or the exec errors)
- When seeding runs
- Then stderr carries a warning, the create path continues through hooks and succeeds absent other failures, the container is NOT deleted, and bring-up recovery is NOT entered

#### Scenario: non-create paths never seed

- Given a matching running bind-mode container, a stopped bind-mode container, or a bare `start` target
- When `up` reuses the running container, `up` starts the stopped one, or `start` runs
- Then no seeding exec runs

#### Scenario: secrets are redacted on the seeding error path

- Given host fill returned username/password for a remote and the seeding exec fails
- When the warning or error is emitted
- Then the warning or error contains no credential material and no URL userinfo

#### Scenario: SSH remotes are not seeded

- Given a bind workspace whose remotes are SSH URLs (`git@host:path`)
- When `up` fresh create runs
- Then no seeding exec runs

#### Scenario: seeding runs as the resolved connection user

- Given a create path whose resolved connection user is `alice` (non-root) or `root`
- When the seeding exec runs
- Then the exec runs as that user and the store lands in that user's home directory

#### Scenario: S15: username-agnostic get serves URL-forced usernames

- Given a seeded store entry for (https, dev.azure.com, X) and a create-path hook whose URL forces username Y (X ≠ Y) on the same protocol and host
- When the hook's git performs credential lookup in the non-interactive hook environment
- Then the helper's get returns the stored password with the QUERIED username Y and the hook's git authenticates

#### Scenario: S16: unseeded hosts receive no credentials

- Given a seeded store containing entries only for one (protocol, host, username) triple
- When git queries the helper for a host absent from the store
- Then the helper exits 0 with no output, no credentials are returned, and git falls through to remaining helpers, askpass, or prompt

#### Scenario: S17: helper and store files are private and secrets stay out of argv and logs

- Given a create path that seeded the helper
- When seeding completes and the hook environment runs
- Then the helper script (0700) and the store file (0600) are owned by the connection user, are not world-readable, and no password material appears in argv, success JSON, labels, progress lines, or logged errors

#### Scenario: S18: pre-existing global credential helpers are preserved

- Given a container whose global git config already configures one or more credential helpers
- When seeding appends its helper via `git config --global --add credential.helper <absolute-path>`
- Then the pre-existing helpers remain configured and are consulted before the seeded helper

## MODIFIED Requirements

Merge target: [specs/clone.md](../../../clone.md).

### Requirement: In-container full clone populate (auth by URL scheme)

After the container is created and started (and Features have ensured in-container git), `clone` MUST populate the workspace volume with a **full git clone inside the container** into `workspaceFolder` (volume mount), **before** create-path lifecycle hooks.

**Populate steps — MUST**

1. Exec in-container `git clone` of the git URL into the workspace folder (workdir = `workspaceFolder`, as the **resolved remote connection user** when stamped/non-empty). Implementation MAY clone to a temp path on the volume and move into place when the mount is non-empty (e.g. `lost+found` only).
2. **Verify** populate with `test -e <workspaceFolder>/.git` (or equivalent path-exists). If verification fails, populate MUST fail structured (MUST NOT treat empty volume as success).
3. MUST NOT perform host full clone + tar-pipe populate on the happy path. (Runtime tar-pipe MAY remain as an unused utility.)
4. The product MUST NOT implement explicit Git Credential Manager detection, install, or configuration inside the guest.
5. The product MUST NOT add PAT/token CLI flags as primary UX. Optional env `ADEVCONTAINER_GIT_TOKEN` as escape hatch is allowed.
6. Secrets MUST NEVER appear in success JSON, labels, or StatusPrinter progress lines. Errors MUST redact URL userinfo and credential material.

**Auth by URL scheme — MUST**

| Scheme | Behavior |
|--------|----------|
| **SSH** (`git@host:path`, `ssh://…`) | On volume-mode create, inject `AllowlistedRunArg.ssh` (`container create --ssh`) when host `SSH_AUTH_SOCK` is set and non-empty (if not already in runArgs). If SSH URL and `SSH_AUTH_SOCK` unset/empty → fail structured with hint to start ssh-agent / `ssh-add` / use HTTPS. Later push works while the container retains `--ssh` forward from create. |
| **HTTPS** (`http://`, `https://`) | On the **host**, attempt credentials via `git credential fill` (protocol/host/path from URL) using host env (works with GCM/osxkeychain without product GCM integration). Optional fallbacks: `ADEVCONTAINER_GIT_TOKEN`; if `gh` available and host is github.com, `gh auth token`. When credentials are available, pass them into **one** in-container `git clone` via GIT_ASKPASS / env one-shot (prefer approach that avoids logging secrets; redact errors), then configure in-container `credential.helper store` and `git credential approve` once so later push/pull work without re-prompt. Store MAY persist on volume/home layer. When fill returns nothing, still attempt an anonymous in-container clone (public repos). If that clone fails → structured error hinting to configure git credential on Mac or use SSH URL. The host-side acquisition (fill with `GIT_TERMINAL_PROMPT=0`, `ADEVCONTAINER_GIT_TOKEN`, `gh auth token` fallback) is the **shared acquisition contract**; clone's in-container store+approve pattern is one use site (seeding uses its own helper — Amendment 1) — see **Shared acquisition contract** below. |
| **Other** | Fail clear or best-effort passthrough with structured errors on failure. |

**Shared acquisition contract — MUST**

The host-side HTTPS acquisition (`git credential fill` with `GIT_TERMINAL_PROMPT=0`, optional `ADEVCONTAINER_GIT_TOKEN`, `gh auth token` fallback) constitutes the shared acquisition contract. Clone's populate MUST keep the in-container `credential.helper store` + `git credential approve` pattern; create-path seeding MUST reuse the same host-side acquisition and persist credentials in-container via the username-agnostic credential helper defined in [core.md](../../../core.md) **Git credential store seeded on create paths** (Amendment 1) — the seeding mechanism no longer uses `credential.helper store`. Both use sites MUST redact secrets identically (URL userinfo and credential material must never appear in success JSON, labels, progress lines, or logged errors).

**Clone cleanup on failure (after workspace volume / container create) — MUST**

If start, populate, or create-path lifecycle hooks fail after the workspace volume and/or container have been created, `clone` MUST:

1. Delete the managed dev container (force as needed), and
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
- Then credentials are passed into one in-container clone without appearing in success JSON/labels, and after clone the guest configures `credential.helper store`.

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

#### Scenario: create-path seeding reuses the shared acquisition contract

- Given a bind-mode `up` fresh create (or a `rebuild` replacement create) whose host workspace has an HTTPS remote, and clone's populate already exercised the same host fill and store+approve semantics
- When create-path seeding acquires credentials for that remote
- Then seeding uses the same acquisition contract as the clone HTTPS row (fill with `GIT_TERMINAL_PROMPT=0`, `ADEVCONTAINER_GIT_TOKEN` escape hatch, `gh auth token` fallback) and redacts secrets identically

#### Scenario: clone keeps a single populate mechanism (regression)

- Given a volume-mode `clone` create with an HTTPS git URL and host credentials available
- When clone runs populate
- Then the existing in-clone store+approve delivers the store outcome before hooks and NO seeding call runs on `clone`

## REMOVED Requirements

None.
