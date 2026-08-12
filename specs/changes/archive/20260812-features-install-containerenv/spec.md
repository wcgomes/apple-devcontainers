# Change Spec: features-install-containerenv

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply. Requirements below are **MODIFIED** unless marked **ADDED**.

## ADDED Requirements

None.

## MODIFIED Requirements

### Requirement: Derived image build (native arm64; no Rosetta)

**Modify** step 4 (generated Dockerfile install layers) so install-time environment is not limited to options + `_REMOTE_USER` / `_CONTAINER_USER`.

When the Features runner generates a derived-image Dockerfile, for **each** feature install layer the product MUST make that feature’s declared metadata `containerEnv` (from `devcontainer-feature.json`) available to that feature’s `./install.sh` during the install `RUN` (parity with `@devcontainers/cli` ENV-before-install intent).

**Install env composition (MUST):**

1. Feature metadata **`containerEnv`** key/value pairs declared for that feature, emitted as Dockerfile **`ENV` lines before** that feature’s install `RUN`. Values MUST preserve `$VAR` / `${VAR}` for BuildKit/Docker ENV expansion and MUST NOT be shell single-quoted (single-quoting blocks expansion and can replace `PATH` with a literal `$PATH:…` string).
2. Feature **options** (resolved user options over metadata defaults), mapped to install env names as today, on the install `RUN` export prefix.
3. **`_REMOTE_USER` / `_CONTAINER_USER`** (and homes) per existing Features install user-env contract (config users → base image USER → `root`; no hardcoded editor usernames), on the install `RUN` export prefix so they win over `ENV` for the install process on key collision.

**Empty metadata (MUST):** When a feature’s `containerEnv` is absent or empty, install env MUST still include options and user keys; no extra feature `ENV` lines are required; behavior MUST match prior options+user-only install env aside from the `recipeVersion` bump.

**Scope of availability (MUST):** Each feature’s `containerEnv` MUST be visible to **that** feature’s `install.sh`. The product MUST NOT omit a non-empty declared key solely because runtime merge also applies the same key later.

**Unchanged (MUST NOT regress):**

- Install remains **as root** with final base-image `USER` restore after all feature layers.
- Runtime merge of feature `containerEnv` into effective create/exec env remains **config `containerEnv` wins** on key conflict (see **Merge feature metadata into create and lifecycle**). This change MUST NOT alter that runtime conflict policy.
- Config-file `containerEnv` is **not** required in the install Dockerfile; install-time source is feature metadata.

**recipeVersion (MUST):** Because install-Dockerfile semantics change, the product MUST set Features `recipeVersion` to `"5"` so existing derived tags (including epoch `"4"` RUN-prefix containerEnv) miss and rebuild. Tag identity material (base + features + `recipeVersion`) and reuse rules are otherwise unchanged.

#### Scenario: install sees feature containerEnv

- Given a feature whose metadata declares `containerEnv.DOTNET_ROOT=/usr/share/dotnet` (or equivalent non-empty map)
- When the Features Dockerfile install layer for that feature is generated
- Then the generated Dockerfile includes `ENV DOTNET_ROOT=/usr/share/dotnet` (or equivalent non-single-quoted ENV form) before that feature’s install `RUN`
- And that feature’s `./install.sh` install environment includes `DOTNET_ROOT` with value `/usr/share/dotnet`

#### Scenario: containerEnv PATH dollar-refs expand (no single-quote wipe)

- Given a feature whose metadata declares `containerEnv.DOTNET_ROOT=/usr/share/dotnet` and `containerEnv.PATH=$PATH:$DOTNET_ROOT` (or `${PATH}:$DOTNET_ROOT`)
- When the Features Dockerfile install layer for that feature is generated
- Then the Dockerfile contains an `ENV` assignment for `PATH` whose value still includes expandable `$PATH` / `${PATH}` (e.g. `ENV PATH=$PATH:$DOTNET_ROOT`)
- And the Dockerfile does **not** contain a shell single-quoted PATH value such as `PATH='$PATH:$DOTNET_ROOT'`
- And `DOTNET_ROOT` is still available to `install.sh` (via `ENV` or equivalent)
- And system utilities on the base image PATH (e.g. `dirname`) remain reachable during install because PATH is not replaced by the literal string `$PATH:…`

#### Scenario: empty containerEnv unchanged

- Given a feature with absent or empty metadata `containerEnv`
- When the Features Dockerfile install layer for that feature is generated
- Then install env still includes resolved option keys and `_REMOTE_USER` / `_CONTAINER_USER` (and homes)
- And no extra feature `containerEnv` keys are required

#### Scenario: install env still has options and user keys

- Given a feature with options and non-empty metadata `containerEnv`, and config/base user inputs that resolve install users
- When the Features Dockerfile install layer is generated
- Then install env includes option-derived keys, the feature’s `containerEnv` keys, and `_REMOTE_USER` / `_CONTAINER_USER` (and homes)
- And option/user keys remain on the RUN export prefix (not forced into `ENV` solely by this change)

#### Scenario: recipeVersion bump invalidates derived tags

- Given the same base image + feature refs/options
- When derived tags are computed with product `recipeVersion` `"4"` vs `"5"`
- Then the tags differ (stale images built under the prior install recipe are not reused)

#### Scenario: runtime merge still config-wins (no change)

- Given feature metadata `containerEnv.FOO=from-feature` and config `containerEnv.FOO=from-config`
- When effective **runtime** env is computed for create/exec
- Then `FOO` is `from-config`
- And this conflict policy is unchanged by install-time `containerEnv` availability

---

### Requirement: Merge feature metadata into create and lifecycle

**Clarify (no behavior change):** The `containerEnv` row remains runtime-only merge into effective create/exec env with **config wins** on key conflict. Install-time availability of feature `containerEnv` is governed solely by **Derived image build** above and MUST NOT reverse or weaken config-wins at runtime.

#### Scenario: Config containerEnv wins over feature env

- Given feature metadata `containerEnv.FOO=from-feature` and config `containerEnv.FOO=from-config`
- When effective env is computed
- Then `FOO` is `from-config`

## REMOVED Requirements

None.
